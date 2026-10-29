import Foundation
import llama

/// zenz 形式のモデル（GGUF）を llama.cpp で動かし、読みから出力の文字列を貪欲に生成する。llama.cpp を直接触るのはこのファイルだけ。
///
/// 区切りごとに「BOS + ZenzPrompt.text をトークンにし、EOS か上限まで argmax を 1 つずつ足した列」を作り、文字にして繋ぐ。
/// 入力と出力がモデルの位置の上限に収まらないときは、左の文脈を前から削る。
/// 1 つの区切りの読みは出力と合わせて収まる長さに分けてあるので、読みは落ちない。
/// 打鍵ごとの再計算は、2 つの仕組みで少ない decode にする:
/// - KV キャッシュには、前に計算した入力と下書きが残る。新しい入力と先頭が一致する範囲は計算し直さない。
///   生成の系列を区切りの候補の数だけ持ち、先頭が最も長く一致する系列で生成する
/// - 下書きは、同じ左の文脈で前に生成した出力。入力の後ろに置いて一度に decode し、各位置の argmax と一致する先頭だけを採る
/// まとめて decode した位置と 1 つずつ decode した位置では浮動小数の丸めが違うので、argmax が並ぶ所では、
/// 同じ入力でもそれまでの打鍵によって出力が変わることがある
final class ZenzGenerator: DirectDisplayGenerating {
    /// KV キャッシュの型。genmai-310M の元のモデルの型（単精度）に合わせる。F16 は genmai-310M で桁があふれ、BF16 は丸めで出力が変わる
    private static let kvType = GGML_TYPE_F32
    /// モデルの全層を GPU に載せる。llama.cpp はモデルの層数を超える値を全層として扱う
    private static let allLayersOnGPU: Int32 = 999
    /// 文字にするときに最初に用意する、1 トークンあたりのバイト数。足りなければ llama.cpp が要る大きさを返す
    private static let bytesPerTokenGuess = 8
    /// 表示の生成に使う KV キャッシュの系列の数（系列 0 から）。区切りの候補ごとに表示を生成し、同時に渡された候補は系列を分けて同時に進める。
    /// 候補は、残した語の割り当て 2 つごとに、まだ決めていない語の組み合わせを並べたもの。決めていない語が 2 つまでなら 1 回で収まる
    private static let generationSequences = 8
    /// 文の確からしさを 1 回の decode で測る文の数。文ごとに KV キャッシュの系列を 1 つ使う（表示の生成の系列の後ろ）。数の理由は generationSequences と同じ
    private static let naturalnessSequences = 8

    /// KV キャッシュのセル数。生成の系列はそれぞれ位置の上限まで使い、文の確からしさを測る系列は全部で位置の上限ぶんのセルを共有する。
    /// 文の確からしさは、文の前に置く入力と同時に測る文の和が位置の上限に収まるように組を分けるので、セルは足りる
    private static func cells(maxPositions: Int) -> Int {
        maxPositions * (generationSequences + 1)
    }

    /// 1 回の decode に入れるトークンの上限。生成は系列ごとに位置の上限まで同時に入れる。文の確からしさは位置の上限に収まる
    private static func batchCapacity(maxPositions: Int) -> Int {
        maxPositions * generationSequences
    }

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
    /// 表示の生成の系列ごとの、KV キャッシュに入っているもの。添字が系列の番号
    private var slots = (0..<ZenzGenerator.generationSequences).map { _ in GenerationSlot() }
    /// slots の番号を、最後に使った順（後ろほど新しい）に並べたもの。先頭の一致が同じ長さなら、古い方を使う
    private var slotOrder = Array(0..<ZenzGenerator.generationSequences)
    /// 左の文脈ごとの、前に生成した出力
    private var drafts: [String: [llama_token]] = [:]
    /// 文の確からしさを測る系列（1 から naturalnessSequences まで）に共通して入っている、文の前に置く入力と、
    /// その最後の位置の次のトークンの対数確率（文の最初のトークンの確率に使う）。系列には、その後ろに前に測った文が残りうる
    private var naturalnessPrefix: (tokens: [llama_token], next: [Double])?

