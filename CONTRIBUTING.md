# Contributing to SYM Swift

SYM Swift is the reference Swift/iOS implementation of the [Mesh Memory Protocol (MMP)](https://meshcognition.org/spec/mmp). All changes must comply with the specification.

## Branch Strategy

- **`main`** is protected. No direct pushes.
- Create feature branches from `main` (e.g. `feat/uuid-v7`, `fix/bonjour-discovery`).
- Submit a pull request. All PRs require at least one review and passing CI before merge.

## Before Submitting a PR

1. **Read the spec.** If your change touches identity, transport, connection, memory, coupling, or any protocol layer, verify it conforms to [MMP](https://meshcognition.org/spec/mmp).
2. **Run tests.** All tests must pass:
   ```bash
   swift test
   ```
3. **Verify both platforms.** Changes must compile for iOS 17+ and macOS 14+.
4. **Keep commits focused.** One logical change per commit. Reference MMP spec sections where applicable.

## Development Setup

```bash
git clone https://github.com/sym-bot/sym-swift.git
cd sym-swift
swift build
swift test
```

Requires Xcode with iOS 17 SDK and macOS 14 SDK.

## SYMCore Binary Framework

`SYMCore.xcframework` is a precompiled binary dependency containing the cognitive core (context encoder, SVAF evaluator, E2E crypto). The source lives in a separate private repository (`sym-core-swift`). If your change requires modifications to SYMCore, open an issue first.

## Code Style

- Match existing patterns. Follow Swift conventions.
- Production quality: proper error handling, no shortcuts.
- Only add comments where logic isn't self-evident.
- Use `os.log` (`Logger`) for diagnostics, not `print()`.

## Spec Changes

If you believe the MMP spec itself should change, open an issue describing the proposed change and rationale before implementing. Spec changes require separate review at [symbot-website](https://github.com/sym-bot/symbot-website).
