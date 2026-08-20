#!/usr/bin/env node
//
// Swift ↔ Node payload interop gate (0.5.0 release condition).
//
// The correlation surface is worth nothing if the two implementations
// disagree about where the payload lives on the wire, so this drives REAL
// bytes through BOTH sides rather than asserting a shape twice:
//
//   A. Node reads Swift.  Swift emits length-prefixed frames into a fixture
//      file; Node's own FrameParser parses them and Node's own
//      _preserveIncomingPayload lifts the payload — the actual functions a
//      Node peer would run, not a re-implementation of them.
//   B. Swift reads Node.  Node emits a frame shaped exactly as the
//      llm-sidecar writes one; the Swift suite parses it and asserts the
//      payload and request_id survive.
//
// Both directions cover BOTH SVAF verdicts: the payload must survive an
// admitted remix (which Node rebuilds from CAT7, losing siblings unless
// preserved) and a rejected-but-directed delivery. That asymmetry is not
// hypothetical — it shipped once, and delivery silently depended on the
// receiver's per-node drift.
//
// Usage: node scripts/interop-payload-gate.mjs <fixture-dir>
// Exits non-zero on any mismatch.

import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const require = createRequire(import.meta.url);
const SYM_ROOT = process.env.SYM_NODE_ROOT || '/Users/hongwei/code/sym';

const { FrameParser } = require(join(SYM_ROOT, 'lib/frame-parser.js'));

const fixtureDir = process.argv[2];
if (!fixtureDir) {
  console.error('usage: interop-payload-gate.mjs <fixture-dir>');
  process.exit(2);
}

