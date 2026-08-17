import Foundation
import SwiftUI
import HybridRetrieval

// MARK: - App

/// Demo host for `HybridRetrieval` (consumed as a remote Swift Package, pinned to a
/// release tag). The app owns what a real integrator owns: the corpus, the engine
/// configuration, and two custom `RetrievalSource` implementations that exercise the
/// library's pluggable-source seam — including one that exists purely to violate its
/// deadline so the graceful-degradation path is visible in the UI.
@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Bundled corpus (the app-owned, compiled-in data the library indexes)

/// The app owns the corpus; the library owns retrieval. Two documents are deliberately
/// long enough to exceed the chunker's 48-token window, so `SentenceWindowChunker`'s
/// windowing and boundary-sentence overlap are visible in the indexed-chunk count
/// rather than being a feature you have to take on faith.
enum DemoCorpus {
    static let documents: [Document] = [
        Document(
            id: DocumentID("wwdc-foundation-models"),
            text: "WWDC26 gave Foundation Models a Spotlight-backed search tool. "
                + "It performs local retrieval with no embeddings and no vector database. "
                + "The convenience ends where private in-app corpora begin. "
                + "Spotlight cannot see data your app never donated to it, and it cannot rank "
                + "structured domain records the way your product needs them ranked. "
                + "At that point you own an indexing pipeline, a ranking policy, and a freshness "
                + "guarantee, whether or not you planned to own them. "
                + "The question stops being which API to call and starts being which failure "
                + "modes you are willing to ship.",
            tier: .open
        ),
        Document(
            id: DocumentID("wwdc-containment"),
            text: "Tool calling should be sandboxed with a deadline and a retry policy. "
                + "Provenance of tool results matters for debugging agent behavior.",
            tier: .open
        ),
        Document(
            id: DocumentID("bm25-notes"),
            text: "BM25 saturates term frequency and normalizes document length. "
                + "Rare terms carry more signal than common terms. "
                + "Lexical search wins on exact identifiers and error codes.",
            tier: .open
        ),
        Document(
            id: DocumentID("vector-notes"),
            text: "Vector similarity finds paraphrases that lexical search misses. "
                + "Embedding quality decides recall. Hybrid ranking fuses both worlds. "
                + "A similarity floor is what separates a search from a ranking: without one, "
                + "a nearest-neighbour index returns the entire corpus ordered by noise for a "
                + "query that matches nothing at all. "
                + "That is worse than an empty result, because the fusion layer then hands "
                + "rank-one weight to the least bad piece of garbage in the index.",
            tier: .open
        ),
        Document(
            id: DocumentID("rrf-notes"),
            text: "Reciprocal rank fusion merges rankings using positions, not raw scores. "
                + "Score normalization across heterogeneous sources is brittle. "
                + "RRF degrades gracefully when a source misses its deadline.",
            tier: .open
        ),
        Document(
            id: DocumentID("actor-isolation"),
            text: "Actors serialize access to mutable state. "
                + "Reentrancy across await suspension points reorders interleavings. "
                + "Commit protocols must re-check preconditions after every suspension.",
            tier: .open
        ),
        Document(
            id: DocumentID("project-sync-plan"),
            text: "My sync engine plan: write-ahead queue, sequence numbers from the server, "
                + "last-writer-wins by sequence not by wall clock. Ship behind a flag in March.",
            tier: .personal
        ),
        Document(
            id: DocumentID("project-review-notes"),
            text: "Review feedback on my retrieval prototype: give every source a deadline, "
                + "surface degraded responses to the caller, never trust source ordering.",
            tier: .personal
        ),
        Document(
            id: DocumentID("oncall-runbook"),
            text: "Private on-call notes: the staging API key rotates on the first Monday. "
                + "Escalation contact for search outages is the platform team pager.",
            tier: .sensitive
        ),
        Document(
            id: DocumentID("health-log"),
            text: "Personal health log: sleep quality dropped during the release week. "
                + "Migraine triggers correlate with late-night incident calls.",
            tier: .sensitive
        )
    ]
}

// MARK: - Custom sources (the pluggable-seam demonstration)

