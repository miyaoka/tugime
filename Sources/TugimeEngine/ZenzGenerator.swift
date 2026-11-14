import Foundation
import llama
import TugimeCore

/// zenz 形式のモデル（GGUF）を llama.cpp で動かし、読みから出力の文字列を貪欲に生成する。llama.cpp を直接触るのはこのファイルだけ。
///
/// 区切りごとに「BOS + ZenzPrompt.text をトークンにし、EOS か上限まで、ZenzPrompt.outputGrammar が許すうちで logit が最大のトークンを 1 つずつ足した列」を作り、文字にして繋ぐ。
/// 入力と出力がモデルの位置の上限に収まらないときは、左の文脈を前から削る。
/// 1 つの区切りの読みは出力と合わせて収まる長さに分けてあるので、読みは落ちない。
/// 打鍵ごとの再計算は、2 つの仕組みで少ない decode にする:
/// - KV キャッシュには、前に計算した入力と下書きが残る。新しい入力と先頭が一致する範囲は計算し直さない
/// - 下書きは、同じ左の文脈で前に生成した出力。入力の後ろに置いて一度に decode し、生成するトークンと一致する先頭だけを採る
/// まとめて decode した位置と 1 つずつ decode した位置では浮動小数の丸めが違うので、argmax が並ぶ所では、
/// 同じ入力でもそれまでの打鍵によって出力が変わることがある
final class ZenzGenerator: DirectDisplayGenerating {
    /// KV キャッシュの型。genmai-310M の元のモデルの型（単精度）に合わせる。F16 は genmai-310M で桁があふれ、BF16 は丸めで出力が変わる
    private static let kvType = GGML_TYPE_F32
    /// モデルの全層を GPU に載せる。llama.cpp はモデルの層数を超える値を全層として扱う
    private static let allLayersOnGPU: Int32 = 999
    /// 文字にするときに最初に用意する、1 トークンあたりのバイト数。足りなければ llama.cpp が要る大きさを返す
    private static let bytesPerTokenGuess = 8
    /// 左の文脈を削るときの字数の単位
    private static let contextTrimStep = 32

    private static let backend: Void = llama_backend_init()

    /// モデルを読めない
    enum LoadError: Error, CustomStringConvertible {
        case model(String)
        case context(String)
        case vocabulary(String)
        case grammar
        var description: String {
            switch self {
            case .model(let path): "モデルを読めない: \(path)"
            case .vocabulary(let path): "モデルの語彙を読めない: \(path)"
            case .context(let path): "llama.cpp のコンテキストを作れない: \(path)"
            case .grammar: "出力の文法を作れない"
            }
        }
    }

    /// 生成の途中で llama.cpp が失敗した。その生成を取りやめる
    private enum Failure: Error {
        case memory
        case decode
        /// 計算が壊れて logits が有限でない。KV キャッシュの型と flash attention が原因になりうる
        case nonFinite
        case tokenize(String)
        case detokenize([llama_token])
        /// decode する列が、位置の上限か batch の大きさを超える
        case overflow
        /// llama.cpp が位置の logits を返さない
        case logits
        /// argmax を求めていない位置の次のトークンを読もうとした
        case argmax
    }

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
    /// 出力から、目印と、字の頭にならないバイトを除く
    private let grammar: UnsafeMutablePointer<llama_sampler>
    /// 左の文脈ごとの、前に生成した出力
    private var drafts: [String: [llama_token]] = [:]

