# SYM Swift

**Add your iOS or macOS app to the mesh. Think together with every other agent on the network.**

Your app sees workouts. Claude Code sees fatigue. MeloTune sees a skipped playlist. Alone, each is noise. On the mesh, they become collective intelligence — and your app acts on it autonomously.

SYM Swift is the native SDK for the [Mesh Memory Protocol (MMP)](https://sym.bot/spec/mmp). Add the package, wire in a service class, and your app joins the mesh alongside Claude Code and any other SYM agent on the local network. No servers, no APIs, no integration code.

[![Swift](https://img.shields.io/badge/Swift_SPM-compatible-orange)](https://github.com/sym-bot/sym-swift)
[![MMP Spec](https://img.shields.io/badge/protocol-MMP_v0.2.3-purple)](https://sym.bot/spec/mmp)
[![arXiv](https://img.shields.io/badge/arXiv-2604.03955-b31b1b.svg)](https://arxiv.org/abs/2604.03955)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![CI](https://github.com/sym-bot/sym-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/sym-bot/sym-swift/actions/workflows/ci.yml)
[![中文文档](https://img.shields.io/badge/语言-中文-red)](README_zh.md)

## What SYM Handles

SYM handles discovery, connection, and collective intelligence. Your app finds other agents on the local network automatically — no servers, no accounts, no configuration. An iOS app and Claude Code on the same network discover each other and think together using the same protocol.

Before you start, read the [MMP Specification](https://sym.bot/spec/mmp) to understand the protocol — the 8-layer architecture, CMB structure, [SVAF](https://sym.bot/research/svaf) (Symbolic-Vector Attention Fusion) per-field evaluation that decides what enters each agent's memory, and how agents produce and consume signals on the mesh.

You build the domain logic — what your agent observes and how it responds to mesh events. See [How Agents Extract CAT7 Fields](https://github.com/sym-bot/sym#how-agents-extract-cat7-fields) for the three extraction approaches (LLM, structured data, prompt template).

## Proof of Concept

This is shipping in production. [MeloTune](https://melotune.ai) — an AI music agent — uses this SDK to join the mesh with a 100-line service class. When Claude Code broadcasts a mood ("tired after long debugging session"), MeloTune receives it over LAN and autonomously curates a matching playlist. No integration code between them. No API. They discover each other via Bonjour and speak the SYM protocol.

The same pattern works for any domain — fitness, focus, health, productivity, smart home. Your app contributes observations that only it can see. The mesh synthesizes signals across all agents into collective intelligence no single agent could build alone.

## Build Your Domain Agent

SYM gives you the infrastructure. You define what your agent knows:

- A **fitness app** shares workout completion, heart rate, energy level
- A **focus app** shares deep work sessions, break patterns, attention state
- A **health app** shares stress indicators, sleep quality, activity levels

Each agent contributes its domain signal. The mesh connects them. Every agent gets smarter because yours joined.

## Requirements

- iOS 17+ / macOS 14+
- Swift 5.9+
- SYM source is open (Apache 2.0). SYMCore is distributed as a precompiled xcframework via SPM binary target. SYMCore contains the CfC neural engine (closed-form continuous-time networks for affective state modeling) and the SVAF evaluator (per-field attention fusion for incoming CMBs). Source is not included to protect trained model weights.

## Integration

### 1. Add the package

In Xcode:

1. **File → Add Package Dependencies** → enter `https://github.com/sym-bot/sym-swift.git` → Add Package
2. When prompted to choose products, select **SYM** → Add to your app target
3. Your target → **General → Frameworks, Libraries, and Embedded Content** → verify **SYM** appears in the list

Or in Package.swift:

```swift
dependencies: [
    .package(url: "https://github.com/sym-bot/sym-swift.git", from: "0.3.2")
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

Create a service class that wraps `SymNode`. This is your app's domain layer — it decides what to do with mesh events.

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
            // Be specific — SYM uses this to evaluate relevance with other agents
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

    // MARK: - Wake (iOS background)

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
            // Your domain logic — handle command

        case .memoryReceived(_, let content, _, let cmb):
            logger.info("[Mesh] insight: \(content)")
            // Your domain logic — act on collective intelligence

        case .peerJoined(_, let name):
            peerCount = node?.peerList().count ?? 0
            logger.info("[Mesh] peer joined: \(name)")

        case .peerLeft(_, let name):
            peerCount = node?.peerList().count ?? 0
            logger.info("[Mesh] peer left: \(name)")

        case .xmeshInsight(_, let trajectory, _, _, _, _):
            guard trajectory.count >= 2 else { break }
            // trajectory[0] = valence, trajectory[1] = arousal
            // Your domain logic — act on collective intelligence

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
        WindowGroup {
            ContentView()
        }
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

Your app is on the mesh. It discovers other agents automatically via Bonjour. Claude Code, or any SYM node on the same network will find it.

## API

```swift
import SYM

let node = SymNode(name: "my-app")

// Lifecycle
node.start()
node.stop()

// Share observations — the agent extracts CAT7 fields from its domain data
node.remember(fields: [
    .focus:      CMBEncoder.encodeField("workout session completed"),
    .commitment: CMBEncoder.encodeField("30min, 320 cal burned"),
    .perspective: CMBEncoder.encodeField("fitness agent, post-workout"),
    .mood:       CMBEncoder.encodeField("energized", valence: 0.7, arousal: 0.6),
])

// Query the mesh
node.recall("energy patterns")   // [SymMemoryEntry]
node.peerList()                  // [SymPeerInfo]
node.status()                    // SymNodeStatus

// Background wake (iOS) — receive mesh signals while suspended
node.setWakeToken(platform: "apns", token: deviceToken, environment: "production")
node.reconnect()                 // Call from silent push handler

// Events — the mesh delivers, your app decides what to do
node.on { event in
    switch event {
    case .peerJoined(let id, let name): ...
    case .peerLeft(let id, let name): ...
    case .moodDelivered(let from, let mood, let drift): ...
    case .moodRejected(let from, let mood, let drift): ...
    case .memoryReceived(let from, let content, let decision, let cmb): ...
    case .message(let from, let content): ...
    case .xmeshInsight(let from, let trajectory, let patterns, let anomaly, let outcome, let coherence): ...
    case .couplingDecision(let peer, let decision, let drift): ...
    case .stateSyncReceived(_, _, _, _): break // deprecated (MMP v0.2.3 — hidden states never cross the wire)
    }
}
```

## Logging

SDK logs use the `[SYM]` prefix with categories:

```
[SYM] node: started: my-app (a1b2c3d4)
[SYM] discovery: found peer: other-app (e5f6g7h8)
[SYM] session: connection ready (outbound=true)
[SYM] session: handshake complete with other-app (e5f6g7h8)
[SYM] peer: connected: other-app (outbound, bonjour)
[SYM] mood: from other-app: "tired" → ACCEPTED (drift: 0.23)
[SYM] memory: stored: "user exhausted" → 1/1 peers
```

Categories: `node`, `discovery`, `session`, `peer`, `mood`, `memory`, `relay`, `wake`, `xmesh`, `coupling`

Your app's own logs should use a different prefix (e.g. `[Mesh]`, `[MyApp]`) to distinguish from SDK internals.

## Interoperability

Same wire protocol as [SYM](https://github.com/sym-bot/sym) (Node.js). A Swift app and Claude Code discover each other on the same network and exchange CMBs automatically. Cross-platform mesh verified: iOS ↔ macOS Catalyst ↔ Windows ↔ Node.js (April 2026).

Production-verified in [MeloTune](https://melotune.ai) (iOS, App Store since November 2025) — the first consumer app with SYM mesh cognition built in.

## References

- [MMP Specification v0.2.3](https://sym.bot/spec/mmp) — 8-layer protocol architecture
- [SVAF Paper (arXiv:2604.03955)](https://arxiv.org/abs/2604.03955) — Symbolic-Vector Attention Fusion for Collective Intelligence
- [Node.js SDK](https://github.com/sym-bot/sym) — reference implementation
- [Claude Code Plugin](https://github.com/sym-bot/sym-mesh-channel) — real-time Claude-to-Claude mesh

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). All changes must comply with the [MMP specification](https://sym.bot/spec/mmp) and pass CI before merge.

## License

Apache 2.0 — see [LICENSE](LICENSE)

**[SYM.BOT Ltd](https://sym.bot)**