/// Stands in for a `CSSearchQuery`-backed Spotlight adapter: an app-owned source with
/// its own tiny corpus and its own scoring, fanned out and fused like any other source.
struct SimulatedSpotlightSource: RetrievalSource {
    let id: SourceID = "spotlight.simulated"

    private static let entries: [(DocumentID, String)] = [
        (DocumentID("spotlight-faq-hybrid"), "Hybrid retrieval combines lexical and vector search results."),
        (DocumentID("spotlight-faq-spotlight"), "Spotlight indexes app content via CSSearchableItem donations."),
        (DocumentID("spotlight-faq-deadline"), "A deadline bounds how long retrieval waits for a source.")
    ]

    func retrieve(_ query: RetrievalQuery) async throws -> [ScoredChunk] {
        let terms = Set(Tokenizer.tokenize(query.text))
        guard !terms.isEmpty else { return [] }
        return Self.entries.compactMap { docID, text -> ScoredChunk? in
            let tokens = Set(Tokenizer.tokenize(text))
            let overlap = terms.intersection(tokens).count
            guard overlap > 0 else { return nil }
            return ScoredChunk(
                id: ChunkID(document: docID, ordinal: 0),
                text: text,
                tier: .open,
                score: Double(overlap)
            )
        }
        .sorted { $0.score > $1.score }
    }
}

/// Deliberately violates its deadline (cooperatively) so the orchestrator's
/// degradation path — partial results + a TIMED OUT report — is visible live.
struct DeliberatelySlowSource: RetrievalSource {
    let id: SourceID = "backend.slow"

    func retrieve(_ query: RetrievalQuery) async throws -> [ScoredChunk] {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return []
    }
}

/// Violates the privacy contract on purpose: returns `sensitive` content no matter what
/// tier the query allows. The orchestrator must drop it *and* count it, which is what
/// turns "defense in depth" from a README claim into something you can watch happen.
struct ContractViolatingSource: RetrievalSource {
    let id: SourceID = "vendor.leaky"

    func retrieve(_ query: RetrievalQuery) async throws -> [ScoredChunk] {
        [
            ScoredChunk(
                id: ChunkID(document: DocumentID("leaked-credentials"), ordinal: 0),
                text: "LEAKED: production signing key — this row must never reach you at .open",
                tier: .sensitive,
                score: 99
            ),
            ScoredChunk(
                id: ChunkID(document: DocumentID("vendor-faq"), ordinal: 0),
                text: "Vendor FAQ: retrieval sources are fanned out with independent deadlines.",
                tier: .open,
                score: 1
            )
        ]
    }
}

/// Always throws, so the `FAILED` disposition is reachable in the UI. A source that is
/// simply broken must cost you that source, never the query.
struct AlwaysFailingSource: RetrievalSource {
    struct Unavailable: Error, CustomStringConvertible {
        var description: String { "Unavailable(backend returned 503)" }
    }

    let id: SourceID = "backend.broken"

    func retrieve(_ query: RetrievalQuery) async throws -> [ScoredChunk] {
        throw Unavailable()
    }
}

// MARK: - Engine state

@MainActor
@Observable
final class DemoModel {
    enum IndexState: Equatable {
        case building
        case ready(chunks: Int)
        case failed(String)
    }

    private(set) var indexState: IndexState = .building
    private(set) var response: RetrievalResponse?
    private(set) var lastQueryText = ""
    private(set) var isSearching = false
    var queryText = ""
    var maxTier: PrivacyTier = .open
    var includeSlowSource = false {
        didSet { rebuildEngine() }
    }
    var includeMisbehavingSources = false {
        didSet { rebuildEngine() }
    }

    private var engine: HybridSearchEngine?

    init() {
        rebuildEngine()
    }

    private func rebuildEngine() {
        indexState = .building
        response = nil
        var extras: [any RetrievalSource] = [SimulatedSpotlightSource()]
        if includeSlowSource {
            extras.append(DeliberatelySlowSource())
        }
        if includeMisbehavingSources {
            extras.append(ContractViolatingSource())
            extras.append(AlwaysFailingSource())
        }
        let engine = HybridSearchEngine(
            extraSources: extras,
            configuration: OrchestratorConfiguration(
                perSourceDeadline: .milliseconds(400),
                maxResults: 8,
                minimumFulfilledSources: 1
            )
        )
        self.engine = engine
        Task { [weak self] in
            do {
                var sequence: UInt64 = 0
                var chunkTotal = 0
                for document in DemoCorpus.documents {
                    sequence += 1
                    let result = try await engine.apply(.upsert(document, sequence: sequence))
                    if case .applied(let chunks, _) = result {
                        chunkTotal += chunks
                    }
                }
                self?.indexState = .ready(chunks: chunkTotal)
            } catch {
                self?.indexState = .failed(String(describing: error))
            }
        }
    }

