# Changelog

> **Note:** Versions 0.3.24 – 0.3.54 were released as git tags without changelog entries. Changelog resumes at 0.3.55 below.

## 0.5.0 (unreleased)

### Added

- **Request/response over the mesh — `node.exchange`.** Send a directed CMB carrying an application payload and `await` the peer's reply. `SymExchange.request(payload:categories:to:timeout:)` generates a correlation id, injects it into the payload, and suspends until the matching response arrives; `SymNode.respond(to:payload:categories:)` is the responder half, and a payload nobody is awaiting surfaces as `SymEvent.requestReceived(envelope:)` — an app that only issues requests and an app that also serves them use the same two calls.

  **The timeout is caller-set per call, with no default**, because call classes genuinely differ: a query the user is watching should give up in seconds, while one riding out an upstream cold start should not. Peer departure deliberately does **not** fast-fail — relay presence flaps while a sleeping upstream wakes, and the response may still arrive, so the caller's window is the only contract. Cancelling the awaiting `Task` fails with `.cancelled`; stopping the node (including the app suspension that stops it) fails every pending request with `.interrupted` rather than leaving a continuation only a departed peer could resume. A response arriving after its timeout is not an error — it becomes an ordinary uncorrelated payload the app may ignore or salvage.

  **Why a separate handle rather than a method on `SymNode`:** `SymNode` is not `Sendable`, so `await`ing a method on it from an actor-isolated context sends the class across an isolation boundary — which the Swift 6 language mode rejects, and an actor-isolated service is exactly what consumes this. Verified against a throwaway Swift 6 package with a `@MainActor` call site before the shape was chosen. `SymExchange` is a `Sendable` value holding a lock-protected registry and one dispatch closure; hold it wherever you hold the node. `@unchecked Sendable` is claimed only for that registry — one dictionary under one lock, no public surface — and never for `SymNode`, where nothing would back the claim.

  On the wire the payload rides **inside** the `cmb` object as a sibling of the CAT7 content, matching what Node reads, and is joined **after** the CMB is signed so it can never enter the block key or a signing preimage. Additive: a frame without a payload is byte-identical to 0.4.7, and a pre-0.5.0 receiver ignores the member.

- **`SymInviteURL` — one parser and formatter for `sym://` invite links.** `sym://invite/v1?relay=…&token=…&room=…&name=…`, so no app carries its own regex and two apps cannot disagree about what a link means. The optional `name` is display-only, letting a join sheet say what is being joined instead of every app carrying the label out of band.

  **A present-but-empty `room=` is malformed, not absent.** The empty string is itself a real relay partition — the unnamed one every pre-room client occupies — so reading it as "no room" would silently join the holder to everyone. Absent stays `nil`; present-but-empty is refused, as is an unknown version segment and any non-`wss` relay. Canonical output fixes parameter order so links round-trip byte-stably for QR codes, and `description` redacts the token: the most common way a bearer credential leaks is a log line written by someone who never thought of it as a secret.

### Fixed

- **`SymNodeStatus.relayConnected` reported a connection the node did not have.** It was `relaySession != nil` — the existence of a session *object*, which is true from the moment a relay is configured and stays true after the relay closes the socket refusing the node. Found by dev-team-2 on a real rig: MeloTune was handed a token the deployed relay does not accept, the socket upgraded and died ~17 s later, and `status()` reported connected throughout. A reach indicator was about to be built on it.

  The accurate value already existed one layer down and was simply never surfaced. It moves behind a lock on the way out, because it is written from the send-completion handler on an arbitrary thread and read from whichever thread calls `status()`; surfacing it as-is would have swapped a wrong value for a racy one.

  **`relayConnected` answers "is the socket up right now", not "am I on the mesh", and must not be read alone.** Measured on the deployed relay by dev-team-2 over 45 s: a node whose token the relay will never accept reads `true → false → true` on a ~20 s cycle, indefinitely, and is `true` most of the time. The edge holds the refused socket open ~20 s so the close arrives late, and the session then reconnects into the same hopeless auth. Against a controlled relay the same code reports `false` within 253 ms — the behaviour is the deployment's, not the SDK's, but the consequence for a client is real either way.

  The oscillation is **specific to the refused case**, which the same probe confirmed once the channel was registered: on the accepted path against the same deployed relay, `relayConnected` is `true` at 511 ms with `relayClose` nil, stable across the window, no flapping. So gate a connected indicator on `relayConnected && relayClose?.wasRefused != true` — a predicate now verified in production in both states rather than argued from a rig.