    /// モデルを読む。読めなければ LoadError を投げる
    init(weight: URL) throws {
        _ = Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = Self.allLayersOnGPU
        guard let model = llama_model_load_from_file(weight.path, modelParams) else { throw LoadError.model(weight.path) }
        // 語彙が無いと、トークンにすることも、logits の最大を選ぶこともできない
        guard let vocab = llama_model_get_vocab(model), llama_vocab_n_tokens(vocab) > 0 else {
            llama_model_free(model)
            throw LoadError.vocabulary(weight.path)
        }
        self.vocab = vocab
        maxPositions = Int(llama_model_n_ctx_train(model))
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(maxPositions)
        contextParams.n_batch = UInt32(maxPositions)
        contextParams.type_k = Self.kvType
        contextParams.type_v = Self.kvType
        contextParams.no_perf = true
        // flash attention は、genmai-310M の単精度の KV キャッシュでは出力を変えずに 1 打鍵の表示を遅くする
        contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LoadError.context(weight.path)
        }
        guard let grammar = llama_sampler_init_grammar(vocab, ZenzPrompt.outputGrammar, "root") else {
            llama_free(context)
            llama_model_free(model)
            throw LoadError.grammar
        }
        self.grammar = grammar
        resources = LlamaResources(model: model, context: context)
        LiveLlamaResources.add(resources)
        batch = llama_batch_init(Int32(maxPositions), 0, 1)
        bos = llama_vocab_bos(vocab)
        eos = llama_vocab_eos(vocab)
        vocabularySize = Int(llama_vocab_n_tokens(vocab))
    }

    deinit {
        llama_sampler_free(grammar)
        llama_batch_free(batch)
        LiveLlamaResources.remove(resources)
        resources.release()
    }

    /// llama.cpp が途中で失敗したら、想定外の状態として記録して空の出力を返す。失敗した生成の KV キャッシュと下書きは次に持ち越さない
    func generate(left: String, kana: String) -> String {
        do {
            return try generating(left: left, kana: kana)
        } catch {
            // 失敗した計算の値をバッファに残さないよう、データまで消す
            clear(data: true)
            return switch error {
            case .memory: Unexpected.reached("llama.cpp の KV キャッシュを消せない", continuingWith: "")
            case .decode: Unexpected.reached("llama.cpp の decode が失敗した", continuingWith: "")
            case .nonFinite: Unexpected.reached("モデルの計算が壊れた（logits が有限でない）", continuingWith: "")
            case .tokenize(let text): Unexpected.reached("トークンにできない", detail: text, continuingWith: "")
            case .detokenize(let tokens): Unexpected.reached("トークンを文字にできない", detail: "\(tokens)", continuingWith: "")
            case .overflow: Unexpected.reached("decode する列が位置の上限を超える", continuingWith: "")
            case .logits: Unexpected.reached("llama.cpp が logits を返さない", continuingWith: "")
            case .argmax: Unexpected.reached("argmax を求めていない位置を読もうとした", continuingWith: "")
            }
        }
    }

    func reset() {
        clear(data: false)
    }

    /// KV キャッシュと、その中身を表す resident・next と、下書きを捨てる。data が偽なら KV キャッシュは管理情報だけを消し、バッファは次の decode が上書きする
    private func clear(data: Bool) {
        llama_memory_clear(llama_get_memory(context), data)
        resident = []
        next = []
        drafts = [:]
    }

    private func generating(left: String, kana: String) throws(Failure) -> String {
        var output = ""
        var parts = ZenzPrompt.chunks(kana, maxLength: ZenzPrompt.maxChunkLength(positions: maxPositions))[...]
        while let part = parts.popFirst() {
            let contextText = left + output
            let limit = outputLimit(part)
            guard let prompt = try fittedPrompt(context: contextText, kana: part, limit: limit) else {
                // 文脈を空にしても収まらない区切り（読みの字が複数のトークンになるとき）は、収まるまで半分に分ける。読みは削らない
                let halves = try ZenzPrompt.halving([part]) { piece throws(Failure) in
                    try fittedPrompt(context: "", kana: piece, limit: outputLimit(piece)) != nil
                }
                parts.insert(contentsOf: halves, at: parts.startIndex)
                continue
            }
            let tokens = try greedy(prompt, limit: limit, draft: drafts[contextText] ?? [])
            drafts[contextText] = tokens
            output += ZenzPrompt.cutAtNewline(try detokenize(tokens))
        }
        return ZenzPrompt.restoreSpaces(output)
    }

    /// 1 つの区切りで生成するトークン数の上限。出力に位置の半分までを使い、残りに入力を収める
    private func outputLimit(_ part: String) -> Int {
        min(ZenzPrompt.outputLimit(part), maxPositions / 2)
    }

    /// 入力と limit 個の出力が位置の上限に収まるよう、左の文脈を前から削った入力。文脈の目印は残す。
    /// 文脈を空にしても収まらなければ nil
    private func fittedPrompt(context: String, kana: String, limit: Int) throws(Failure) -> [llama_token]? {
        var scalars = Array(context.unicodeScalars.suffix(ZenzPrompt.maxContextLength))
        while true {
            let prompt = try tokenize(ZenzPrompt.text(left: String(String.UnicodeScalarView(scalars)), kana: kana))
            let over = prompt.count + limit - maxPositions
            if over <= 0 { return prompt }
            if scalars.isEmpty { return nil }
            // 1 字は 1 トークン以上なので、超えたトークンの数だけ字を削れば、少なくともその数のトークンが減る。
            // 削る字数は contextTrimStep の倍数に切り上げる。超えた数だけ削ると、読みが伸びるたびに入力の先頭が変わり、KV キャッシュを使い回せない
            let step = Self.contextTrimStep
            scalars.removeFirst(min((over + step - 1) / step * step, scalars.count))
        }
    }

    private func greedy(_ prompt: [llama_token], limit: Int, draft: [llama_token]) throws(Failure) -> [llama_token] {
        let sequence = prompt + draft.prefix(limit)
        let needFrom = prompt.count - 1
        var keep = 0
        while keep < min(resident.count, sequence.count), resident[keep] == sequence[keep] { keep += 1 }
        // 入力の最後から先は argmax が要る。持ち越す範囲で求めていない位置があれば、そこから計算し直す
        if let missing = (needFrom..<max(needFrom, keep)).first(where: { next[$0] == nil }) { keep = missing }
        try truncate(keep)
        try append(Array(sequence[keep...]), needFrom: needFrom)
        var out: [llama_token] = []
        llama_sampler_reset(grammar)
        while out.count < limit {
            let token = try allowed(at: needFrom + out.count)
            if token == eos { break }
            llama_sampler_accept(grammar, token)
            out.append(token)
            let position = prompt.count + out.count - 1
            if position < resident.count, resident[position] == token { continue }
            try truncate(position)
            try append([token], needFrom: position)
        }
        return out
    }

    private func truncate(_ count: Int) throws(Failure) {
        guard resident.count > count else { return }
        guard llama_memory_seq_rm(llama_get_memory(context), 0, Int32(count), -1) else { throw .memory }
        resident.removeLast(resident.count - count)
        next.removeLast(next.count - count)
    }

    /// tokens を resident の後ろに decode し、位置 needFrom 以降の argmax を next に足す。
    /// 計算が壊れると logits が有限でなくなる。そのまま argmax を取るとエラーにならずに壊れた出力を返すので、失敗にする
    private func append(_ tokens: [llama_token], needFrom: Int) throws(Failure) {
        guard !tokens.isEmpty else { return }
        let start = resident.count
        // batch とコンテキストは maxPositions の大きさで作ってある
        guard start + tokens.count <= maxPositions else { throw .overflow }
        batch.n_tokens = 0
        for (i, token) in tokens.enumerated() {
            batch.token[i] = token
            batch.pos[i] = Int32(start + i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = start + i >= needFrom ? 1 : 0
            batch.n_tokens += 1
        }
        guard llama_decode(context, batch) == 0 else { throw .decode }
        for i in 0..<tokens.count {
            guard start + i >= needFrom else {
                next.append(nil)
                continue
            }
            guard let logits = llama_get_logits_ith(context, Int32(i)) else { throw .logits }
            var best = 0
            var finite = logits[0].isFinite
            for v in 1..<vocabularySize {
                finite = finite && logits[v].isFinite
                if logits[v] > logits[best] { best = v }
            }
            guard finite else { throw .nonFinite }
            next.append(llama_token(best))
        }
        resident += tokens
    }

    /// 位置 index の直後のトークン。argmax が文法に合えばそれを、合わなければその位置を decode し直し、文法が許すうちで logit が最大のものを返す。
    /// llama.cpp の common_sampler_sample と同じく、全トークンに文法を当てるのは argmax が外れたときだけにする。
    /// 位置ごとの logits は持たない（decode のたびに語彙全体を写すことになる）ので、外れた位置は decode し直す
    private func allowed(at index: Int) throws(Failure) -> llama_token {
        guard index < next.count, let token = next[index] else { throw .argmax }
        var single = llama_token_data(id: token, logit: 1, p: 0)
        let fits = withUnsafeMutablePointer(to: &single) { pointer in
            var check = llama_token_data_array(data: pointer, size: 1, selected: -1, sorted: false)
            llama_sampler_apply(grammar, &check)
            return pointer.pointee.logit != -.infinity
        }
        if fits { return token }
        let input = resident[index]
        try truncate(index)
        try append([input], needFrom: index)
        guard let logits = llama_get_logits_ith(context, 0) else { throw .logits }
        var data = (0..<vocabularySize).map { llama_token_data(id: llama_token($0), logit: logits[$0], p: 0) }
        return data.withUnsafeMutableBufferPointer { buffer in
            var array = llama_token_data_array(data: buffer.baseAddress, size: buffer.count, selected: -1, sorted: false)
            llama_sampler_apply(grammar, &array)
            return buffer.max { $0.logit < $1.logit }!.id
        }
    }

    private func tokenize(_ text: String) throws(Failure) -> [llama_token] {
        let capacity = text.utf8.count + 1
        var buffer = [llama_token](repeating: 0, count: capacity)
        let count = llama_tokenize(vocab, text, Int32(text.utf8.count), &buffer, Int32(capacity), false, false)
        guard count >= 0 else { throw .tokenize(text) }
        return [bos] + buffer.prefix(Int(count))
    }

    /// トークンの列を文字にする。1 文字が 2 つのトークンに分かれていても、列のバイトを繋いでから文字にするので壊れない
    private func detokenize(_ tokens: [llama_token]) throws(Failure) -> String {
        var buffer = [CChar](repeating: 0, count: tokens.count * Self.bytesPerTokenGuess)
        var count = llama_detokenize(vocab, tokens, Int32(tokens.count), &buffer, Int32(buffer.count), false, false)
        // 領域が足りないと、要る大きさを負の数で返す
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_detokenize(vocab, tokens, Int32(tokens.count), &buffer, Int32(buffer.count), false, false)
        }
        guard count >= 0 else { throw .detokenize(tokens) }
        return String(decoding: ZenzPrompt.droppingIncompleteTail(buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }), as: UTF8.self)
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
