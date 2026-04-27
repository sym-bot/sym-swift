# SYM Swift — Mesh Memory Protocol (MMP) iOS/macOS 原生实现

> **将你的 iOS / macOS 应用接入智能体网格，与局域网内所有 SYM 节点协同思考**

[![Swift Package](https://img.shields.io/badge/Swift_Package-v0.3.66-orange)](https://github.com/sym-bot/sym-swift)
[![Platform](https://img.shields.io/badge/Platform-iOS%2017+%20%7C%20macOS%2014+-blue)](https://developer.apple.com)
[![MMP Spec](https://img.shields.io/badge/MMP-v1.0-blue)](https://meshcognition.org/spec/mmp)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)

---

## 核心价值

当前应用中的 AI 智能体普遍处于「孤岛状态」：健身应用看到用户完成训练，编码助手察觉用户疲劳，音乐应用发现用户跳过常听歌单——但没有任何单一应用能将「训练完成」+「提交频率下降」+「跳过歌单」关联为「用户可能疲劳，需要调整体验」。

**SYM Swift 不是又一个 SDK，而是一套让自主智能体在保持上下文独立的前提下，通过结构化认知消息交换实现协同推理的底层协议原生实现。**

- 零配置局域网发现（Bonjour mDNS）
- 与 Node.js 参考实现完全互操作
- 原生 Swift API，符合 Apple 平台开发范式
- 生产环境验证：MeloTune（App Store，2025 年 11 月起）

> **重要澄清**：
> - 智能体之间**不共享上下文**，仅通过离散认知消息块（CMB）交换信息
> - 接收方收到的是**通道通知**，后续处理由应用逻辑或用户交互决定
> - 所有认知内容必须使用 `cmb` 帧格式传输（MMP v1.0+）

---

## 设计原则

| 原则 | 说明 |
|------|------|
| **智能体自治** | 每个应用维护完全独立的对话上下文与记忆存储（MMP §2.4），不共享状态 |
| **离散消息交换** | 通过认知记忆块（CMB）传递结构化信息，非连续状态同步 |
| **按字段评估** | SVAF 对每条消息的 7 个认知字段独立评估相关性，决定接收策略 |
| **零配置发现** | 基于 DNS-SD (Bonjour) 的局域网自动发现，无需服务器或手动配置 |
| **协议可组合** | 上层应用可基于 MMP 构建专属认知协议，底层传输与身份层保持正交 |

---

## 技术架构：8 层协议栈（Swift 原生实现）

```
┌─────────────────────────────────┐
│ Layer 7: 应用认知层              │ ← 你的业务逻辑（MeshService）
├─────────────────────────────────┤
│ Layer 6: CfC 神经动力学层        │ ← SYMCore 预编译组件（闭式连续时间神经网络）
├─────────────────────────────────┤
│ Layer 5: 合成记忆层              │ ← 跨智能体记忆融合策略
├─────────────────────────────────┤
│ Layer 4: SVAF 认知耦合层         │ ← 按字段相关性评估与注意力融合
├─────────────────────────────────┤
│ Layer 3: CMB 认知消息层          │ ← CAT7 七字段结构化消息格式
├─────────────────────────────────┤
│ Layer 2: 传输层 (TCP/WS)         │ ← 长度前缀 JSON 线格式
├─────────────────────────────────┤
│ Layer 1: 身份与加密层            │ ← 密钥对、签名、端到端加密
├─────────────────────────────────┤
│ Layer 0: 发现层 (DNS-SD/Bonjour) │ ← 零配置局域网发现
└─────────────────────────────────┘
```

### SYMCore 组件说明

| 组件 | 功能 | 分发形式 |
|------|------|----------|
| **SYM** | 协议栈主框架（发现、连接、事件循环、CMB 编码） | 开源源码（Apache 2.0） |
| **SYMCore.xcframework** | CfC 神经引擎 + SVAF 评估器（含训练模型权重） | 预编译二进制（通过 SPM 分发） |

> SYMCore 包含经 237K 样本训练的神经网络权重，为保护知识产权采用二进制分发。接口完全开放，行为符合 MMP 规范，支持审计与调试。

---

## 快速集成

### 前置要求
- iOS 17+ / macOS 14+ / visionOS 1+
- Swift 5.9+
- Xcode 15+
- 启用本地网络权限（见下方配置）

### 步骤 1：添加 Swift Package

**Xcode 图形界面**：
1. `File → Add Package Dependencies`
2. 输入 `https://github.com/sym-bot/sym-swift.git`
3. 选择产品 **SYM** → 添加到你的 App Target

**Package.swift**：
```swift
dependencies: [
    .package(url: "https://github.com/sym-bot/sym-swift.git", from: "0.3.66")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "SYM", package: "sym-swift")
        ]
    )
]
```

### 步骤 2：配置网络权限

**Info.plist**：
```xml
<key>NSLocalNetworkUsageDescription</key>
<string>本应用使用本地网络与其他 SYM 智能体协同思考，提供更个性化的体验。</string>

<key>NSBonjourServices</key>
<array>
    <string>_sym._tcp</string>
</array>
```

**Entitlements**（`.entitlements` 文件）：
```xml
<key>com.apple.security.network.server</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

> 两项均为必需：`server` 用于 Bonjour 广播（让其他节点发现你），`client` 用于主动连接对等节点。

### 步骤 3：创建 Mesh 服务类

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
    private let logger = Logger(subsystem: "com.example.app", category: "Mesh")
    
    private init() {}
    
    func start() {
        guard !isRunning else { return }
        
        let symNode = SymNode(
            name: "fitness-companion",
            cognitiveProfile: "Fitness agent that tracks workouts, heart rate, and energy levels",
            svafFieldWeights: FIELD_WEIGHT_PROFILES.fitness,
            svafFreshnessSeconds: 10800
        )
        self.node = symNode
        
        symNode.on { [weak self] event in
            Task { @MainActor in
                self?.handleEvent(event)
            }
        }
        
        symNode.start()
        isRunning = true
        logger.info("[Mesh] started: \(symNode.nodeId)")
    }
    
    func stop() {
        guard isRunning else { return }
        node?.stop()
        node = nil
        isRunning = false
        peerCount = 0
        logger.info("[Mesh] stopped")
    }
    
    func setWakeToken(platform: String, token: String, environment: String) {
        node?.setWakeToken(platform: platform, token: token, environment: environment)
    }
    
    func reconnect() {
        node?.reconnect()
    }
    
    private func handleEvent(_ event: SymEvent) {
        switch event {
        case .moodDelivered(let from, let mood, let drift):
            logger.info("[Mesh] mood from \(from): \(mood) (drift: \(drift, format: .number))")
            
        case .memoryReceived(_, let content, let decision, let cmb):
            logger.info("[Mesh] insight received: \(content) (decision: \(decision))")
            
        case .peerJoined(_, let name):
            peerCount = node?.peerList().count ?? 0
            logger.info("[Mesh] peer joined: \(name) (total: \(peerCount))")
            
        case .xmeshInsight(_, let trajectory, let patterns, _, _, _):
            break
            
        default:
            break
        }
    }
}
```

### 步骤 4：应用启动时初始化

**SwiftUI**：
```swift
import SwiftUI

@main
struct YourApp: App {
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

### 步骤 5：发布认知消息（可选）

```swift
node?.remember(fields: [
    .focus:      CMBEncoder.encodeField("workout session completed"),
    .issue:      CMBEncoder.encodeField("none"),
    .intent:     CMBEncoder.encodeField("log progress and recover"),
    .motivation: CMBEncoder.encodeField("maintain consistent training rhythm"),
    .commitment: CMBEncoder.encodeField("30min, 320 cal burned"),
    .perspective: CMBEncoder.encodeField("fitness agent, post-workout, morning"),
    .mood:       CMBEncoder.encodeField("energized", valence: 0.7, arousal: 0.6)
])
```

> **字段提取策略**：
> - 结构化数据应用（如健身追踪）：直接映射域数据到 CAT7 字段
> - 非结构化文本应用：调用 LLM API 按 [MMP 提示模板](https://meshcognition.org/spec/mmp#cat7) 提取字段
> - 混合应用：结合规则引擎与轻量 LLM

---

## 配置指南

### 认知画像预置模板

| 画像 | 适用场景 | 新鲜度窗口 | 设计理由 |
|------|----------|------------|----------|
| `music` | 音乐/氛围应用 | 1,800s (30min) | 情绪状态变化快，需快速响应 |
| `coding` | 编码助手/开发工具 | 7,200s (2hr) | 会话上下文重要，昨日调试信息价值衰减 |
| `fitness` | 健康/运动追踪 | 10,800s (3hr) | 久坐检测需累积数小时行为模式 |
| `messaging` | 聊天/通知类应用 | 3,600s (1hr) | 近期对话上下文相关性最高 |
| `knowledge` | 资讯/研究类应用 | 86,400s (24hr) | 按日周期更新，新闻时效性以天为单位 |
| `uniform` | 通用原型/测试 | 1,800s (30min) | 无字段偏好，适合作为起点 |

### 漂移阈值

| 区域 | 漂移值 | 行为 | 置信度 |
|------|--------|------|--------|
| **对齐** | ≤ 0.25 | 接收并融合 | 完整 |
| **审慎** | 0.25–0.50 | 接收但降权 | 衰减 |
| **拒绝** | > 0.50 | 丢弃 | — |

---

## 典型应用场景

### 健身应用 × 编码助手 × 音乐应用：疲劳感知协同

| 应用 | 观测内容 | 网格合成洞察 |
|------|----------|--------------|
| **健身应用** | 「训练完成，心率 145，能量值 0.7」 | → 用户刚完成高强度训练 |
| **Claude Code** | 「提交频率下降，消息变短，情绪值 -0.3」 | → 用户可能疲劳 |
| **音乐应用** | 「跳过常听歌单 3 次」 | → 当前音乐不匹配用户状态 |

→ **网格推理**：多信号能量衰减 → 非专注而是疲劳
→ **自主响应**：音乐切换舒缓曲风，健身应用建议拉伸，编码助手提示休息

---

## 与 Claude Code 实时协作

> 如需 **Claude 到 Claude 的实时推送**，请配合使用 [`@sym-bot/mesh-channel`](https://github.com/sym-bot/sym-mesh-channel)。

Swift 应用与 Claude Code 可跨平台互操作（已验证：iOS ↔ macOS ↔ Windows ↔ Node.js）。

---

## 其他实现与生态

| 语言 | 项目 | 维护者 | 范围 |
|------|------|--------|------|
| Swift | [sym-bot/sym-swift](https://github.com/sym-bot/sym-swift) | SYM.BOT | iOS/macOS 参考实现 |
| Node.js | [sym-bot/sym](https://github.com/sym-bot/sym) | SYM.BOT | 参考实现 |
| Rust | [AxonOS/axonos-consent](https://github.com/AxonOS-org/axonos-consent) | AxonOS | 零分配、Cortex-M4F |
| Node.js (MCP) | [sym-bot/sym-mesh-channel](https://github.com/sym-bot/sym-mesh-channel) | SYM.BOT | Claude Code 插件 |

---

## 延伸阅读

- [MMP 协议规范 (v1.0)](https://meshcognition.org/spec/mmp)
- [SVAF 技术论文 (arXiv:2604.03955)](https://arxiv.org/abs/2604.03955)
- [贡献指南](CONTRIBUTING.md)

---

## 许可证

- **参考实现代码**：[Apache License 2.0](LICENSE)
- **SYMCore 二进制组件**：仅限与开源框架配套使用

> © 2026 SYM.BOT

---

> **集体智能不是让智能体变成同一个大脑，而是让每个自主大脑在保持独立的前提下，看见彼此眼中的世界。**

*最后更新：2026 年 4 月 10 日 · 跨平台互操作验证：iOS ↔ macOS ↔ Windows ↔ Node.js*
