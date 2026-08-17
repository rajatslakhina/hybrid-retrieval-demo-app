# HybridRetrieval Demo

**A runnable iOS app that makes an on-device hybrid retrieval system's *failure behavior* visible: flip one switch and watch a source blow its deadline, the query still return partial results, and the per-source report say so out loud.**

This app consumes [`hybrid-retrieval-kit`](https://github.com/rajatslakhina/hybrid-retrieval-kit) as a **version-pinned remote Swift Package** (`upToNextMajorVersion` from `1.1.0`) — not a local path, not a branch. It is deliberately a separate repo: the library stays a clean, app-target-free package that anyone can add to their own project, and this repo exercises the published artifact exactly the way a stranger's project would.

## Why this matters

Most retrieval demos show you a result list. A result list is the easy half. The hard half — the half a staff engineer gets asked about — is what the system does when a source is slow, when a source lies, and when the answer you're about to feed a language model is *incomplete*. This app puts those three on screen:

- **Degradation is visible, not hidden.** Toggle *"Inject a deadline-busting source"* and the app adds a source that sleeps 5s against a 400ms per-source deadline. The query still returns at the deadline, the healthy sources' results still rank, and the report row for `backend.slow` reads **TIMED OUT** with a banner stating the response is partial by design.
- **A source that lies is caught and counted.** Toggle *"Inject misbehaving sources"* and the app adds `vendor.leaky` — which returns `sensitive` content to every query regardless of tier — plus `backend.broken`, which always throws. The leaked row never reaches the results; its report row shows **1 privacy violation filtered**, and `backend.broken` shows **FAILED** while the query still returns everyone else's hits. That is the library's defense-in-depth claim, on screen, rather than in a bullet point.
- **The privacy boundary is a control you can move.** The bundled corpus is tagged `open` / `personal` / `sensitive`. The segmented picker *is* the query's privacy context: at `open`, the on-call runbook and health log are unreachable; raise it and they enter the result set. Enforcement happens inside the library twice over — in the store's searches and again at the orchestrator, on whatever any third-party source returns.
- **Ranking is explainable.** Every result row shows which sources contributed it (`lexical.bm25`, `vector.cosine`, `spotlight.simulated`) and its fused RRF score, so a consensus hit is distinguishable from a lexical-only or vector-only one at a glance.
- **The pluggable-source seam is exercised, not just documented.** The app ships four of its own `RetrievalSource` conformances — a `SimulatedSpotlightSource` standing in for a `CSSearchQuery`-backed adapter, plus the slow, leaky and failing ones — fanned out and fused alongside the library's built-ins.

## What's on screen

A single `NavigationStack` with three sections:

1. **Query** — text field, privacy-context picker, the two fault-injection toggles, and a live "14 chunks indexed across 10 documents" status line (14, not 10, because two documents are long enough to exercise the chunker's sliding window and boundary overlap).
2. **Results** — fused hits, each with its text, document id, tier badge, contributing-source chips, and RRF score.
3. **Per-source report** — one row per source: `OK · n` / `TIMED OUT` / `FAILED` / `CANCELLED`, measured latency in ms, and a count of any privacy violations the orchestrator filtered out.

Try `deadline`, `fusion`, `actors`, or `spotlight`; then flip a toggle and search again. Measured against the real library with this exact corpus and configuration, `deadline` at the `open` tier returns 3 fused hits (`lexical.bm25` 2, `spotlight.simulated` 1, `vector.cosine` 1); at `sensitive` it returns 4.

## Design decisions (this app, not the library)

**Rebuild the whole engine when a toggle flips, rather than mutating a live source list.** `RetrievalOrchestrator` is deliberately immutable and stateless — its source set is fixed at construction, which is what makes it `Sendable` and concurrent-query-safe. Rather than punch a mutation hole in that design for a demo affordance, the app throws the engine away and re-indexes (10 documents, milliseconds). Rejected: making the orchestrator's source list mutable, which would have traded a real concurrency property for UI convenience.

**A hand-rolled `SimulatedSpotlightSource` instead of real `CoreSpotlight`.** A genuine `CSSearchQuery` adapter needs donated `CSSearchableItem`s, a populated on-device index, and entitlements — none of which a reviewer cloning this repo will have, and all of which would make the app's behavior depend on the machine it runs on. The simulated source has the same shape (its own corpus, its own scoring, its own `SourceID`) and demonstrates the same seam deterministically. The trade-off is honest: this proves the *architecture* accommodates Spotlight, not that a Spotlight adapter has shipped.

**Fault injection as first-class UI.** Most demos hide their failure paths behind unit tests. Here the timed-out, failed and privacy-violation branches are reachable by tapping a switch, because the entire thesis of the library is that degradation must be *observable*. A demo that only ever shows the happy path would undercut the claim it exists to support.

**`upToNextMajorVersion` from a released tag, with no committed `Package.resolved`.** Pinning to a version (not `branch = main`) means this project builds the same way in a year. Leaving `Package.resolved` out keeps the repo honest about what it actually pins — the requirement lives in one place, `project.pbxproj`. Rejected: `exact:`, which would make the demo a maintenance burden on every library patch release.

**A 400ms per-source deadline.** Long enough that the in-memory sources never trip it, short enough that a human watching the screen sees the timeout resolve immediately rather than wondering whether the app hung.

## Screenshots

**None. There are no screenshots in this repository, and no `Demo/Screenshots/` directory exists.**

This run was executed as an unattended scheduled task. Screen-control access was granted, but the machine's Xcode already had an unrelated production workspace open with live edits, and two Simulators were running unrelated apps. Driving that machine would have meant clicking through someone else's work in progress, so the run stopped instead of proceeding. Nothing was launched, so there is nothing to screenshot — see [Verification](#verification) for exactly what *was* proven.

## How to run it

```bash
git clone https://github.com/rajatslakhina/hybrid-retrieval-demo-app.git
cd hybrid-retrieval-demo-app
open Demo.xcodeproj
```

Then in Xcode: wait for **Package Dependencies** to resolve `hybrid-retrieval-kit` from GitHub (first open only), select the shared **Demo** scheme, pick any iOS 17+ Simulator, and **⌘R**. No signing setup, no local checkout of the library, no `Info.plist` to fix.

## Verification

Exactly what has and has not been checked, in descending order of strength — no step is used to imply a stronger one:

1. **The app's own logic was executed against the real library.** `DemoCorpus` and the four `RetrievalSource` conformances were compiled against `HybridRetrieval` and run headlessly on Swift 6.0.3, which is where the numbers in this README come from: 14 indexed chunks across 10 documents; `deadline`/`fusion`/`actors`/`spotlight` all return hits; the leaky source's `sensitive` row is dropped with `privacyViolationsFiltered == 1`; the failing source reports `FAILED` while the query still returns other sources' hits.
2. **CI compiled the whole app target — views included — against the published package, and it passed.** The [CI workflow](https://github.com/rajatslakhina/hybrid-retrieval-demo-app/actions) runs on `macos-15` and does what a stranger's first clone does: `xcodebuild -resolvePackageDependencies` (proving the version-pinned remote dependency genuinely resolves from GitHub — not from any local checkout) followed by `xcodebuild build -scheme Demo -destination 'generic/platform=iOS Simulator'`. Both steps succeeded on the head commit. The generic destination is intentional — a named device would tie the job to whichever simulator runtimes that day's runner image happens to ship. The Actions tab is the live source of truth; prefer it to this sentence.
3. **Nobody has launched this app.** Compiling for an iOS Simulator destination is strictly weaker than running on a Simulator, and neither claim above is used to mean that one. No Simulator run happened: this was an unattended scheduled run, and although screen-control access was granted, the machine's Xcode had an unrelated production workspace open with live edits and two Simulators were running unrelated apps, so the run stopped rather than clicking through someone else's work. Nothing was installed, launched, tapped or screenshotted.

The library it depends on is verified independently: a clean `swift build -Xswiftc -warnings-as-errors` plus `swift test` — **72 tests, 0 failures** on Swift 6.0.3 — re-run by [its own CI](https://github.com/rajatslakhina/hybrid-retrieval-kit/actions) on every push.

## The library

[**rajatslakhina/hybrid-retrieval-kit**](https://github.com/rajatslakhina/hybrid-retrieval-kit) — BM25 + vector fusion via RRF, per-source deadlines that hold even against cancellation-ignoring sources, privacy tiers, and an indexing actor that commits by sequence number rather than wall clock. Design decisions and rejected alternatives are written up there.

## License

MIT — see [LICENSE](LICENSE).