- **`SymNodeStatus.relayClose` tells a refusal from a dropped connection.** `wasRefused` is true for application close codes (4000–4999) — a bad token, a duplicate identity — and for a refusal the relay states in its own `relay-error` message, which was previously logged and discarded. A stated refusal is kept in preference to the transport close that follows it, so a retry cannot bury the one message that explains everything.

  An app that cannot tell a refusal from silence cannot say anything true about an empty room: it may be reporting a place it never reached. **In production this is the only reliable refusal signal** — unlike `relayConnected` it does not oscillate while a refused session retries; it was populated correctly at 510 ms in the rig check and stayed stable and correct through every flip.

- **A payload on an end-to-end-encrypted frame no longer takes the whole frame down with it.** The E2E path clears `cmb` after moving the categories into `encryptedFields`, and nesting the payload under a synthesized `cmb` there produced a block missing every required member: the decode failed, the v2 rescue did not match, and the receiver dropped frame and payload together, silently. Such frames now carry the payload at top level; the Node-facing plaintext path is unchanged.

### Known

- sym-swift's own sources do not compile under the **Swift 6 language mode** — pre-existing `@Sendable` capture errors in `SymDiscovery` and `SymPeerSession`, unrelated to this release. The library builds in its own Swift 5 mode and a Swift 6 app consuming it is unaffected, which the bundled `StrictConcurrencyConsumerProbe` and an external Swift 6 consumer package both demonstrate. Recorded here so the next consumer is not surprised.

- **A refused relay session retries forever.** A 4003 (invalid token) is a *permanent* refusal — the token will not become valid by trying again — but the session treats it like any transport drop and reconnects on the usual backoff, so a misconfigured app hammers the relay indefinitely. The relay already treats 4006 (duplicate identity) as a hard stop clients should not retry, and 4003 arguably deserves the same or a much longer backoff. Found during the 0.5.0 rig check; deliberately not fixed here because changing retry policy is its own change with its own review, and `relayClose.wasRefused` already lets a client stop on its own.

## 0.4.7

### Fixed

- **Two sym-swift nodes no longer storm the relay with handshakes.** `addRelayPeer` sent a handshake + wake-channel on EVERY call, and an incoming handshake called `addRelayPeer` — so A's handshake made B handshake, which made A handshake, forever; the directory refresh re-greeted stale entries every cycle as well. Measured by dev-team-2 on sym-relay 0.1.3 with two MeloTune 3.1 simulators: one node alone sent 48 handshakes + 48 wake-channels in 15 s; the moment a second authenticated, 100 handshakes in 26 ms and 225 + 74 in 1.2 s, then the relay's rate limit (burst 300) closed both, reconnect, repeat every 2–9 s — Music Mates over the internet could not hold a connection for 2 s.

  The handshake is now sent **once per peer per relay session** (a `relayHandshakeSent` set: cleared when the relay disconnects, and per peer when the relay loses it, so a returning peer is greeted again). The exchange terminates after one handshake each way: the receiver's reply lands on a sender that already has it in the set. The Bonjour path was never affected (it handshakes once in `sessionDidBecomeReady`), and sym-swift ↔ Node peers never looped because the Node side does not answer a handshake with a handshake. Verified against dev-team-2's two-simulator relay rig before the tag.

## 0.4.6

### Fixed

