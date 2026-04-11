# Changelog

> **Note:** Versions 0.3.24 – 0.3.54 were released as git tags without changelog entries. Changelog resumes at 0.3.55 below.

## 0.3.77

### Added

- **SVAF fourth outcome — semantic redundancy pre-filter** (paper §4.5).
  `SymNode` now classifies an incoming CMB as *redundant* when every
  CAT7 field's vector has cosine similarity greater than
  `(1 − svafRedundancyThreshold)` with at least one existing anchor
  field's vector. The filter runs **before** the SVAFFusion drift
  classifier, because SVAF's fusion-based drift formula
  (`drift = 1 − cosSim(fused, incoming)`) collapses identical and
  orthogonal inputs to the same near-zero drift value — redundancy
  cannot be detected from drift output alone and requires a
  similarity-based check at the receive-handler pre-step.

- `SymNode.init` gains two new parameters:
  - `svafRedundancyThreshold: Float = 0.02` — per-instance, default
    is conservative (≥ 98% per-field similarity required to classify
    as redundant). Tune per agent based on the observed near-duplicate
    distribution in the production workload. Matches the per-instance
    pattern already established for `svafStableThreshold` and
    `svafGuardedThreshold`.
  - `svafRedundancyCheckEnabled: Bool = false` — feature flag, default
    **off** for backward compatibility. Existing SDK consumers who
    bump to this version see identical behaviour. Agents that want
    the fourth outcome opt in explicitly at init.

- `SymNode.isCMBRedundant(incoming:anchors:)` — internal helper method
  for the pre-filter logic. Exposed as `internal` rather than `private`
  so the dedicated test suite (`SVAFRedundancyTests`) can exercise it
  in isolation without spinning up a live peer session.

### Absorbed-anchor storage pattern

- Redundant CMBs are stored with a `sym.absorbed` tag rather than
  dropped entirely. This preserves the CMB key in local meshmem so
  future descendants (CMBs with this one as a lineage parent) are
  still caught by the existing lineage-based echo filter
  (`hasLocalKey`). The fusion pipeline filters absorbed entries out
  of the anchor set so they don't contaminate future fusion math.
  No schema change — uses the existing `tags: [String]` field on
  `CMBStoreEntry`.

- When `svafRedundancyCheckEnabled` is true, the anchor fetch path
  switches from `recentCMBs(limit: 5)` to a tag-filtered query over
  `allEntries()`. When the flag is off, the fast path is unchanged.

### Event semantics

- Redundant CMBs emit `.metric(type: "cmb-redundant", ...)` but do
  **not** emit `.cmbAccepted` or `.memoryReceived`. R5 mood
  passthrough does not fire on redundant CMBs — a redundant mood
  signal is by definition the same mood the receiver already has,
  so delivering it would be duplicate work and could trigger
  spurious re-curation.

### Tests

- 68 tests, 0 failures (59 pre-existing + 9 new).
  `SVAFRedundancyTests` covers:
  - Feature flag OFF by default and when explicitly disabled
  - Identical vectors → redundant
  - Orthogonal vectors → NOT redundant (critical — this is the
    case that distinguishes the pre-filter from the drift classifier)
  - Small perturbation at default 0.02 threshold → redundant
  - Tight threshold (0.0001) → small perturbation escapes classification
  - Single novel field blocks redundancy (AND-over-all-fields semantics)
  - Empty anchor set → always returns false
  - Multi-anchor set: redundancy fires if ANY anchor covers the incoming

### Paper alignment

- Paper §4.5 claim "four outcomes (redundant, aligned, guarded,
  rejected)" is now backed by shipping code. The CAPABILITY exists in
  the SDK; activation is per-agent via `svafRedundancyCheckEnabled`.

## 0.3.76

### Fixed

- **Bonjour auto-reconnect after peer disconnect.** When a peer's TCP
  connection drops (iOS backgrounding, wifi blip) but the mDNS record
  remains visible, the node now re-scans current browse results after 5s
  to attempt reconnection. Previously the peer was permanently lost until
  the SYM node was restarted, because `NWBrowser` doesn't re-fire
  `.added` events for services that never disappeared from mDNS.

