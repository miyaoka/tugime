import Foundation
import llama

/// zenz 形式のモデル（GGUF）を llama.cpp で動かし、読みから出力の文字列を貪欲に生成する。llama.cpp を直接触るのはこのファイルだけ。
///
/// 区切りごとに「BOS + ZenzPrompt.text をトークンにし、EOS か上限まで argmax を 1 つずつ足した列」を作り、文字にして繋ぐ。
/// 入力と出力がモデルの位置の上限に収まらないときは、左の文脈を前から削る。
/// 1 つの区切りの読みは出力と合わせて収まる長さに分けてあるので、読みは落ちない。
/// 打鍵ごとの再計算は、2 つの仕組みで少ない decode にする:
/// - KV キャッシュには、前に計算した入力と下書きが残る。新しい入力と先頭が一致する範囲は計算し直さない
/// - 下書きは、同じ左の文脈で前に生成した出力。入力の後ろに置いて一度に decode し、各位置の argmax と一致する先頭だけを採る
/// まとめて decode した位置と 1 つずつ decode した位置では浮動小数の丸めが違うので、argmax が並ぶ所では、
/// 同じ入力でもそれまでの打鍵によって出力が変わることがある
final class ZenzGenerator: DirectDisplayGenerating {
    /// KV キャッシュの型。単精度より軽い型で出力が変わらないことを tugime-eval で確かめたモデルだけを、GGUF の general.name で書く
    private static let kvTypes: [String: ggml_type] = ["Genmai 310M": GGML_TYPE_BF16]
    private static let defaultKVType = GGML_TYPE_F32
    /// モデルの全層を GPU に載せる。llama.cpp はモデルの層数を超える値を全層として扱う
    private static let allLayersOnGPU: Int32 = 999
    /// 文字にするときに最初に用意する、1 トークンあたりのバイト数。足りなければ llama.cpp が要る大きさを返す
    private static let bytesPerTokenGuess = 8

    private static let backend: Void = llama_backend_init()

    private let resources: LlamaResources
    private var context: OpaquePointer { resources.context }
    private let vocab: OpaquePointer
    private var batch: llama_batch
    private let bos: llama_token
    private let eos: llama_token
    private let vocabularySize: Int
    /// モデルが学習した位置の数。入力と出力はこの中に収める
    private let maxPositions: Int
    /// KV キャッシュの系列 0 に入っているトークンと、各位置の直後の argmax。KV を消したら同じだけ縮める。
    /// argmax は、そのトークンを足したときの入力の最後の位置より前では求めないので nil になる
    private var resident: [llama_token] = []
    private var next: [llama_token?] = []
    /// 左の文脈ごとの、前に生成した出力
    private var drafts: [String: [llama_token]] = [:]

    /// モデルを読む。読めなければ止める（make() は投げないので、受け止められない）
    init(weight: URL) {
        _ = Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = Self.allLayersOnGPU
        guard let model = llama_model_load_from_file(weight.path, modelParams) else { fatalError("モデルを読めない: \(weight.path)") }
        vocab = llama_model_get_vocab(model)!
        maxPositions = Int(llama_model_n_ctx_train(model))
        var nameBuffer = [CChar](repeating: 0, count: 256)
        let name = llama_model_meta_val_str(model, "general.name", &nameBuffer, nameBuffer.count) >= 0
            ? String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : ""
        let kvType = Self.kvTypes[name] ?? Self.defaultKVType
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(maxPositions)
        contextParams.n_batch = UInt32(maxPositions)
        contextParams.type_k = kvType
        contextParams.type_v = kvType
        contextParams.no_perf = true
        // genmai-310M は半精度の KV キャッシュで flash attention を使うと logits が有限でなくなる。使わなければ半精度でも壊れない
        contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED
        guard let context = llama_init_from_model(model, contextParams) else { fatalError("llama.cpp のコンテキストを作れない: \(weight.path)") }
        resources = LlamaResources(model: model, context: context)
        LiveLlamaResources.add(resources)
        batch = llama_batch_init(Int32(maxPositions), 0, 1)
        bos = llama_vocab_bos(vocab)
        eos = llama_vocab_eos(vocab)
        vocabularySize = Int(llama_vocab_n_tokens(vocab))
    }

