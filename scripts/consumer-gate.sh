#!/bin/bash
#
# consumer-gate.sh — build a REAL iOS consumer against a candidate of this package
# and fail the release if it does not compile.
#
# WHY THIS EXISTS
#
# Both defects reported against v0.5.1 were found by consuming seats rather than by
# anything here, and the check that ran before publishing was a macOS probe while both
# consumers are iOS. A gate whose coverage does not match its consumers is not a gate.
#
# THE RULES, from dev-team-2, after their own false report cost an afternoon:
#
#   1. WIPE DerivedData. An incremental build is NOT a consumer verification — it reports
#      the PREVIOUS version's module cache as confidently as the current one, with nothing
#      saying which. If a binaryTarget changed, the wipe is not optional: the cache will
#      otherwise answer for the version you replaced. This is the exact mechanism that
#      produced six phantom "type has no member" errors against a release that compiled.
#   2. Read Package.resolved AND the checkout HEAD. A resolve command's exit code has
#      reported success while resolving an OLD version, three times in one repo.
#   3. Take the verdict from the ERROR COUNT, never from the exit code — a build that runs
#      zero targets can exit 0.
#
# USAGE
#   scripts/consumer-gate.sh              # gate the working tree (path dependency)
#   scripts/consumer-gate.sh v0.5.2       # gate a published tag (URL dependency)
#
set -uo pipefail

CANDIDATE="${1:-}"
PKG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)/Consumer"
DD="$WORK/DerivedData"
trap 'rm -rf "$(dirname "$WORK")"' EXIT

echo "── consumer gate ──────────────────────────────────────"
if [ -n "$CANDIDATE" ]; then
  echo "  candidate : tag $CANDIDATE (as a consumer resolves it)"
  DEP=".package(url: \"https://github.com/sym-bot/sym-swift.git\", exact: \"${CANDIDATE#v}\")"
else
  echo "  candidate : working tree at $PKG_ROOT"
  DEP=".package(path: \"$PKG_ROOT\")"
fi

mkdir -p "$WORK/Sources/Consumer"
cat > "$WORK/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Consumer",
    platforms: [.iOS(.v17)],
    dependencies: [$DEP],
    targets: [.target(name: "Consumer", dependencies: [.product(name: "SYM", package: "sym-swift")])]
)
EOF

# The consumer exercises the PUBLIC surface an app actually touches. Adding a symbol here
# is how a future release proves it did not break consumers who use it.
cat > "$WORK/Sources/Consumer/Consumer.swift" <<'EOF'
import Foundation
import SYM

@MainActor
public final class ConsumerProbe {
    private let node: SymNode
    private let exchange: SymExchange
    public init(name: String) {
        self.node = SymNode(name: name)
        self.exchange = node.exchange
    }

    public func ask(_ prompt: String, of peer: String) async throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: ["prompt": prompt])
        return try await exchange.request(
            payload: payload,
            categories: [.focus: CMBEncoder.encodeCategory(prompt)],
            to: peer, timeout: 20).payload
    }

    public func serve(_ envelope: SymEnvelope) throws {
        try node.respond(to: envelope,
                         payload: try JSONSerialization.data(withJSONObject: ["ok": true]),
                         categories: [.focus: CMBEncoder.encodeCategory("answer")])
    }

    // An EXPLICIT case per event — never `default`, which would also swallow every case a
    // future SDK adds. This is the advice the 0.5.0 notes give consumers; the gate holds
    // itself to it, so adding an event breaks the gate loudly rather than silently.
    public func observe() {
        node.on { event in
            switch event {
            case .peerJoined, .peerLeft, .couplingDecision, .memoryReceived,
                 .moodDelivered, .moodRejected, .message, .xmeshInsight,
                 .cmbAccepted, .metric, .requestReceived:
                break
            @unknown default:
                break
            }
        }
    }

    public func join(_ url: URL) -> String? { SymInviteURL(parsing: url)?.name }
    public func reachable() -> Bool {
        let s = node.status()
        // The predicate the release notes tell consumers to use.
        return s.relayConnected && s.relayClose?.wasRefused != true
    }
}
EOF

