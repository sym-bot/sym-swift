# Changelog

> **Note:** Versions 0.3.24 – 0.3.54 were released as git tags without changelog entries. Changelog resumes at 0.3.55 below.

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