    func search() {
        guard let engine, case .ready = indexState else { return }
        let text = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            response = nil
            lastQueryText = ""
            return
        }
        isSearching = true
        lastQueryText = text
        let query = RetrievalQuery(text: text, maxTier: maxTier, perSourceLimit: 10)
        Task { [weak self] in
            let result = await engine.search(query)
            self?.response = result
            self?.isSearching = false
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @State private var model = DemoModel()

    var body: some View {
        NavigationStack {
            List {
                controlsSection
                resultsSection
                reportSection
            }
            .navigationTitle("Hybrid Retrieval")
            .animation(.default, value: model.response?.hits.count ?? 0)
        }
    }

    private var controlsSection: some View {
        Section("Query") {
            HStack {
                TextField("Try: deadline, fusion, actors…", text: $model.queryText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { model.search() }
                Button("Search") { model.search() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.indexState == .building)
            }

            Picker("Privacy context", selection: $model.maxTier) {
                Text("Open").tag(PrivacyTier.open)
                Text("Personal").tag(PrivacyTier.personal)
                Text("Sensitive").tag(PrivacyTier.sensitive)
            }
            .pickerStyle(.segmented)

            Toggle("Inject a deadline-busting source", isOn: $model.includeSlowSource)
            Toggle("Inject misbehaving sources (leaky + failing)", isOn: $model.includeMisbehavingSources)

            switch model.indexState {
            case .building:
                Label("Building index…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            case .ready(let chunks):
                Label("\(chunks) chunks indexed across \(DemoCorpus.documents.count) documents",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label("Indexing failed: \(message)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if let response = model.response {
            Section("Results for “\(model.lastQueryText)”") {
                if response.hits.isEmpty {
                    Text("No results at this privacy tier.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(response.hits, id: \.chunk.id) { hit in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(hit.chunk.text)
                                .font(.callout)
                            HStack(spacing: 6) {
                                Text(hit.chunk.id.document.rawValue)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                TierBadge(tier: hit.chunk.tier)
                                ForEach(hit.contributingSources, id: \.self) { source in
                                    Text(source.rawValue)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.15), in: Capsule())
                                }
                                Spacer()
                                Text(String(format: "%.4f", hit.fusedScore))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        } else if model.isSearching {
            Section { ProgressView("Fanning out…") }
        }
    }

    @ViewBuilder
    private var reportSection: some View {
        if let response = model.response {
            Section("Per-source report") {
                ForEach(response.reports, id: \.source) { report in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.source.rawValue)
                                .font(.caption.monospaced())
                            if report.privacyViolationsFiltered > 0 {
                                Text("\(report.privacyViolationsFiltered) privacy violation(s) filtered")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        DispositionBadge(disposition: report.disposition)
                        Text(Self.milliseconds(report.latency))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if !response.isComplete {
                    Label("Degraded response: some sources missed their deadline; results below are partial by design.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let total = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.0f ms", total)
    }
}

struct TierBadge: View {
    let tier: PrivacyTier

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch tier {
        case .open: "open"
        case .personal: "personal"
        case .sensitive: "sensitive"
        }
    }

    private var color: Color {
        switch tier {
        case .open: .green
        case .personal: .blue
        case .sensitive: .red
        }
    }
}

struct DispositionBadge: View {
    let disposition: SourceReport.Disposition

    var body: some View {
        Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch disposition {
        case .fulfilled(let count): "OK · \(count)"
        case .timedOut: "TIMED OUT"
        case .failed: "FAILED"
        case .cancelled: "CANCELLED"
        }
    }

    private var color: Color {
        switch disposition {
        case .fulfilled: .green
        case .timedOut: .orange
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}

#Preview {
    ContentView()
}