- **An unrecognized frame type no longer kills the frame.** `SymFrameType` is a `String`-raw-value enum and `SymFrame.type` is non-optional, so a discriminator this SDK did not know threw `DecodingError.dataCorrupted` and failed the entire frame. The consequence was structural rather than cosmetic: **every frame type added to the wire after a client shipped broke that client's decode of those frames, silently, for as long as it stayed in the field.**

  Observed live — JS nodes emit `attestation`, no Swift client had the case, and because each peer relays the same frame the failure was amplified by the roster: one attestation cost one decode failure per peer per copy.

  This was the second instance of the class. The first was a v2 two-section record in the `cmb` member, patched narrowly by an internal rescue for that one shape. A rescue per shape does not converge, so the discriminator itself is tolerant now: unrecognized values decode to `SymFrameType.unknown`, the frame is ignored rather than failed, and future wire additions are a no-op for older clients.

  Ignored frames are reported once per novel type per connection, at info — not once per frame, which would have reproduced the same peer-count amplification more quietly. An ignored frame is deliberately still distinguishable from a handled one: the log line is what keeps that visible without costing a failure.

  Adding `attestation` as a real case would have fixed the symptom and left the mechanism. Whether Swift clients should *handle* attestations rather than ignore them is a separate question and is not answered here.

  The length-prefixed stream never desynced on this path — the parser advances its buffer before decoding — so the cost was a dropped frame and log noise, never a torn-down session.

## 0.4.1

### Added

- **`SymPeerInfo.reachability` — how a peer is reachable, exposed at last.** The node already tracked it (`PeerState.transports`, keyed by source: `bonjour` for the local network, the relay otherwise); it simply never left the SDK, so an app could not tell a Wi-Fi peer from a relayed one even to LABEL it.

  It is a `Set<SymPeerReachability>`, not a mode, and that is the load-bearing decision: **MMP §4.6 allows a peer to hold multiple transports at once**, so someone on your Wi-Fi who is also relay-connected is genuinely both. The node prefers Bonjour when both exist, but that is a routing choice, not a fact about the peer — a two-state field would have to pick one and misreport the ordinary case. Read from the transports a peer currently holds rather than from how it was first discovered, so a LAN peer that later gains a relay path becomes both, and stays both until a transport closes.

  This exists so an app can show WHERE a peer is reachable from. It does not gate what a peer may do: coupling, presence and harmonizing are identical on either transport.

### Fixed

- **`SymPeerInfo`'s initialiser is now public.** A public struct whose memberwise init was internal could not be constructed by a consumer, so an app could receive one and never build one — leaving every peer-facing view untestable and unpreviewable. Found while writing a consumer's peer-classification tests, which had to be rewritten against a different surface to get around it.

## 0.3.94

### Added