    /// モデルを読む。読めなければ止める（make() は投げないので、受け止められない）
    init(weight: URL) {
        _ = Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = Self.allLayersOnGPU
        guard let model = llama_model_load_from_file(weight.path, modelParams) else { fatalError("モデルを読めない: \(weight.path)") }
        vocab = llama_model_get_vocab(model)!
        maxPositions = Int(llama_model_n_ctx_train(model))
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(Self.cells(maxPositions: maxPositions))
        contextParams.n_batch = UInt32(Self.batchCapacity(maxPositions: maxPositions))
        contextParams.n_seq_max = UInt32(Self.generationSequences + Self.naturalnessSequences)
        // 系列ごとに位置の上限ぶんのセルを分けると、使わない系列のセルまで確保する。系列でセルを共有する
        contextParams.kv_unified = true
        contextParams.type_k = Self.kvType
        contextParams.type_v = Self.kvType
        contextParams.no_perf = true
        // flash attention は、genmai-310M の単精度の KV キャッシュでは出力を変えずに 1 打鍵の表示を遅くする
        contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED
        guard let context = llama_init_from_model(model, contextParams) else { fatalError("llama.cpp のコンテキストを作れない: \(weight.path)") }
        resources = LlamaResources(model: model, context: context)
        LiveLlamaResources.add(resources)
        batch = llama_batch_init(Int32(Self.batchCapacity(maxPositions: maxPositions)), 0, Int32(Self.naturalnessSequences))
        bos = llama_vocab_bos(vocab)
        eos = llama_vocab_eos(vocab)
        vocabularySize = Int(llama_vocab_n_tokens(vocab))
    }

    deinit {
        llama_batch_free(batch)
        LiveLlamaResources.remove(resources)
        resources.release()
    }

    func generate(_ requests: [GenerationRequest]) -> [String] {
        var results: [String] = []
        var rest = requests[...]
        while !rest.isEmpty {
            let group = Array(rest.prefix(Self.generationSequences))
            rest = rest.dropFirst(group.count)
            results += generateTogether(group)
        }
        return results
    }

    /// 文ごとに系列を 1 つ使い、naturalnessSequences 個ずつ 1 回の decode で測る。表示の生成の系列には触れないので、生成の使い回しは壊れない。
    /// 文の前に置く入力は全系列で同じなので、前と同じなら計算し直さず、文の部分だけを消して入れ直す。
    /// 文の前に置く入力は、生成で出力に位置の半分を充てるのと同じく、位置の半分までに左の文脈を前から削る。
    /// 削る量は一緒に測る文によらず左の文脈だけで決まるので、同じ文と左の文脈は、いつ測っても同じ値になる。残りに収まらない文があれば nil
    func naturalness(left: String, texts: [String]) -> [Double]? {
        let bodies = texts.map { Array(tokenize(ZenzPrompt.naturalnessBody($0)).dropFirst()) }
        guard let longest = bodies.map(\.count).max() else { return [] }
        guard let prefix = fittedNaturalnessPrefix(left: left, room: maxPositions / 2), prefix.count + longest <= maxPositions else { return nil }
        var values: [Double] = []
        var rest = bodies[...]
        while !rest.isEmpty {
            // 同時に測る文の和と、文の前に置く入力が、文の確からしさのためのセル（位置の上限ぶん）に収まる組にする
            var group: [[llama_token]] = []
            var used = prefix.count
            while let body = rest.first, group.count < Self.naturalnessSequences, used + body.count <= maxPositions {
                group.append(body)
                used += body.count
                rest = rest.dropFirst()
            }
            values += scoreBodies(prefix: prefix, bodies: group)
        }
        return values
    }