    deinit {
        llama_batch_free(batch)
        LiveLlamaResources.remove(resources)
        resources.release()
    }

    func generate(left: String, kana: String) -> String {
        var output = ""
        var parts = ZenzPrompt.chunks(kana, maxLength: ZenzPrompt.maxChunkLength(positions: maxPositions))[...]
        while let part = parts.popFirst() {
            let contextText = left + output
            let limit = outputLimit(part)
            guard let prompt = fittedPrompt(context: contextText, kana: part, limit: limit) else {
                // 文脈を空にしても収まらない区切り（読みの字が複数のトークンになるとき）は、収まるまで半分に分ける。読みは削らない
                let halves = ZenzPrompt.halving([part]) { fittedPrompt(context: "", kana: $0, limit: outputLimit($0)) != nil }
                parts.insert(contentsOf: halves, at: parts.startIndex)
                continue
            }
            let tokens = greedy(prompt, limit: limit, draft: drafts[contextText] ?? [])
            drafts[contextText] = tokens
            output += ZenzPrompt.cutAtNewline(detokenize(tokens))
        }
        return ZenzPrompt.restoreSpaces(output)
    }

    func reset() {
        truncate(0)
        drafts = [:]
    }

    /// 1 つの区切りで生成するトークン数の上限。出力に位置の半分までを使い、残りに入力を収める
    private func outputLimit(_ part: String) -> Int {
        min(ZenzPrompt.outputLimit(part), maxPositions / 2)
    }

    /// 入力と limit 個の出力が位置の上限に収まるよう、左の文脈を前から削った入力。文脈の目印は残す。
    /// 文脈を空にしても収まらなければ nil
    private func fittedPrompt(context: String, kana: String, limit: Int) -> [llama_token]? {
        var scalars = Array(context.unicodeScalars.suffix(ZenzPrompt.maxContextLength))
        while true {
            let prompt = tokenize(ZenzPrompt.text(left: String(String.UnicodeScalarView(scalars)), kana: kana))
            let over = prompt.count + limit - maxPositions
            if over <= 0 { return prompt }
            if scalars.isEmpty { return nil }
            // 1 字は 1 トークン以上なので、超えたトークンの数だけ字を削れば、少なくともその数のトークンが減る
            scalars.removeFirst(min(over, scalars.count))
        }
    }

    private func greedy(_ prompt: [llama_token], limit: Int, draft: [llama_token]) -> [llama_token] {
        let sequence = prompt + draft.prefix(limit)
        let needFrom = prompt.count - 1
        var keep = 0
        while keep < min(resident.count, sequence.count), resident[keep] == sequence[keep] { keep += 1 }
        // 入力の最後から先は argmax が要る。持ち越す範囲で求めていない位置があれば、そこから計算し直す
        if let missing = (needFrom..<max(needFrom, keep)).first(where: { next[$0] == nil }) { keep = missing }
        truncate(keep)
        append(Array(sequence[keep...]), needFrom: needFrom)
        var out: [llama_token] = []
        while out.count < limit {
            let token = next[needFrom + out.count]!
            if token == eos { break }
            out.append(token)
            let position = prompt.count + out.count - 1
            if position < resident.count, resident[position] == token { continue }
            truncate(position)
            append([token], needFrom: position)
        }
        return out
    }

    private func truncate(_ count: Int) {
        guard resident.count > count else { return }
        guard llama_memory_seq_rm(llama_get_memory(context), 0, Int32(count), -1) else { fatalError("KV キャッシュを消せない") }
        resident.removeLast(resident.count - count)
        next.removeLast(next.count - count)
    }