- **Admission across seven cognitive categories reaches the SDK.** Bundled `SYMCore.xcframework` → **v0.3.94**, which adds `SVAFCategories` (per-category drift, the five verdicts, both silent causes, `exactHeld` by content address), `SVAFShadow` (design C in shadow — a redundancy-floor cut that decides nothing and never touches the signed payload), and `SVAFAdmissionPolicy` (the receiver's thresholds are refused rather than invented when incomplete). Held to the same published `conformance/svaf-baseline.json` vectors as the JS reference implementation.

  Until now this SDK could only report one block-level decision per CMB, so a peer's signal with relevant `mood` and irrelevant `focus` was indistinguishable from one that was uniformly mediocre.

### Changed

- **An anchor that states no confidence contributes at full weight** in the new per-category path, rather than at an invented `0.8`. This changes drift arithmetic for stores whose anchors carry no confidence. The existing `SVAFV2` / `SVAFFusion` entry points are unchanged.

## 0.3.93

### Fixed

- **Flat CMB records now read `createdTimestamp`, the member peers actually send.** Same class as 0.3.92's container rename. `createdAt` is a name no peer has ever emitted — the last occurrence in `@sym-bot/core` 0.9.3 is inside a comment. This one degraded instead of refusing: the decoder's `?? 0` stamped every real peer's record epoch, so records arrived carrying a wrong creation time rather than failing. Bundled `SYMCore.xcframework` → **v0.3.93**.

## 0.3.92

### Fixed

- **iOS can hear the mesh again — the CMB wire container is `categories`, not `fields`.** MMP v1.1 §8.2 renamed the container holding the seven CAT7 members. The JS side moved and this SDK did not, so on the bundled v0.3.90 binary *every* CMB from a current peer was dropped and every CMB emitted from iOS was refused: `@sym-bot/core` 0.9.3 reads only `.categories` and throws `"CMB requires categories"` on anything else. Because the frame parser's rescue path wraps its decode in `try?`, the break presented as a quiet mesh rather than an error — no log line, no failed frame, just nothing arriving.

  Bundled `SYMCore.xcframework` bumped to **v0.3.92**, which carries the fix (`sym-core-swift` @ `v0.3.92`). No key moves and no signature is invalidated: `blockKeyV2` hashes the field texts in CAT7 order, never the container name.

- **Records without per-field `meta` now arrive.** Roughly half of what a live peer emits carries none — measured 471 of 903 records with a `categories` container in one node's store, same emitter, same day, interleaved with the rest. The SDK required it, so those dropped too. `meta.key` is recomputed with the same `fieldKeyV1` the emitter would have used; `parents` already defined empty as "no descent asserted".

### Changed

- **The rescue fixtures now carry the shape a peer actually emits.** `BoundaryRecordRescueTests`' records were hand-written against `fields` and every one of them carried per-field `meta`, so the suite agreed with the decoder about a shape no peer sends and could not see either break. Two tests added at the frame layer: a peer record with no per-field `meta` is rescued, and a pre-v1.1 `fields` record is refused rather than partially read.

## 0.3.89

### Added

- **`SymNode.relay(_:)` — propagate one CMB across meshes without re-storing.** A node emitting the same logical CMB across multiple meshes (one `SymNode` per group, all sharing the device store) should send ONE CMB, not `remember()` it per node — the latter mints a fresh random key each time and double-counts the shared store (the node reports emitted N×, while an observer on a single mesh sees only 1/N). `relay(cmb)` broadcasts an existing CMB (same key) to a node's peers without storing it, so a consumer can `remember()` once on a primary node and `relay()` to the rest. (Bundled `SYMCore.xcframework` unchanged — reuses the v0.3.86 binary.)

## 0.3.88

### Added

- **Node-stats self-report — sovereign nodes report emitted/admitted/memory to observers.** Catches the Swift SDK up to `@sym-bot/sym` 0.7.26. A cross-device node (e.g. MeloTune on iOS) had no way to report its store tally over the mesh, so an observer cockpit showed it as `0 emitted / — admitted`. Nodes now gossip a `node-stats` frame every 15s (and on start), byte-compatible with the Node wire format `{ type: 'node-stats', stats: { name, nodeId, emitted, admitted, memory, at } }`:
  - `SymFrameType.nodeStats` + `SymNodeStats` payload + factory.
  - `SymMemoryStore.stats`: own emissions (`local/`) vs admitted peer CMBs (`{peerId}/`) vs total, mirroring the Node store's local-vs-peer split.
  - `SymNode.emitNodeStats()` on a 15s timer, broadcast to all peers. Emit-only (no local consumer). 71/71 tests. (Bundled `SYMCore.xcframework` unchanged — reuses the v0.3.86 binary.)

## 0.3.87

### Fixed

- **Co-resident group nodes now advertise on the LAN.** An app that joins a
  cross-app group runs a second `SymNode` (one per group) sharing the device's
  identity. Both listeners advertised their Bonjour service under the same
  instance name (`node-id`), so the Network framework published only the first —
  the main `_melotune._tcp` node appeared on the LAN but the group's
  `_<group>._tcp` service never did, and the node could never mesh with peers in
  that group. The Bonjour instance name is now unique per (node, service type);
  peers still identify the node via the `node-id` TXT entry, and self-filtering
  is by `node-id`, so the change is transparent to interop. (Bundled
  `SYMCore.xcframework` unchanged — reuses the v0.3.86 binary.)

## 0.3.86

### Added

- **Ed25519 CMB signing & verification (MMP §8.3).** Catches the Swift SDK up
  to `@sym-bot/sym` 0.7.x / `@sym-bot/core` 0.3.38. Nodes now sign every CMB
  they author with their Ed25519 identity key and verify inbound CMBs against
  each peer's handshake-announced signing key, so they interoperate as full
  peers with Node agents (which verify and reject tampered/forged CMBs).
  - `remember()` signs the authored CMB before storing/broadcasting.
  - Inbound CMBs with a present-but-invalid signature are rejected
    (audit-logged, never surfaced); unsigned CMBs stay unverified-not-rejected
    (pre-§8.3 peers); E2E-encrypted CMBs are authenticated by AEAD.
  - Bundled `SYMCore.xcframework` rebuilt with `CMBSigning` (Curve25519,
    canonical `key|author|createdAt` payload — byte-compatible with Node).

## 0.3.85

### Fixed

- **Hotfix for v0.3.84 archive rejection.** App Store Connect rejected
  v0.3.84 with `Invalid MinimumOSVersion ... is ''` and `Missing Info.plist
  value` — the heredoc-generated framework `Info.plist` for each slice
  was missing both `MinimumOSVersion` and `CFBundleSupportedPlatforms`.

  The `Scripts/build-xcframework.sh` in sym-core-swift now writes per-slice
  values matching `Package.swift`'s platform targets and the binary's
  `LC_BUILD_VERSION` minos load command:

  - `ios-arm64` → `MinimumOSVersion 17.0`, `CFBundleSupportedPlatforms iPhoneOS`
  - `ios-sim` → `MinimumOSVersion 17.0`, `CFBundleSupportedPlatforms iPhoneSimulator`
  - `macos-arm64` → `MinimumOSVersion 14.0`, `CFBundleSupportedPlatforms MacOSX`
  - `maccatalyst-arm64` → `MinimumOSVersion 17.0`, `CFBundleSupportedPlatforms MacOSX`

  No binary or API change from v0.3.84 — same dSYM bundling. **Consumers
  on v0.3.84 must update to v0.3.85 to pass App Store validation.**

## 0.3.84

### Build

- **SYMCore.xcframework rebuilt with embedded dSYMs.** Each platform slice
  now ships with a matching `dSYMs/SYMCore.framework.dSYM` bundle alongside
  the framework. App Store Connect symbolicates SYMCore frames in crash
  reports instead of leaving them as raw memory addresses. SPM consumers
  pick up the dSYMs automatically at archive time — no Package.swift
  changes required on the consumer side.

  The `Scripts/build-xcframework.sh` flow in the (private) sym-core-swift
  repo now passes `DEBUG_INFORMATION_FORMAT=dwarf-with-dsym` plus
  `STRIP_INSTALLED_PRODUCT=NO` / `COPY_PHASE_STRIP=NO` /
  `DEPLOYMENT_POSTPROCESSING=NO` during archive, runs `dsymutil` on each
  patched binary after `install_name_tool`, then passes `-debug-symbols`
  per slice into `xcodebuild -create-xcframework`.

  Binary contract identical to v0.3.78 — no API change, no behaviour
  change. Zip size grew ~1 MB (5.x → 5.9 MB).

## 0.3.83

### Fixed

- **Stale-prior threshold lowered from 10s to 1s** in `SymNode.addPeer`
  dedup. Mirrors `@sym-bot/sym` v0.5.5 on the Node side. The 10s window
  shipped in v0.3.81 was too lenient: when a peer process was killed
  and quickly relaunched, the old run had typically sent a CMB seconds
  before death, so `lastSeen` was still within the 10s window. The
  dedup logic then rejected the legitimate redial as a
  same-direction-duplicate, producing `connection ready → immediate
  disconnect` with no handshake-complete on the dialing side.

  Lowered to 1s. Sub-second TCP-retry races during initial handshake
  still keep prior (the case the same-direction-duplicate rule was
  designed for); peer restarts with ≥1s between kill and re-dial now
  recover within the application layer instead of being blocked until
  OS keepalive reaps the socket (~100s).

## 0.3.82

### Fixed

- **Relaxed TCP keepalive timings.** v0.3.81 set `keepaliveIdle = 1`,
  `keepaliveInterval = 1`, `keepaliveCount = 3` — ~4 seconds to declare a
  socket dead. That was far too aggressive for real-world Wi-Fi: brief
  mid-handshake pauses on healthy connections triggered keepalive reaping
  before the application-level handshake exchange could complete, producing
  `[SYM] session: handshake timeout after 10s — disconnecting` even on
  fully-functional peers.

  v0.3.82 relaxes to `keepaliveIdle = 10`, `keepaliveInterval = 30`,
  `keepaliveCount = 3` → ~100s to declare dead. Wi-Fi blips of a few
  seconds during handshake exchange or active CMB flow no longer trigger
  reaping; peer-restart scenarios still recover within ~100s instead of
  the macOS default ~2h.

  Application-layer `lastSeen`-stale check in `SymNode.addPeer` from
  v0.3.81 still handles faster recovery: a peer entry older than 10s
  is treated as stale and the new dial replaces it, regardless of
  whether OS keepalive has reaped the underlying socket yet. So the
  effective recovery time for the user-visible "peer restarted, can
  re-connect now" case is still ~10s, while OS-level keepalive is the
  fallback for cases the application layer doesn't see.

## 0.3.81

### Fixed

- **TCP keepalive on every NWConnection** — outbound sessions
  (`SymPeerSession.init(outboundTo:)` / `init(remoteHost:port:)`) and
  inbound connections accepted by `NWListener` (`SymDiscovery.startListener`)
  now use `NWParameters` with `NWProtocolTCP.Options.enableKeepalive = true`,
  `keepaliveIdle = 1`, `keepaliveInterval = 1`, `keepaliveCount = 3`. Dead
  remote ends (peer process killed without graceful FIN — common on iOS app
  suspension and Mac Catalyst rebuilds) are now reaped within ~4 seconds
  instead of waiting for macOS default `TCP_KEEPALIVE = 7200s` (2 hours).

  Without this, a peer that crashes or restarts leaves the survivor with
  an ESTABLISHED TCP socket that the OS doesn't reap for hours. The
  `addPeer` dedup logic then keeps rejecting the live new dial against
  the zombie entry, producing a permanent connection-flap loop visible in
  the field as "peer joins, immediately drops, retries, repeat" — most
  commonly hit on iPhone↔Mac-Catalyst pairs after either side rebuilds.

  Mirrors the fix shipped in `@sym-bot/sym` v0.5.3 on the Node side so
  cross-runtime peers (sym-swift ↔ sym-node) recover symmetrically from
  peer restarts.

- **lastSeen-aware stale-prior detection in `addPeer` dedup.** A peer
  entry whose `lastSeen` is older than `staleAfterSeconds` (10s, matching
  Node SDK's `_heartbeatInterval` default) is now treated as stale and
  the new dial replaces it, regardless of dual-dial tie-break or
  same-direction-duplicate logic. The remote re-dialling is itself
  evidence its prior is dead — rejecting blocks legitimate reconnects
  after a peer restart for as long as the OS holds the dead socket.

  Combined with the TCP keepalive above, recovery from peer restart is
  now seconds, not hours. Mirrors `@sym-bot/sym` v0.5.3 dedup-path
  staleness check.

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
