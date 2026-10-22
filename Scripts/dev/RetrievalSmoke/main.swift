import Foundation

/// Functional smoke test for the retrieval core, runnable without Xcode.
///
///   swiftc -O -I Scripts/dev/SQLite3 -L <dir with libsqlite3> \
///       App/Sources/Support/*.swift App/Sources/Retrieval/*.swift \
///       App/Sources/Engine/LLMEngine.swift App/Sources/Engine/PromptBuilder.swift \
///       Scripts/dev/RetrievalSmoke/main.swift -o /tmp/retrieval-smoke
///   /tmp/retrieval-smoke App/Resources/corpus.sqlite
///
/// It exercises the same code the app runs: CorpusStore (SQLite/FTS5), RetrievalService
/// (query plan -> bm25 -> dedupe -> rerank), ExtractiveComposer (sentence selection) and
/// PromptBuilder (budgeted prompt). Exit code is non-zero if any expectation fails.

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: retrieval-smoke <corpus.sqlite>\n".utf8))
    exit(2)
}

let corpusURL = URL(fileURLWithPath: args[1])
guard FileManager.default.fileExists(atPath: corpusURL.path) else {
    FileHandle.standardError.write(Data("missing corpus: \(corpusURL.path)\n".utf8))
    exit(2)
}

var failures = 0

func check(_ condition: Bool, _ label: String, detail: String = "") {
    if condition {
        print("  ok    \(label)")
    } else {
        print("  FAIL  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        failures += 1
    }
}

do {
    let store = try CorpusStore(url: corpusURL)
    let articles = try store.articleCount()
    let chunks = try store.chunkCount()
    let integrity = try store.integrityCheck()
    let meta = try store.metadata()

    print("corpus: \(articles) articles, \(chunks) chunks, integrity=\(integrity), schema=\(meta["schema_version"] ?? "?")")
    check(articles > 50, "article count > 50", detail: "\(articles)")
    check(chunks > 200, "chunk count > 200", detail: "\(chunks)")
    check(integrity == "ok", "quick_check ok", detail: integrity)

    let retriever = RetrievalService(store: store)

    let cases: [(question: String, expected: String)] = [
        ("Why does TCP congestion control shrink its window on loss?", "TCP congestion control"),
        ("How does a Kalman filter combine a prediction with a noisy measurement?", "Kalman filter"),
        ("What limits the efficiency of a single junction solar cell?", "Solar cell"),
        ("How does a bloom filter produce false positives but no false negatives?", "Bloom filter"),
        ("Why is delta-v the real currency of space missions?", "Delta-v"),
        ("How does write ahead logging make a database crash safe?", "Write-ahead logging"),
    ]

    print("\nretrieval:")
    var hits = 0
    var latencies: [Double] = []
    for item in cases {
        let result = try retriever.retrieve(item.question)
        latencies.append(result.elapsed)
        let top = result.passages.first?.passage.title ?? "(none)"
        let ok = result.passages.contains { $0.passage.title == item.expected }
        if ok { hits += 1 }
        print(String(format: "  %@  top=%@  strategy=%@  candidates=%d  %.1fms",
                     ok ? "ok  " : "MISS", top, result.strategy, result.candidates, result.elapsed * 1000))
        check(ok, "expected \(item.expected)", detail: "top was \(top)")
    }
    print("  \(hits)/\(cases.count) questions retrieved the expected document")

    // Empty query must not degenerate into a full scan.
    let empty = try retriever.retrieve("the and of")
    check(empty.passages.isEmpty, "stopword-only query returns nothing")

    // Extractive composition over a real query.
    let result = try retriever.retrieve("How does PCR amplify a specific DNA sequence?")
    let answer = ExtractiveComposer.compose(query: "How does PCR amplify a specific DNA sequence?", passages: result.passages)
    print("\nextractive answer (\(answer.text.count) chars, citations \(answer.usedCitations)):")
    print("  " + answer.text.split(separator: "\n").prefix(4).joined(separator: "\n  ").prefix(600))
    check(!answer.text.isEmpty, "extractive answer is non-empty")
    check(!answer.usedCitations.isEmpty, "extractive answer cites at least one passage")

    // Prompt assembly.
    let turns = PromptBuilder.messages(question: "How does PCR amplify DNA?", passages: result.passages)
    let promptChars = turns.reduce(0) { $0 + $1.content.count }
    print("\nprompt: \(turns.count) turns, \(promptChars) chars (~\(TextUtil.estimatedTokens(turns.map(\.content).joined())) tokens)")
    check(turns.first?.role == .system, "prompt starts with system turn")
    check((turns.last?.content ?? "").contains("QUESTION:"), "prompt ends with the question")
    check(promptChars < 20000, "prompt stays under the 4096-token budget")

    // Determinism: same query twice, same top chunk.
    let a = try retriever.retrieve("How does the immune system tell self from non-self?")
    let b = try retriever.retrieve("How does the immune system tell self from non-self?")
    check(a.passages.first?.passage.chunkID == b.passages.first?.passage.chunkID, "retrieval is deterministic")

    let p95 = latencies.sorted()[max(0, latencies.count - 1)]
    print(String(format: "\nretrieval latency: max %.1fms over %d queries", p95 * 1000, latencies.count))
} catch {
    print("ERROR: \(error)")
    exit(1)
}

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