    /// tokens を resident の後ろに decode し、位置 needFrom 以降の argmax を next に足す。decode が失敗したら止める。
    /// 計算が壊れると logits が有限でなくなる。そのまま argmax を取るとエラーにならずに壊れた出力を返すので、止める
    private func append(_ tokens: [llama_token], needFrom: Int) {
        guard !tokens.isEmpty else { return }
        let start = resident.count
        batch.n_tokens = 0
        for (i, token) in tokens.enumerated() {
            batch.token[i] = token
            batch.pos[i] = Int32(start + i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = start + i >= needFrom ? 1 : 0
            batch.n_tokens += 1
        }
        guard llama_decode(context, batch) == 0 else { fatalError("llama.cpp の decode が失敗した") }
        for i in 0..<tokens.count {
            guard start + i >= needFrom else {
                next.append(nil)
                continue
            }
            let logits = llama_get_logits_ith(context, Int32(i))!
            var best = 0
            var finite = logits[0].isFinite
            for v in 1..<vocabularySize {
                finite = finite && logits[v].isFinite
                if logits[v] > logits[best] { best = v }
            }
            guard finite else { fatalError("モデルの計算が壊れた（logits が有限でない）。KV キャッシュの型と flash attention を見直す") }
            next.append(llama_token(best))
        }
        resident += tokens
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let capacity = text.utf8.count + 1
        var buffer = [llama_token](repeating: 0, count: capacity)
        let count = llama_tokenize(vocab, text, Int32(text.utf8.count), &buffer, Int32(capacity), false, false)
        guard count >= 0 else { fatalError("トークンにできない: \(text)") }
        return [bos] + buffer.prefix(Int(count))
    }

    /// トークンの列を文字にする。1 文字が 2 つのトークンに分かれていても、列のバイトを繋いでから文字にするので壊れない
    private func detokenize(_ tokens: [llama_token]) -> String {
        var buffer = [CChar](repeating: 0, count: tokens.count * Self.bytesPerTokenGuess)
        var count = llama_detokenize(vocab, tokens, Int32(tokens.count), &buffer, Int32(buffer.count), false, false)
        // 領域が足りないと、要る大きさを負の数で返す
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_detokenize(vocab, tokens, Int32(tokens.count), &buffer, Int32(buffer.count), false, false)
        }
        guard count >= 0 else { fatalError("トークンを文字にする領域が足りない: \(tokens)") }
        return String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// llama.cpp のモデルとコンテキスト。Metal の GPU の資源を持つ。解放は 1 回だけ行う
private final class LlamaResources: @unchecked Sendable {
    let model: OpaquePointer
    let context: OpaquePointer
    private var released = false

    init(model: OpaquePointer, context: OpaquePointer) {
        self.model = model
        self.context = context
    }

    func release() {
        guard !released else { return }
        released = true
        llama_free(context)
        llama_model_free(model)
    }
}

/// 解放されていない llama.cpp の資源。llama.cpp の Metal は、GPU の資源を残したままプロセスが終わると
/// ggml_metal_rsets_free の検査で止まる。入力メソッドは生成器をグローバルに持ち、解放しないまま終わるので、終わるときに残りを解放する
private enum LiveLlamaResources {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var live: [ObjectIdentifier: LlamaResources] = [:]
    /// 最初の資源を足すとき（Metal を初期化した後）に登録する。atexit の関数と C++ の静的な後片付けは登録の逆順に走るので、Metal の後片付けより先に走る
    private static let releaseAtExit: Void = { atexit { LiveLlamaResources.releaseAll() } }()

    static func add(_ resources: LlamaResources) {
        _ = releaseAtExit
        lock.withLock { live[ObjectIdentifier(resources)] = resources }
    }

    static func remove(_ resources: LlamaResources) {
        _ = lock.withLock { live.removeValue(forKey: ObjectIdentifier(resources)) }
    }

    private static func releaseAll() {
        lock.withLock {
            live.values.forEach { $0.release() }
            live = [:]
        }
    }
}