    /// 文の確からしさを測るときに文の前に置く入力のうち、room トークン以内に収まるもの。左の文脈を前から削る。文脈を空にしても収まらなければ nil
    private func fittedNaturalnessPrefix(left: String, room: Int) -> [llama_token]? {
        var scalars = Array(left.unicodeScalars.suffix(ZenzPrompt.maxContextLength))
        while true {
            let prefix = tokenize(ZenzPrompt.naturalnessPrefix(left: String(String.UnicodeScalarView(scalars))))
            let over = prefix.count - room
            if over <= 0 { return prefix }
            if scalars.isEmpty { return nil }
            // 1 字は 1 トークン以上なので、超えたトークンの数だけ字を削れば、少なくともその数のトークンが減る
            scalars.removeFirst(min(over, scalars.count))
        }
    }

    /// 文の確からしさを測る系列の番号。表示の生成の系列の後ろに置く
    private static let naturalnessSequenceIDs = (generationSequences..<(generationSequences + naturalnessSequences)).map { llama_seq_id($0) }

    /// 文の確からしさを測る系列の先頭から bodies の数までに、prefix の後ろへ bodies をそれぞれ置き、各 body のトークンの対数確率の和を返す
    private func scoreBodies(prefix: [llama_token], bodies: [[llama_token]]) -> [Double] {
        let memory = llama_get_memory(context)
        let sequences = Self.naturalnessSequenceIDs
        let reuse = naturalnessPrefix?.tokens == prefix
        for seq in sequences {
            guard llama_memory_seq_rm(memory, seq, reuse ? Int32(prefix.count) : 0, -1) else { fatalError("KV キャッシュを消せない") }
        }
        batch.n_tokens = 0
        func add(_ token: llama_token, position: Int, seqs: [llama_seq_id], logits: Bool) {
            let i = Int(batch.n_tokens)
            batch.token[i] = token
            batch.pos[i] = Int32(position)
            batch.n_seq_id[i] = Int32(seqs.count)
            for (j, seq) in seqs.enumerated() { batch.seq_id[i]![j] = seq }
            batch.logits[i] = logits ? 1 : 0
            batch.n_tokens += 1
        }
        if !reuse {
            for (position, token) in prefix.enumerated() {
                add(token, position: position, seqs: sequences, logits: position == prefix.count - 1)
            }
        }
        // body ごとに、最後のトークンを除く位置の logits から次のトークンの確率を求める
        var bodyStarts: [Int] = []
        for (k, body) in bodies.enumerated() {
            bodyStarts.append(Int(batch.n_tokens))
            for (offset, token) in body.enumerated() {
                add(token, position: prefix.count + offset, seqs: [sequences[k]], logits: offset < body.count - 1)
            }
        }
        guard batch.n_tokens == 0 || llama_decode(context, batch) == 0 else { fatalError("llama.cpp の decode が失敗した") }
        if !reuse {
            naturalnessPrefix = (prefix, logSoftmax(batchIndex: Int(batch.n_tokens) - bodies.reduce(0) { $0 + $1.count } - 1))
        }
        let first = naturalnessPrefix!.next
        return bodies.enumerated().map { k, body in
            guard let head = body.first else { return 0 }
            var total = first[Int(head)]
            for offset in body.indices.dropFirst() {
                total += logSoftmax(batchIndex: bodyStarts[k] + offset - 1)[Int(body[offset])]
            }
            return total
        }
    }

    /// batch の i 番目の位置の、次のトークンの対数確率の表。logits が有限でなければ止める
    private func logSoftmax(batchIndex i: Int) -> [Double] {
        let logits = llama_get_logits_ith(context, Int32(i))!
        var top = -Double.infinity
        for v in 0..<vocabularySize {
            guard logits[v].isFinite else { fatalError("モデルの計算が壊れた（logits が有限でない）。KV キャッシュの型と flash attention を見直す") }
            top = max(top, Double(logits[v]))
        }
        var sum = 0.0
        for v in 0..<vocabularySize { sum += exp(Double(logits[v]) - top) }
        let normalizer = top + log(sum)
        return (0..<vocabularySize).map { Double(logits[$0]) - normalizer }
    }

