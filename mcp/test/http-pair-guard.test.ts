import assert from "node:assert/strict";
import test from "node:test";

import { PairGuard, isPairingCode } from "../src/http/pair-guard.js";

const NOW = 1_000_000;

test("only codes the mod could accept are recognised", () => {
  assert.equal(isPairingCode("ABCDE-FGHJ-KMNP"), true);
  assert.equal(isPairingCode("ABCDE-FGHJ-KMN"), false, "wrong length");
  assert.equal(isPairingCode("ABCDEFGHJKMNPQR"), false, "missing separators");
  assert.equal(isPairingCode("ABCDE-FGHI-KMNP"), false, "I is not in the alphabet");
  assert.equal(isPairingCode("ABCDE-FGH0-KMNP"), false, "0 is not in the alphabet");
  assert.equal(isPairingCode("abcde-fghj-kmnp"), false, "the alphabet is upper case");
  assert.equal(isPairingCode(42), false);
});

test("five forwarded failures a minute is the ceiling, whatever the source", () => {
  const guard = new PairGuard();
  for (let attempt = 0; attempt < 5; attempt += 1) {
    assert.equal(guard.admit(`10.0.0.${attempt}`, NOW), "allow");
    guard.recordFailure(NOW);
  }
  assert.equal(
    guard.admit("10.0.0.99", NOW),
    "shedding",
    "the sixth failure in a minute never reaches the game"
  );
  assert.equal(guard.admit("10.0.0.99", NOW + 59_999), "shedding");
  assert.equal(guard.admit("10.0.0.99", NOW + 60_001), "allow", "the window rolls");
});

test("one address cannot grind codes", () => {
  const guard = new PairGuard();
  for (let attempt = 0; attempt < 5; attempt += 1) {
    assert.equal(guard.admit("10.0.0.1", NOW + attempt), "allow");
  }
  assert.equal(guard.admit("10.0.0.1", NOW + 5), "ip-throttled");
  assert.equal(guard.admit("10.0.0.2", NOW + 5), "allow", "other players are unaffected");
  guard.recordSuccess("10.0.0.1");
  assert.equal(guard.admit("10.0.0.1", NOW + 6), "allow", "pairing clears the bucket");
});

test("a clock stepped backwards keeps the guard closed, then heals", () => {
  const guard = new PairGuard();
  for (let attempt = 0; attempt < 5; attempt += 1) {
    guard.recordFailure(NOW);
  }
  const jumped = NOW - 3_600_000;
  assert.equal(guard.admit("10.0.0.1", jumped), "shedding", "the window survives the jump");
  assert.equal(guard.admit("10.0.0.1", jumped + 60_001), "allow", "and expires one window later");
});
