# SYM Swift

> **Add your iOS or macOS app to the mesh. Think together with every other agent on the network.**
>
> Native Swift SDK for the [Mesh Memory Protocol (MMP)](https://meshcognition.org/spec/mmp). Your app discovers other SYM agents over the local network, exchanges structured observations, and acts autonomously on collective intelligence. No servers, no accounts, no integration code between pairs of apps.

```swift
// Package.swift
.package(url: "https://github.com/sym-bot/sym-swift.git", from: "0.3.77")
```

[![Swift](https://img.shields.io/badge/Swift_SPM-compatible-orange)](https://github.com/sym-bot/sym-swift)
[![MMP Spec](https://img.shields.io/badge/protocol-MMP_v1.0-orange)](https://meshcognition.org/spec/mmp)
[![SVAF arXiv](https://img.shields.io/badge/arXiv-2604.03955-b31b1b.svg)](https://arxiv.org/abs/2604.03955)
[![MMP arXiv](https://img.shields.io/badge/arXiv-2604.19540-b31b1b.svg)](https://arxiv.org/abs/2604.19540)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![CI](https://github.com/sym-bot/sym-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/sym-bot/sym-swift/actions/workflows/ci.yml)
[![中文文档](https://img.shields.io/badge/语言-中文-red)](README_zh.md)

## Contents

1. [What this looks like](#what-this-looks-like) — three apps, three devices, one mesh
2. [Who this is for](#who-this-is-for)
3. [Integration](#integration) — package, permissions, service class, launch
4. [Background wake](#background-wake) — survive iOS backgrounding via silent push
5. [API](#api)
6. [xMesh synthesis](#xmesh-synthesis) — act on peer-derived cognitive insights
7. [Logging](#logging)
8. [How SYM compares](#how-sym-compares)
9. [Limitations](#limitations)
10. [Interoperability](#interoperability)
11. [References](#references)

---

## What this looks like

Three apps on three devices, three different vendors. Claude Code (macOS), MeloTune (iPhone), MeloMove (iPhone). None of them know the others exist. All three are on the mesh.

You code for hours. Claude Code sees your messages getting shorter. MeloMove notices three hours without movement. MeloTune observes you skipped your usual playlist. Each observation on its own is noise. The mesh synthesises:

> *"Energy declining across all signals. Three-hour sedentary. Deviation from routine. This isn't focus — it's fatigue."*

MeloTune shifts to calm ambient. MeloMove suggests a recovery stretch. Not because one agent told them to — **the mesh understood something none of them could see alone.**

**This is shipping in production.** [MeloTune](https://melotune.ai) has used this SDK on the App Store since November 2025. When Claude Code broadcasts `mood: "cautiously optimistic"` with seven structured fields, MeloTune's SYM instance receives it over LAN, SVAF evaluates all seven fields (drift 0.032 — aligned), its own LLM decides "Exploring Wonder" with Indie genre, and playback starts. No integration code between them. No API. Bonjour discovery, protocol-level coordination.

Same pattern works for any domain — fitness, focus, health, productivity, smart home, finance. Your app contributes one slice of the picture, the mesh connects every slice.

## Who this is for

- **iOS / macOS app developers** whose app has observations worth sharing — mood, activity, attention, health, domain-specific signals. Add the package, define your agent, your users' other AI agents learn from what your app sees.
- **Multi-device mesh builders** coordinating native mobile apps with Node.js agents, Claude Code sessions, and other SYM peers. `sym-swift` is the iOS/macOS leg of a cross-platform mesh verified on Mac ↔ Windows ↔ iOS ↔ Linux.
- **Existing MeloTune / MeloMove integrators** extending their apps with peer-aware behaviour — consumes the same wire protocol.
- **Not for:** apps that only need device-local ML or nearby-peer gaming. Use CoreML, MultipeerConnectivity, or GameCenter directly — SYM is overkill for those.

## Integration

### 1. Add the package

In Xcode:

1. **File → Add Package Dependencies** → `https://github.com/sym-bot/sym-swift.git` → Add Package
2. Choose products → select **SYM** → add to your app target
3. Your target → **General → Frameworks, Libraries, and Embedded Content** → verify **SYM** appears

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/sym-bot/sym-swift.git", from: "0.3.77")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "SYM", package: "sym-swift"),
    ])
]
```

### 2. Add network permissions

SYM discovers peers via Bonjour on the local network.

Add to your `Info.plist`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>This app uses the local network to connect with other AI agents on the SYM mesh.</string>

<key>NSBonjourServices</key>
<array>
    <string>_sym._tcp</string>
</array>
```

Add to your app's `.entitlements` file:

```xml
<key>com.apple.security.network.server</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

Both are required — `network.server` for Bonjour advertising (other agents find you), `network.client` for connecting to peers.

### 3. Create a mesh service

Wrap `SymNode` in a service class. This is your app's domain layer — it decides what to do with mesh events.

```swift
import Foundation
import SYM
import os.log

@MainActor
final class MeshService: ObservableObject {

    static let shared = MeshService()

    @Published private(set) var isRunning = false
    @Published private(set) var peerCount = 0

    private var node: SymNode?
    private let logger = Logger(subsystem: "com.example.myapp", category: "Mesh")

    private init() {}

    func start() {
        guard !isRunning else { return }

        let symNode = SymNode(
            name: "my-app",
            cognitiveProfile: "Fitness agent that tracks workouts, heart rate, and energy levels"
            // Be specific — SVAF uses this description to evaluate relevance with peers
        )
        self.node = symNode

        symNode.on { [weak self] event in
            Task { @MainActor in
                self?.handleEvent(event)
            }
        }

        symNode.start()
        isRunning = true
        logger.info("[Mesh] started")
    }

    func stop() {
        guard isRunning else { return }
        node?.stop()
        node = nil
        isRunning = false
        peerCount = 0
        logger.info("[Mesh] stopped")
    }

    // MARK: - Background wake (iOS)

    func setWakeToken(platform: String, token: String, environment: String) {
        node?.setWakeToken(platform: platform, token: token, environment: environment)
    }

    func reconnect() {
        node?.reconnect()
    }

    // MARK: - Events

    private func handleEvent(_ event: SymEvent) {
        switch event {
        case .moodDelivered(let from, let mood, _):
            logger.info("[Mesh] mood from \(from): \(mood)")
            // Your domain logic — respond to mood

        case .moodRejected:
            break

        case .message(let from, let content):
            logger.info("[Mesh] message from \(from): \(content)")

        case .memoryReceived(_, let content, _, _):
            logger.info("[Mesh] insight: \(content)")
            // Your domain logic — act on collective intelligence

        case .peerJoined(_, let name):
            peerCount = node?.peerList().count ?? 0
            logger.info("[Mesh] peer joined: \(name)")

        case .peerLeft(_, let name):
            peerCount = node?.peerList().count ?? 0
            logger.info("[Mesh] peer left: \(name)")

        case .xmeshInsight(let from, let trajectory, _, let anomaly, let outcome, _):
            // Peer's xMesh LNN emitted a collective-intelligence insight.
            // See the xMesh synthesis section below for the full pattern.
            logger.info("[Mesh] xmesh insight from \(from): \(outcome) (anomaly: \(anomaly))")

        default:
            break
        }
    }
}
```

### 4. Start on app launch

**SwiftUI:**

```swift
import SwiftUI

@main
struct MyApp: App {
    init() {
        MeshService.shared.start()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

**UIKit:**

```swift
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    MeshService.shared.start()
    return true
}
```

### 5. There is no step 5.

Your app is on the mesh. Other SYM peers on the same network discover it via Bonjour automatically.

## Background wake

Most peer-to-peer SDKs die when iOS suspends the app. SYM survives via the [P2P wake protocol (MMP §5)](https://meshcognition.org/spec/mmp) — a peer can send an APNs silent push to your app, which wakes, reconnects the relay, and processes queued CMBs.

**Register on launch:**

```swift
// AppDelegate:
func application(_ application: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02hhx", $0) }.joined()
    MeshService.shared.setWakeToken(
        platform: "apns",
        token: token,
        environment: "production"  // or "sandbox" for TestFlight dev builds
    )
}
```

The token is broadcast to already-connected peers. When you're offline, any peer that has your token can wake you via silent push.

**Reconnect when woken:**

```swift
// AppDelegate:
func application(_ application: UIApplication,
                 didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                 fetchCompletionHandler handler: @escaping (UIBackgroundFetchResult) -> Void) {
    MeshService.shared.reconnect()
    // reconnect() tears down the current relay session and creates a fresh one
    handler(.newData)
}
```

You don't need a backend to send wake pushes — peers generate them via the relay when they have something for you.

## API

```swift
import SYM

let node = SymNode(name: "my-app")

// Lifecycle
node.start()
node.stop()

// Share observations — the agent extracts CAT7 fields from its domain data
node.remember(fields: [
    .focus:       CMBEncoder.encodeField("workout session completed"),
    .commitment:  CMBEncoder.encodeField("30min, 320 cal burned"),
    .perspective: CMBEncoder.encodeField("fitness agent, post-workout"),
    .mood:        CMBEncoder.encodeField("energized", valence: 0.7, arousal: 0.6),
])

// Query the mesh
node.recall("energy patterns")   // [SymMemoryEntry]
node.peerList()                  // [SymPeerInfo]
node.status()                    // SymNodeStatus

// Background wake (iOS)
node.setWakeToken(platform: "apns", token: deviceToken, environment: "production")
node.reconnect()                 // Call from silent-push handler

// Events — the mesh delivers, your app decides what to do
node.on { event in
    switch event {
    case .peerJoined(let id, let name):                ...
    case .peerLeft(let id, let name):                   ...
    case .moodDelivered(let from, let mood, let drift): ...   // peer's mood passed SVAF
    case .moodRejected(let from, let mood, let drift):  ...   // SVAF gated out as irrelevant
    case .memoryReceived(let from, let content,
                         let decision, let cmb):         ...   // full CMB with lineage
    case .message(let from, let content):               ...   // free-text peer message
    case .xmeshInsight(let from, let trajectory,
                       let patterns, let anomaly,
                       let outcome, let coherence):     ...   // see below
    case .couplingDecision(let peer, let decision,
                           let drift):                   ...
    case .stateSyncReceived:                             break // deprecated (MMP v0.2.3)
    }
}
```

For CAT7 field semantics and extraction approaches (LLM, structured data, prompt template), see [How Agents Extract CAT7 Fields](https://github.com/sym-bot/sym#how-agents-extract-cat7-fields) in the Node.js repo.

## xMesh synthesis

When a peer runs an xMesh LNN (liquid neural network trained on bidirectional CMB flows), it periodically emits **collective-intelligence insights** — not individual observations but cognitive state derived from the mesh as a whole. These arrive as `.xmeshInsight` events with:

- `trajectory` — 6-dim vector `[valence, arousal, v_vel, a_vel, stability, confidence]`
- `patterns` — 8 LNN pattern activations
- `anomaly` — 0..1 deviation from expected cognitive state
- `outcome` — predicted label (e.g. `"fatigue-onset"`, `"flow-state"`)
- `coherence` — 0..1 mesh-wide alignment

Your app can respond to these insights *passively* (the switch case above) or participate in the synthesis loop by conforming to `SYMSynthesisDelegate`. SYM passes each insight to your domain logic and re-broadcasts your interpretation back to the mesh — so peers learn from how your domain interprets the collective state.

```swift
class MyAgent: SYMSynthesisDelegate {
    func synthesizeInsight(from insight: XMeshInsight) -> String? {
        if insight.anomaly > 0.6 {
            return "fitness: high anomaly, movement break recommended"
        }
        if insight.outcome == "flow-state" {
            return "fitness: holding heart-rate zone for flow alignment"
        }
        return nil    // skip this insight
    }
}

node.synthesisDelegate = agent
```

This is the "thinking together" loop — not just exchanging observations but synthesising domain-specific interpretations of the mesh's collective state.

## Logging

SDK logs use the `[SYM]` prefix with categories:

```
[SYM] node: started: my-app (a1b2c3d4)
[SYM] discovery: found peer: other-app (e5f6g7h8)
[SYM] session: handshake complete with other-app (e5f6g7h8)
[SYM] e2e: encrypted CMB fields for other-app
[SYM] mood: from other-app: "tired" → ACCEPTED (drift: 0.23)
[SYM] memory: stored: "user exhausted" → 1/1 peers
```

Categories: `node`, `discovery`, `session`, `peer`, `mood`, `memory`, `relay`, `wake`, `xmesh`, `coupling`, `e2e`.

Your app's own logs should use a different prefix (e.g. `[Mesh]`, `[MyApp]`) to distinguish from SDK internals.

## How SYM compares

| | MultipeerConnectivity | WebRTC | Firebase / Supabase Realtime | SYM |
|---|---|---|---|---|
| **Peer discovery** | Nearby only | Requires signalling server | Cloud-only | Bonjour LAN + optional relay |
| **Backend needed?** | No | Signalling server | Vendor cloud | No (LAN) / self-host relay |
| **Protocol openness** | Apple-only | Open | Vendor-specific | Open ([MMP](https://meshcognition.org/spec/mmp) + [arXiv](https://arxiv.org/abs/2604.19540)) |
| **Cross-platform peers** | Apple only | Via adapters | Any with SDK | Native Swift + Node.js + any MMP impl |
| **Cognitive layer** | None (raw bytes) | None (raw streams) | None (raw events) | SVAF per-field relevance gate |
| **Survives iOS background?** | No | No | Yes (push notifications) | Yes (P2P wake via APNs silent push) |
| **End-to-end encryption** | No (key pinning required) | DTLS | Vendor-managed | X25519 + AES-256-GCM per peer pair |

SYM is the only option that combines peer-to-peer discovery, open protocol, cross-platform native SDKs, and a cognitive relevance gate — the last one is the reason agents can "think together" rather than just stream bytes.

## Limitations

- **iOS 17+ / macOS 14+ / Swift 5.9+.** Older OS versions not supported.
- **SYMCore is distributed as a precompiled xcframework.** Source is not open — contains the CfC neural engine (closed-form continuous-time networks for affective state) and the trained SVAF evaluator (field-attention weights). The surrounding `SYM` package and wire protocol are open-source Apache 2.0.
- **E2E encryption is per-peer-pair, not universal.** CMB field content is encrypted end-to-end with X25519 key agreement + AES-256-GCM between peers that both advertise an E2E public key on handshake. Peers without E2E support fall back to plaintext for backward compatibility. Outer frame metadata (sender ID, timestamp, lineage) stays plaintext — enough for relay forwarding and SVAF evaluation without seeing bodies.
- **Corporate networks often block mDNS multicast.** If LAN discovery fails on the same wifi, fall back to a relay.
- **Background wake requires push infrastructure.** APNs silent push works out of the box if your app is registered for remote notifications. For FCM (Android via cross-platform builds), your backend generates the wake.
- **Handshake is not post-quantum.** X25519 is vulnerable to future quantum attacks on recorded traffic. Post-quantum KEM is on the MMP roadmap.

## Interoperability

Same wire protocol as [SYM](https://github.com/sym-bot/sym) (Node.js) and [sym-mesh-channel](https://github.com/sym-bot/sym-mesh-channel) (Claude Code plugin). A Swift app and Claude Code discover each other on the same network and exchange CMBs automatically.

**Verified cross-platform:** iOS ↔ macOS ↔ macOS Catalyst ↔ Windows ↔ Node.js on the same mesh (April 2026). Production-verified in [MeloTune](https://melotune.ai) (iOS, App Store since November 2025).

## References

- [MMP Specification v1.0](https://meshcognition.org/spec/mmp) — canonical web version of the 8-layer protocol
- [MMP paper](https://arxiv.org/abs/2604.19540) — Xu, 2026. *Mesh Memory Protocol: Semantic Infrastructure for Multi-Agent LLM Systems*. arXiv:2604.19540.
- [SVAF paper](https://arxiv.org/abs/2604.03955) — Xu, 2026. *Symbolic-Vector Attention Fusion for Collective Intelligence*. arXiv:2604.03955.
- [sym (Node.js)](https://github.com/sym-bot/sym) — reference implementation.
- [sym-mesh-channel](https://github.com/sym-bot/sym-mesh-channel) — Claude Code MCP plugin.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). All changes must comply with the [MMP specification](https://meshcognition.org/spec/mmp) and pass CI before merge.

## License

Apache 2.0 — see [LICENSE](LICENSE).

**[SYM.BOT](https://sym.bot)** — Glasgow, Scotland.
