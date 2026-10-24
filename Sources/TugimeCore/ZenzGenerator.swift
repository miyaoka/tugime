import Foundation
import llama

/// zenz 形式のモデル（GGUF）を llama.cpp で動かし、読みから出力の文字列を貪欲に生成する。llama.cpp を直接触るのはこのファイルだけ。
///
/// llama.cpp は azooKey が trait Zenzai で載せるもの（binaryTarget）をそのまま使い、別の llama.cpp を足さない。
/// direct の方式は azooKey に Zenzai を渡さないので、プロセスで llama.cpp にモデルを載せるのはこの型だけになる。
///
/// 返す値の定義は「BOS + ZenzPrompt.text をトークンにし、EOS か上限まで argmax を 1 つずつ足した列」を区切りごとに繋いだもの。
/// 打鍵ごとの再計算を速くする仕組み（KV キャッシュの持ち越しと下書き）は、その列を少ない decode で得るための省略である。
/// - KV キャッシュには、前に計算した入力と下書きが残る。新しい入力と先頭が一致する範囲は計算し直さない
/// - 下書きは、同じ左の文脈で前に生成した出力。入力の後ろに置いて一度に decode し、各位置の argmax と一致する先頭だけを採る
/// まとめて decode した位置と 1 つずつ decode した位置では浮動小数の丸めが違い、argmax が並ぶ所では打鍵の途中の出力が変わりうる
final class ZenzGenerator: DirectDisplayGenerating {
    /// KV キャッシュの型。単精度より軽い型で出力が変わらないことを tugime-eval で確かめたモデルだけを、GGUF の general.name で書く
    private static let kvTypes: [String: ggml_type] = ["Genmai 310M": GGML_TYPE_BF16]
    private static let defaultKVType = GGML_TYPE_F32
    /// GPT-2 の位置の上限。入力と出力はこの中に収める
    private static let maxPositions = 1024

    private static let backend: Void = llama_backend_init()

    private let model: OpaquePointer
    private let vocab: OpaquePointer
    private let context: OpaquePointer
    private var batch: llama_batch
    private let bos: llama_token
    private let eos: llama_token
    private let vocabularySize: Int
    /// KV キャッシュの系列 0 に入っているトークンと、各位置の直後の argmax。KV を消したら同じだけ縮める
    private var resident: [llama_token] = []
    private var next: [llama_token] = []
    /// 左の文脈ごとの、前に生成した出力
    private var drafts: [String: [llama_token]] = [:]

    /// モデルを読む。読めなければ止める（make() は投げないので、受け止められない）
    init(weight: URL) {
        _ = Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(weight.path, modelParams) else { fatalError("モデルを読めない: \(weight.path)") }
        self.model = model
        vocab = llama_model_get_vocab(model)!
        var nameBuffer = [CChar](repeating: 0, count: 256)
        let name = llama_model_meta_val_str(model, "general.name", &nameBuffer, nameBuffer.count) >= 0
            ? String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : ""
        let kvType = Self.kvTypes[name] ?? Self.defaultKVType
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(Self.maxPositions)
        contextParams.n_batch = UInt32(Self.maxPositions)
        contextParams.type_k = kvType
        contextParams.type_v = kvType
        contextParams.no_perf = true
        // genmai-310M は半精度の KV キャッシュで flash attention を使うと logits が有限でなくなる。使わなければ半精度でも壊れない
        contextParams.flash_attn = false
        guard let context = llama_init_from_model(model, contextParams) else { fatalError("llama.cpp のコンテキストを作れない: \(weight.path)") }
        self.context = context
        batch = llama_batch_init(Int32(Self.maxPositions), 0, 1)
        bos = llama_vocab_bos(vocab)
        eos = llama_vocab_eos(vocab)
        vocabularySize = Int(llama_vocab_n_tokens(vocab))
    }

    deinit {
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    func generate(left: String, kana: String) -> String {
        var output = ""
        for part in ZenzPrompt.chunks(kana) {
            let contextText = left + output
            let prompt = tokenize(ZenzPrompt.text(left: contextText, kana: part))
            let tokens = greedy(prompt, limit: ZenzPrompt.outputLimit(part), draft: drafts[contextText] ?? [])
            drafts[contextText] = tokens
            output += detokenize(tokens)
        }
        return ZenzPrompt.restoreSpaces(output)
    }

    func reset() {
        truncate(0)
        drafts = [:]
    }

    private func greedy(_ prompt: [llama_token], limit: Int, draft: [llama_token]) -> [llama_token] {
        let sequence = prompt + draft.prefix(limit)
        var common = 0
        while common < min(resident.count, sequence.count), resident[common] == sequence[common] { common += 1 }
        truncate(common)
        append(Array(sequence[common...]))
        var out: [llama_token] = []
        while out.count < limit {
            let token = next[prompt.count - 1 + out.count]
            if token == eos { break }
            out.append(token)
            let position = prompt.count + out.count - 1
            if position < resident.count, resident[position] == token { continue }
            truncate(position)
            append([token])
        }
        return out
    }

    private func truncate(_ count: Int) {
        guard resident.count > count else { return }
        guard llama_kv_cache_seq_rm(context, 0, Int32(count), -1) else { fatalError("KV キャッシュを消せない") }
        resident.removeLast(resident.count - count)
        next.removeLast(next.count - count)
    }

    /// tokens を resident の後ろに decode し、各位置の argmax を next に足す。decode が失敗したら止める。
    /// 計算があふれると logits が有限でなくなる。そのまま argmax を取ると、エラーにならずに壊れた出力を返すので、止める
    private func append(_ tokens: [llama_token]) {
        guard !tokens.isEmpty else { return }
        guard resident.count + tokens.count <= Self.maxPositions else { fatalError("入力と出力がモデルの位置の上限 \(Self.maxPositions) を超えた") }
        batch.n_tokens = 0
        for (i, token) in tokens.enumerated() {
            batch.token[i] = token
            batch.pos[i] = Int32(resident.count + i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = 1
            batch.n_tokens += 1
        }
        guard llama_decode(context, batch) == 0 else { fatalError("llama.cpp の decode が失敗した") }
        for i in 0..<tokens.count {
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

    /// トークンのバイトを繋いでから文字にする。1 文字が 2 つのトークンに分かれていても壊れない
    private func detokenize(_ tokens: [llama_token]) -> String {
        var bytes: [UInt8] = []
        var buffer = [CChar](repeating: 0, count: 64)
        for token in tokens {
            let count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
            guard count >= 0 else { fatalError("トークンを文字にする領域が足りない: \(token)") }
            bytes += buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