- `SymDiscovery.retryVisiblePeers()` — re-evaluates current Bonjour
  browse results, called automatically after any peer disconnect.

### Tests

- 59 tests, 0 failures. Added 6 new tests: `hasLocalKey` echo loop
  detection (3 tests), purge/retention (2 tests), `recentCMBs` (1 test).

## 0.3.74

### Fixed

- **Echo loop prevention (MMP Section 14).** When node A broadcasts a CMB
  and node B remixes it back, node A now detects the echo by checking the
  incoming CMB's lineage parents against its own local meshmem keys. If any
  parent key exists locally, the CMB is a derivative of A's own broadcast —
  all processing is skipped, including mood delivery. This prevents
  ping-pong curation between same-app peers (e.g. two MeloTune instances
  where Mac→iPhone→Mac caused an 8-second genre revert loop).

### Added

- `SymMemoryStore.hasLocalKey(_:)` — checks if a CMB key exists in the
  node's local meshmem directory (persisted, survives restart).

## 0.3.73

### Fixed

- **Heartbeat timeout increased to 120s** (from 15s) to match Node.js SYM.
  The aggressive 15s timeout caused false peer disconnects during wifi
  blips, iCloud sync pauses, and iOS backgrounding. Check interval raised
  to 10s, ping threshold to 10s.

## 0.3.72

### Fixed

- Preserve `valence`/`arousal` structured floats on SVAF-fused CMB mood
  fields (MMP §8.2). Previously the fusion path dropped the numeric
  coordinates, causing downstream mood inference to fall back to keyword
  extraction instead of using the peer's actual circumplex values.

## 0.3.60

### Changed (MMP v0.2.2 spec conformance)