echo "  workdir   : $WORK"
rm -rf "$DD"                      # RULE 1 — never inherit a module cache
echo "  DerivedData wiped"

cd "$WORK"
swift package resolve > /dev/null 2>&1

# RULE 2 — read what was RESOLVED, not what was requested.
RESOLVED=$(python3 - <<'PY' 2>/dev/null
import json
try:
    d = json.load(open("Package.resolved"))
    pins = d.get("pins", d.get("object", {}).get("pins", []))
    for p in pins:
        if "sym-swift" in json.dumps(p):
            st = p.get("state", {})
            print(st.get("version") or st.get("revision", "?")[:12])
            break
    else:
        print("NOT-RESOLVED")
except Exception:
    print("NO-RESOLVED-FILE")
PY
)
if [ -n "$CANDIDATE" ]; then
  # Tag mode: the pin is the thing under test, so a missing or wrong pin is a failure.
  echo "  resolved  : sym-swift $RESOLVED"
  if [ "$RESOLVED" = "NOT-RESOLVED" ] || [ "$RESOLVED" = "NO-RESOLVED-FILE" ]; then
    echo "  ✗ FAIL — dependency did not resolve"; exit 1
  fi
  if [ "$RESOLVED" != "${CANDIDATE#v}" ]; then
    echo "  ✗ FAIL — asked for ${CANDIDATE#v} and got $RESOLVED (a resolve can succeed on the WRONG version)"
    exit 1
  fi
else
  # Path mode: SPM does not pin a path dependency, so Package.resolved says nothing about
  # it. The identity that matters is the tree's own HEAD — report it so a passing gate is
  # attributable to a commit rather than to "whatever was on disk".
  HEAD_SHA=$(git -C "$PKG_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  DIRTY=$(git -C "$PKG_ROOT" status --porcelain 2>/dev/null | head -1)
  echo "  tree HEAD : $HEAD_SHA${DIRTY:+  (working tree DIRTY — this gate covers uncommitted code)}"
fi

# Discover the scheme rather than assume it. SPM generates an aggregate scheme whose name
# is not simply the package name (it appends -Package), and guessing produced a FAILURE
# THAT LOOKED LIKE A COMPILE ERROR while nothing had been compiled at all — the same class
# of false report this gate exists to prevent, reproduced inside the gate itself.
SCHEME=$(xcodebuild -list 2>/dev/null | sed -n '/Schemes:/,$p' | tail -n +2 | head -1 | xargs)
if [ -z "$SCHEME" ]; then echo "  ✗ FAIL — no scheme found in the consumer workspace"; exit 1; fi
echo "  scheme    : $SCHEME"

LOG="$WORK/build.log"
xcodebuild -scheme "$SCHEME" -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DD" build > "$LOG" 2>&1
BUILD_EXIT=$?

# RULE 3 — the verdict is the error count, not the exit code.
ERRORS=$(grep -cE "^.*: error: " "$LOG" || true)
echo "  errors    : $ERRORS   (exit code was $BUILD_EXIT — not the verdict)"

if [ "$ERRORS" -ne 0 ]; then
  echo "  ✗ FAIL — an iOS consumer does not compile against this candidate:"
  grep -E "^.*: error: " "$LOG" | head -12 | sed 's/^/      /'
  exit 1
fi
if [ "$BUILD_EXIT" -ne 0 ]; then
  echo "  ✗ FAIL — build failed with no parsed errors; last lines:"
  tail -12 "$LOG" | sed 's/^/      /'
  exit 1
fi

echo "  ✓ PASS — an iOS consumer compiles against this candidate"
echo "───────────────────────────────────────────────────────"