let failures = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok || !detail ? '' : ` — ${detail}`}`);
  if (!ok) failures++;
};

// ─────────────────────────────────────────────────────────────────────
// A. Node reads Swift
// ─────────────────────────────────────────────────────────────────────

const swiftFixture = join(fixtureDir, 'swift-payload-frames.bin');
if (!existsSync(swiftFixture)) {
  console.error(`missing ${swiftFixture} — run the Swift emitter first`);
  process.exit(2);
}

const frames = [];
const parser = new FrameParser();
parser.on('message', (msg) => frames.push(msg));
parser.on('error', (err) => check('node parses swift frames', false, err.message));
parser.feed(readFileSync(swiftFixture));

check('A1 node parsed every swift frame', frames.length === 2,
      `parsed ${frames.length}, expected 2 (plaintext + e2e)`);

const plaintext = frames[0];
check('A2 payload is a sibling of CAT7 inside cmb (msg.cmb.payload)',
      plaintext?.cmb?.payload != null,
      `got ${JSON.stringify(plaintext?.cmb?.payload ?? null)}`);
check('A3 request_id is snake_case and intact',
      plaintext?.cmb?.payload?.request_id === 'swift-to-node-1',
      `got ${plaintext?.cmb?.payload?.request_id}`);
check('A4 the CAT7 content is untouched alongside it',
      plaintext?.cmb?.categories != null && Object.keys(plaintext.cmb.categories).length > 0,
      'categories missing');

// Node's OWN preservation function, on both verdict paths.
const { SymNode } = require(join(SYM_ROOT, 'lib/node.js'));
const preserve = SymNode.prototype._preserveIncomingPayload
  ? SymNode.prototype._preserveIncomingPayload
  : require(join(SYM_ROOT, 'lib/frame-handler.js')).FrameHandler?.prototype?._preserveIncomingPayload;

if (typeof preserve === 'function') {
  // ADMITTED: the fused remix is rebuilt from CAT7 and would lose the
  // sibling payload without preservation — the exact shape that shipped.
  const fusedEntry = { cmb: { key: 'cmb-fused', categories: {} } };
  preserve.call({}, fusedEntry, plaintext);
  check('A5 payload survives the ADMITTED path (rebuilt remix keeps the sibling)',
        fusedEntry.cmb.payload?.request_id === 'swift-to-node-1',
        `got ${JSON.stringify(fusedEntry.cmb.payload ?? null)}`);

  // REJECTED-but-directed: the raw msg surfaces, payload rides on it.
  check('A6 payload survives the REJECTED-but-directed path (raw msg carries it)',
        plaintext.cmb.payload?.request_id === 'swift-to-node-1');
} else {
  check('A5/A6 node preservation function reachable', false,
        '_preserveIncomingPayload not found — cannot prove verdict independence');
}

// The E2E-shaped frame: Swift clears `cmb`, so the payload rides top level.
// A Node peer never receives this shape today (the JS side announces no
// e2ePublicKey, so the pair never derives a secret) — asserted here so the
// divergence stays KNOWN rather than becoming a silent drop later.
const e2e = frames[1];
check('A7 e2e-shaped swift frame still parses on the node side',
      e2e != null && e2e.type === 'cmb');
// Assert the DIVERGENCE, not a lenient either-or. Node reads msg.cmb.payload
// and nothing else, so a Swift e2e frame's top-level payload is invisible to
// it. That is acceptable only because this shape never reaches a Node peer —
// the JS side announces no e2ePublicKey, so a Swift↔JS pair never derives a
// secret and always falls back to plaintext. Asserting the real state of
// affairs is what keeps this a known divergence instead of a latent drop:
// if JS ever announces a key, A9 starts failing and says why.
check('A8 e2e frame carries its payload at top level (swift↔swift shape)',
      e2e?.cmbPayload?.request_id === 'swift-to-node-e2e',
      `got ${JSON.stringify(e2e?.cmbPayload ?? null)}`);
check('A9 KNOWN DIVERGENCE: node cannot read an e2e frame payload — ' +
      'holds only while JS announces no e2ePublicKey',
      e2e?.cmb?.payload == null,
      'msg.cmb.payload is now populated on the e2e shape — the divergence closed, update this gate');

// ─────────────────────────────────────────────────────────────────────
// B. Swift reads Node — emit the sidecar's exact shape
// ─────────────────────────────────────────────────────────────────────

// Built by Node's OWN createCMB, never hand-written. The first version of
// this gate invented a flat CMB with text/valence/arousal categories and the
// Swift parser dropped it entirely — because createCMB has minted a v2
// two-section record (categories + metadata) for some time, so the literal
// described a shape no Node peer still sends. A fixture that is authored
// rather than generated tests the author's belief, not the protocol.
const { createCMB, encodeCategory } = require(join(SYM_ROOT, 'lib/core/cmb-encoder.js'));

const categories = {};
for (const [name, text] of Object.entries({
  focus: 'llm request',
  intent: 'answer the prompt',
})) {
  categories[name] = await encodeCategory(text);
}

const nodeCMB = createCMB({
  categories,
  source: 'sym-llm-sidecar',
  createdBy: 'sym-llm-sidecar',
  originTimestamp: 1_785_700_000_000,
});
// The sidecar's convention: payload sibling of the CAT7 sections.
nodeCMB.payload = {
  request_id: 'node-to-swift-1',
  kind: 'llm-request',
  prompt: 'how did my human move today',
};

const nodeFrameObject = {
  type: 'cmb',
  source: 'sym-llm-sidecar',
  key: nodeCMB.metadata.key,
  cmb: nodeCMB,
};

const json = Buffer.from(JSON.stringify(nodeFrameObject), 'utf8');
const framed = Buffer.alloc(4 + json.length);
framed.writeUInt32BE(json.length, 0);
json.copy(framed, 4);
writeFileSync(join(fixtureDir, 'node-payload-frame.bin'), framed);

// Round-trip our own emission through Node's parser, so a malformed
// fixture fails here rather than looking like a Swift defect.
const backFrames = [];
const backParser = new FrameParser();
backParser.on('message', (m) => backFrames.push(m));
backParser.feed(framed);
check('B1 node fixture is well-formed (parses on the node side)',
      backFrames[0]?.cmb?.payload?.request_id === 'node-to-swift-1');
check('B2 fixture is the v2 two-section shape a real node peer sends',
      backFrames[0]?.cmb?.metadata?.key != null && backFrames[0]?.cmb?.categories != null,
      'not a v2 record — the Swift side would be testing a shape nobody sends');
console.log('\n  wrote node-payload-frame.bin — copy to Tests/Fixtures/ to update the Swift side');

console.log(`\n${failures === 0 ? 'GATE PASS' : `GATE FAIL (${failures})`}`);
process.exit(failures === 0 ? 0 : 1);