- **`state-sync` frame is now deprecated.** CfC hidden states never cross
  the wire under SVAF (Xu, 2026, *Symbolic-Vector Attention Fusion for
  Collective Intelligence*, [arXiv:2604.03955](https://arxiv.org/abs/2604.03955),
  §3.4). Cognitive coupling propagates as **CMBs** at SVAF Layer 4 only;
  the per-agent CfC at Layer 6 stays private to each agent.
- **`SymNode` no longer broadcasts `state-sync` frames.** Removed from
  the Bonjour and relay handshake paths and from `broadcastCurrentState()`,
  which is now a deprecated no-op. The `stateSyncInterval` constructor
  parameter is preserved for source compatibility but no longer schedules
  a timer.
- **`SymNode` no longer feeds incoming `state-sync` frames into the local
  CfC.** Frames received from older v0.2.0 / v0.2.1 peers are silently
  dropped with an `[SYM] state-sync: dropping deprecated frame ...` log
  line. Upgrade peers to MMP v0.2.2+ to silence the message.
- **`SymEvent.stateSyncReceived` is deprecated and no longer fired.** The
  case is preserved on the enum surface for source compatibility.
  Subscribers should consume `.cmbAccepted`, `.memoryReceived`, or
  `.moodDelivered` instead.
- The deprecated factory `SymFrame.stateSync(h1:h2:confidence:)` and the
  `h1` / `h2` / `confidence` fields on `SymFrame` are kept on the type
  for backward-compatible decoding of inbound v0.2.0 frames; senders MUST
  NOT populate them.

SYMCore xcframework unchanged from 0.3.59 — this is a pure Swift wrapper
change. No wire-format break for inbound parsing; outbound wire shrinks
by one frame type per peer.

### Migration

If you previously relied on `.stateSyncReceived` to drive a coupling
visualisation or downstream cognitive engine, switch to `.cmbAccepted`
or `.memoryReceived` and read `(valence, arousal)` from the
`cmb.fields[.mood]` field. The mood field is delivered across domain
boundaries even when SVAF rejects the rest of the CMB
(MMP §9.3 protocol guarantee R5).

## 0.3.59

### Fixed
- **SYMCore 0.3.7** — fixes hard `EXC_BAD_ACCESS` crash in `SemanticCoupler.pruneExpired()` / `NeuralCoupler.pruneExpired()` under multi-peer load. Both couplers had concurrent dictionary mutation and missing locks on read paths. Affects any consumer with more than 1 active peer session (which is essentially all real deployments).

## 0.3.58

### Fixed
- Discovery → connection layer no longer hammers stale Bonjour endpoints. Outbound discovery now dedups by nodeId across pending sessions, `discoveryDidLosePeer` cancels pending unhandshaked attempts for that peer, and every session has a 10s handshake timeout. Eliminates the cascade of failed `NWConnection`s to peers that left the LAN or never came up. SYMCore xcframework unchanged from 0.3.55.

## 0.3.57

### Fixed
- `SymPeerSession`: cancel `NWConnection` promptly on `.failed` and on receive-error disconnect, and gate disconnect notification through an idempotent path. Eliminates `nw_endpoint_flow_failed_with_error ... already failing, returning` log spam from unreachable peers and stops the upstream `SymNode` from cleaning up the same peer twice. SYMCore xcframework unchanged from 0.3.55.

## 0.3.56

### Fixed
- Cleaned up 3 Swift build warnings — `swift build` now zero-warning. No API change. SYMCore xcframework unchanged from 0.3.55.

## 0.3.55

### Changed
- **SYMCore 0.3.6** — fixes `[CMBField: Float]` decode failure on inbound CMBs (`CMBField` now conforms to `CodingKeyRepresentable`); migrates CMB content key from MD5 → SHA256 (truncated to 32 hex chars). Wire-breaking with respect to CMB key dedup against pre-0.3.55 mesh nodes. Coordinated with `@sym-bot/core` 0.3.28 and `@sym-bot/sym` 0.3.56.
- `Package.swift` `binaryTarget` URL bumped to `v0.3.55/SYMCore.xcframework.zip`.

## 0.3.23

### Changed
- **SYMCore 0.2.0** — `SemanticEncoder` protocol for pluggable SVAF embeddings. Host apps (MeloTune) provide CoreML/ONNX semantic encoders. N-gram default preserved. Per-field evaluation quality bounded by encoder quality.

## 0.3.22

### Added
- **Handshake: `version` and `extensions` fields** per MMP v0.2.1 Section 5.2. Handshake now sends `version: "0.2.1"` and `extensions: []`.
- **Error frame type** per MMP v0.2.1 Section 7.2. `SymFrame.error(code:message:detail:)` factory. SymNode handles inbound error frames — logs warning, emits metric event.

### Parity
- 100% feature parity with sym (Node.js SDK). Both SDKs implement all 10 frame types, handshake with version/extensions/e2ePublicKey, error frames, multi-transport per peer, SVAF per-field evaluation, MD5 content-addressable CMB keys, lineage, remix guard, and metrics.

### Tests
- 53 tests, 0 failures.

## 0.3.21

### Added
- **Multi-transport per peer** matching Node.js SDK v0.3.20 (MMP Section 4.6). LAN + relay connections coexist per peer with automatic failover.
- **Protocol-level metrics** — CMB counts, peer events, LLM cost tracking via `reportLLMUsage()`
- **Remix guard** — `canRemix()` enforces MMP Section 14.7 (agents MUST have new domain data before remixing)
- **`cmb-accepted` event** — agents receive notification when SVAF accepts an incoming CMB

### Tests
- 53 tests across 5 suites.

## 0.3.3

### Added
- **Lineage in SVAF fused CMBs** (MMP Section 14). Remixed CMBs carry `parents` and `ancestors`.
- CI workflow, PR template, contributing guide
- 46 tests across 5 suites

## 0.3.2

### Changed
- **UUID v7 identity** with mandatory Ed25519 keypair
- SYMCore xcframework rebuilt with macOS slice

## 0.3.1

### Added
- **E2E encryption** — Curve25519 key exchange, per-peer encrypt/decrypt for cognitive frames
- Wire frame rename: `memory-share` → `cmb`

## 0.3.0

### Added
- Full API documentation on all public types
- Thread safety improvements

## 0.2.0

- Initial public release. SymNode, SymDiscovery (Bonjour), SymRelay (WebSocket), SymMemoryStore, SVAF evaluation.
