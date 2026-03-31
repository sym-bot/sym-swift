# SYM Swift

**让你的 iOS 或 macOS 应用加入 mesh，和网络上的所有 Agent 一起思考。**

你的应用看到运动数据。Claude Code 看到疲劳。MeloTune 看到跳过的播放列表。单独看都是噪声。在 mesh 上，它们成为集体智能——你的应用自主响应。

SYM Swift 是 [Mesh Memory Protocol (MMP)](https://sym.bot/spec/mmp) 的原生 SDK。添加 package，接入一个 service 类，你的应用就能和 Claude Code 以及本地网络上的任何 SYM Agent 协作。无需服务器，无需 API，无需对接代码。

[![Swift](https://img.shields.io/badge/Swift_SPM-compatible-orange)](https://github.com/sym-bot/sym-swift)
[![MMP Spec](https://img.shields.io/badge/protocol-MMP_v0.2.0-purple)](https://sym.bot/spec/mmp)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![CI](https://github.com/sym-bot/sym-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/sym-bot/sym-swift/actions/workflows/ci.yml)
[![English](https://img.shields.io/badge/lang-English-blue)](README.md)

## SYM 负责什么

SYM 处理发现、连接和集体智能。你的应用自动发现本地网络上的其他 Agent——无需服务器、无需账号、无需配置。iOS 应用和 Claude Code 在同一网络上自动发现彼此，使用相同的协议一起思考。

开始之前，请阅读 [MMP 规范](https://sym.bot/spec/mmp) 了解协议——8 层架构、CMB 结构、[SVAF](https://sym.bot/research/svaf)（符号-向量注意力融合）逐字段评估，以及 Agent 如何在 mesh 上产生和消费信号。

你负责领域逻辑——你的 Agent 观察什么，以及如何响应 mesh 事件。参见 [如何提取 CAT7 字段](https://github.com/sym-bot/sym#how-agents-extract-cat7-fields)了解三种提取方式（LLM、结构化数据、提示模板）。

## 已在生产环境运行

[MeloTune](https://melotune.ai)——一个 AI 音乐 Agent——使用这个 SDK 加入 mesh，只需约 100 行 service 类。当 Claude Code 广播情绪（"长时间编码后疲劳"），MeloTune 通过局域网接收并自主策展匹配的播放列表。没有对接代码，没有 API。它们通过 Bonjour 发现彼此，使用 SYM 协议通信。

同样的模式适用于任何领域——健身、专注、健康、生产力、智能家居。你的应用贡献只有它能看到的观察。Mesh 将所有 Agent 的信号综合为集体智能。

## 构建你的领域 Agent

SYM 提供基础设施。你定义 Agent 的领域知识：

- **健身应用**分享运动完成情况、心率、能量水平
- **专注应用**分享深度工作时段、休息模式、注意力状态
- **健康应用**分享压力指标、睡眠质量、活动水平

每个 Agent 贡献自己的领域信号。Mesh 连接它们。因为你的 Agent 加入，每个 Agent 都变得更智能。

## 要求

- iOS 17+ / macOS 14+
- Swift 5.9+
- SYM 源码开放（Apache 2.0）。SYMCore 以预编译 xcframework 形式通过 SPM 二进制目标分发。

## 集成步骤

### 1. 添加 package

在 Xcode 中：

1. **File → Add Package Dependencies** → 输入 `https://github.com/sym-bot/sym-swift.git` → Add Package
2. 选择产品时，选 **SYM** → 添加到你的 app target
3. 在 target → **General → Frameworks, Libraries, and Embedded Content** → 确认 **SYM** 出现在列表中

或在 Package.swift 中：

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

### 2. 添加网络权限

SYM 通过 Bonjour 在本地网络上发现 peer。

在 `Info.plist` 中添加：

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>此应用使用本地网络连接 SYM mesh 上的其他 AI 智能体。</string>

<key>NSBonjourServices</key>
<array>
    <string>_sym._tcp</string>
</array>
```

在应用的 `.entitlements` 文件中添加：

```xml
<key>com.apple.security.network.server</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

两者都必需——`network.server` 用于 Bonjour 广播（其他 Agent 发现你），`network.client` 用于连接 peer。

### 3. 创建 mesh service

创建一个封装 `SymNode` 的 service 类。这是你应用的领域层——决定如何响应 mesh 事件。

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
            cognitiveProfile: "跟踪运动、心率和能量水平的健身 Agent"
            // 尽量具体——SYM 用这个来评估与其他 Agent 的相关性
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

    // MARK: - 唤醒（iOS 后台）

    func setWakeToken(platform: String, token: String, environment: String) {
        node?.setWakeToken(platform: platform, token: token, environment: environment)
    }

    func reconnect() {
        node?.reconnect()
    }

    // MARK: - 事件处理

    private func handleEvent(_ event: SymEvent) {
        switch event {
        case .moodAccepted(let from, let mood, _):
            logger.info("[Mesh] mood from \(from): \(mood)")
            // 你的领域逻辑——响应情绪

        case .moodRejected:
            break

        case .message(let from, let content):
            logger.info("[Mesh] message from \(from): \(content)")

        case .memoryReceived(_, let content, _, let cmb):
            logger.info("[Mesh] insight: \(content)")
            // 你的领域逻辑——响应集体智能

        case .peerJoined(_, let name):
            peerCount = node?.peerList().count ?? 0
            logger.info("[Mesh] peer joined: \(name)")

        case .peerLeft(_, let name):
            peerCount = node?.peerList().count ?? 0
            logger.info("[Mesh] peer left: \(name)")

        case .xmeshInsight(_, let trajectory, _, _, _, _):
            guard trajectory.count >= 2 else { break }
            // trajectory[0] = valence, trajectory[1] = arousal
            // 你的领域逻辑——响应集体智能

        default:
            break
        }
    }
}
```

### 4. 在应用启动时启动

**SwiftUI：**

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

**UIKit：**

```swift
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    MeshService.shared.start()
    return true
}
```

### 5. 没有第 5 步。

你的应用已经在 mesh 上了。它通过 Bonjour 自动发现其他 Agent。Claude Code 或同一网络上的任何 SYM 节点都会找到它。

## API

```swift
import SYM

let node = SymNode(name: "my-app")

// 生命周期
node.start()
node.stop()

// 分享观察——Agent 从领域数据中提取 CAT7 字段
node.remember(fields: [
    .focus:      CMBEncoder.encodeField("运动完成"),
    .commitment: CMBEncoder.encodeField("30分钟, 消耗320卡"),
    .perspective: CMBEncoder.encodeField("健身 Agent, 运动后"),
    .mood:       CMBEncoder.encodeField("充满活力", valence: 0.7, arousal: 0.6),
])

// 查询 mesh
node.recall("能量模式")              // [SymMemoryEntry]
node.peerList()                     // [SymPeerInfo]
node.status()                       // SymNodeStatus

// 后台唤醒（iOS）——在挂起时接收 mesh 信号
node.setWakeToken(platform: "apns", token: deviceToken, environment: "production")
node.reconnect()                    // 在静默推送处理器中调用

// 事件——mesh 传递信号，你的应用决定如何响应
node.on { event in
    switch event {
    case .peerJoined(let id, let name): ...
    case .peerLeft(let id, let name): ...
    case .moodAccepted(let from, let mood, let drift): ...
    case .moodRejected(let from, let mood, let drift): ...
    case .memoryReceived(let from, let content, let decision, let cmb): ...
    case .message(let from, let content): ...
    case .xmeshInsight(let from, let trajectory, let patterns, let anomaly, let outcome, let coherence): ...
    case .couplingDecision(let peer, let decision, let drift): ...
    case .stateSyncReceived(let from, let h1, let h2, let confidence): ...
    }
}
```

## 互操作性

和 [SYM](https://github.com/sym-bot/sym)（Node.js）使用相同的线路协议。Swift 应用和 Claude Code 在同一网络上自动发现彼此并一起思考。

## 贡献

参见 [CONTRIBUTING.md](CONTRIBUTING.md)。所有更改必须符合 [MMP 规范](https://sym.bot/spec/mmp) 并通过 CI。

欢迎中文社区的 PR 和 Issue。

## 许可证

Apache 2.0 — 参见 [LICENSE](LICENSE)

**[SYM.BOT Ltd](https://sym.bot)**