    func reset() {
        for slot in slots.indices { truncate(slot, to: 0) }
        drafts = [:]
        let memory = llama_get_memory(context)
        for seq in Self.naturalnessSequenceIDs {
            guard llama_memory_seq_rm(memory, seq, 0, -1) else { fatalError("KV キャッシュを消せない") }
        }
        naturalnessPrefix = nil
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

    /// requests を、1 つずつ別の系列で同時に生成する。各要求の次に decode するトークンを 1 回の decode にまとめる。
    /// 要求ごとの手順（区切りの分け方・下書き・使い回し）は 1 つずつ生成するときと同じ
    private func generateTogether(_ requests: [GenerationRequest]) -> [String] {
        var jobs = requests.map { GenerationJob(left: $0.left, parts: ZenzPrompt.chunks($0.kana, maxLength: ZenzPrompt.maxChunkLength(positions: maxPositions))[...]) }
        var free = slotOrder
        for k in jobs.indices { advance(&jobs[k], free: &free) }
        while jobs.contains(where: { $0.pending != nil }) {
            batch.n_tokens = 0
            var starts: [Int?] = []
            for job in jobs {
                guard let pending = job.pending else {
                    starts.append(nil)
                    continue
                }
                starts.append(Int(batch.n_tokens))
                let start = slots[job.slot!].resident.count
                for (i, token) in pending.tokens.enumerated() {
                    let b = Int(batch.n_tokens)
                    batch.token[b] = token
                    batch.pos[b] = Int32(start + i)
                    batch.n_seq_id[b] = 1
                    batch.seq_id[b]![0] = llama_seq_id(job.slot!)
                    batch.logits[b] = start + i >= pending.needFrom ? 1 : 0
                    batch.n_tokens += 1
                }
            }
            guard llama_decode(context, batch) == 0 else { fatalError("llama.cpp の decode が失敗した") }
            for k in jobs.indices {
                guard let pending = jobs[k].pending, let first = starts[k] else { continue }
                record(pending, batchStart: first, slot: jobs[k].slot!)
                jobs[k].pending = nil
                advance(&jobs[k], free: &free)
            }
        }
        return jobs.map { ZenzPrompt.restoreSpaces($0.output) }
    }

    /// job を、次に decode が要るところか、生成し終えるところまで進める。区切りを生成し終えたら次の区切りに移る。
    /// 系列は最初の区切りで free から選び、その後は同じ系列を使う
    private func advance(_ job: inout GenerationJob, free: inout [Int]) {
        while true {
            if let chunk = job.chunk {
                let slot = job.slot!
                while job.out.count < chunk.limit {
                    let token = slots[slot].next[chunk.prompt.count - 1 + job.out.count]!
                    if token == eos { break }
                    job.out.append(token)
                    let position = chunk.prompt.count + job.out.count - 1
                    if position < slots[slot].resident.count, slots[slot].resident[position] == token { continue }
                    truncate(slot, to: position)
                    job.pending = ([token], position)
                    return
                }
                drafts[chunk.contextText] = job.out
                job.output += ZenzPrompt.cutAtNewline(detokenize(job.out))
                job.chunk = nil
                job.out = []
            }
            guard let part = job.parts.popFirst() else { return }
            let contextText = job.left + job.output
            let limit = outputLimit(part)
            guard let prompt = fittedPrompt(context: contextText, kana: part, limit: limit) else {
                // 文脈を空にしても収まらない区切り（読みの字が複数のトークンになるとき）は、収まるまで半分に分ける。読みは削らない
                let halves = ZenzPrompt.halving([part]) { fittedPrompt(context: "", kana: $0, limit: outputLimit($0)) != nil }
                job.parts.insert(contentsOf: halves, at: job.parts.startIndex)
                continue
            }
            let sequence = prompt + (drafts[contextText] ?? []).prefix(limit)
            let needFrom = prompt.count - 1
            let slot = job.slot ?? takeSlot(for: sequence, from: &free)
            job.slot = slot
            job.chunk = (contextText, prompt, limit)
            var keep = slots[slot].commonPrefix(with: sequence)
            // 入力の最後から先は argmax が要る。持ち越す範囲で求めていない位置があれば、そこから計算し直す
            if let missing = (needFrom..<max(needFrom, keep)).first(where: { slots[slot].next[$0] == nil }) { keep = missing }
            truncate(slot, to: keep)
            guard keep == sequence.count else {
                job.pending = (Array(sequence[keep...]), needFrom)
                return
            }
        }
    }

    /// free のうち sequence と先頭が最も長く一致する系列を取り出す。同じ長さなら最後に使ったのが古い方にする
    private func takeSlot(for sequence: [llama_token], from free: inout [Int]) -> Int {
        let slot = free.max { slots[$0].commonPrefix(with: sequence) < slots[$1].commonPrefix(with: sequence) }!
        free.removeAll { $0 == slot }
        slotOrder.removeAll { $0 == slot }
        slotOrder.append(slot)
        return slot
    }

    private func truncate(_ slot: Int, to count: Int) {
        guard slots[slot].resident.count > count else { return }
        guard llama_memory_seq_rm(llama_get_memory(context), llama_seq_id(slot), Int32(count), -1) else { fatalError("KV キャッシュを消せない") }
        slots[slot].resident.removeLast(slots[slot].resident.count - count)
        slots[slot].next.removeLast(slots[slot].next.count - count)
    }

    /// decode した pending を系列 slot の後ろに足し、位置 needFrom 以降の argmax を next に足す。batchStart は pending の先頭の batch の位置。
    /// 計算が壊れると logits が有限でなくなる。そのまま argmax を取るとエラーにならずに壊れた出力を返すので、止める
    private func record(_ pending: (tokens: [llama_token], needFrom: Int), batchStart: Int, slot: Int) {
        let start = slots[slot].resident.count
        for i in 0..<pending.tokens.count {
            guard start + i >= pending.needFrom else {
                slots[slot].next.append(nil)
                continue
            }
            let logits = llama_get_logits_ith(context, Int32(batchStart + i))!
            var best = 0
            var finite = logits[0].isFinite
            for v in 1..<vocabularySize {
                finite = finite && logits[v].isFinite
                if logits[v] > logits[best] { best = v }
            }
            guard finite else { fatalError("モデルの計算が壊れた（logits が有限でない）。KV キャッシュの型と flash attention を見直す") }
            slots[slot].next.append(llama_token(best))
        }
        slots[slot].resident += pending.tokens
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

/// 生成中の 1 つの要求。parts は残りの区切り、chunk は生成中の区切り、out はその区切りで生成したトークン、
/// pending は次に decode するトークンとその中で argmax が要る最初の位置
private struct GenerationJob {
    let left: String
    var parts: ArraySlice<String>
    var output = ""
    var slot: Int?
    var chunk: (contextText: String, prompt: [llama_token], limit: Int)?
    var out: [llama_token] = []
    var pending: (tokens: [llama_token], needFrom: Int)?

    init(left: String, parts: ArraySlice<String>) {
        self.left = left
        self.parts = parts
    }
}

/// 表示の生成の系列 1 本の KV キャッシュに入っているトークンと、各位置の直後の argmax。KV を消したら同じだけ縮める。
/// argmax は、そのトークンを足したときの入力の最後の位置より前では求めないので nil になる
private struct GenerationSlot {
    var resident: [llama_token] = []
    var next: [llama_token?] = []

    /// resident と sequence の先頭が一致する長さ
    func commonPrefix(with sequence: [llama_token]) -> Int {
        zip(resident, sequence).prefix { $0 == $1 }.count
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
