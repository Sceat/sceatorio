import assert from "node:assert/strict";
import crypto from "node:crypto";
import test, { mock } from "node:test";

import type { AccessGrant } from "../src/auth/authorize.js";
import { InMemoryCredentialStore, parseBearer } from "../src/http/credentials.js";

const NOW = 1_000_000;

function grant(overrides: Partial<AccessGrant> = {}): AccessGrant {
  return {
    bindingId: "binding-0000000000000001",
    principalId: "remote-mcp:1",
    tokenId: "unset",
    saveId: "save-1",
    playerId: "player-1",
    forceId: "force-1",
    teamId: "team-1",
    capabilities: new Set(["session:read"]),
    surfaces: [
      { surfaceId: "nauvis", forceId: "force-1", kind: "primary", visibility: "force-chart" }
    ],
    preferences: {
      enabled: true,
      requestedCapabilities: ["session:read"],
      notifications: "important",
      blueprintDelivery: "inbox-only"
    },
    issuedAtMs: NOW,
    expiresAtMs: NOW + 60_000,
    ...overrides
  };
}

test("a minted bearer verifies once and only in its own exact form", () => {
  const store = new InMemoryCredentialStore();
  const credential = store.mint(grant(), NOW);

  assert.match(credential.token, /^scto_[0-9a-f]{18}_[0-9a-f]{64}$/);
  assert.equal(store.verify(credential.token, NOW)?.playerId, "player-1");
  assert.equal(store.verify(credential.token, NOW)?.tokenId, credential.tokenId);

  const [, tokenId, secret] = /^scto_([0-9a-f]{18})_([0-9a-f]{64})$/.exec(credential.token)!;
  const wrongSecret = `scto_${tokenId}_${secret!.replace(/.$/, (last) => (last === "a" ? "b" : "a"))}`;
  assert.equal(store.verify(wrongSecret, NOW), undefined, "a wrong secret must not verify");
  assert.equal(
    store.verify(`scto_${"0".repeat(18)}_${secret!}`, NOW),
    undefined,
    "an unknown token id must not verify"
  );
  assert.equal(store.verify("scto_nope", NOW), undefined);
  assert.equal(store.verify(undefined, NOW), undefined);
});

test("secret comparison goes through timingSafeEqual", () => {
  const timingSafeEqual = mock.method(crypto, "timingSafeEqual");
  try {
    const store = new InMemoryCredentialStore();
    const credential = store.mint(grant(), NOW);
    timingSafeEqual.mock.resetCalls();
    assert.notEqual(store.verify(credential.token, NOW), undefined);
    assert.equal(timingSafeEqual.mock.callCount(), 1);

    timingSafeEqual.mock.resetCalls();
    assert.equal(store.verify(`scto_${"0".repeat(18)}_${"0".repeat(64)}`, NOW), undefined);
    assert.equal(
      timingSafeEqual.mock.callCount(),
      1,
      "an unknown token id must still cost one constant-time comparison"
    );
  } finally {
    timingSafeEqual.mock.restore();
  }
});

test("an expired grant is refused and dropped", () => {
  const store = new InMemoryCredentialStore();
  const credential = store.mint(grant({ expiresAtMs: NOW + 1_000 }), NOW);

  assert.notEqual(store.verify(credential.token, NOW + 999), undefined);
  assert.equal(store.verify(credential.token, NOW + 1_000), undefined, "expiry is exclusive");
  assert.equal(store.size, 0, "an expired credential is not kept around");
});

test("re-pairing a player replaces that player's credential", () => {
  const store = new InMemoryCredentialStore();
  const first = store.mint(grant(), NOW);
  const other = store.mint(grant({ playerId: "player-2" }), NOW);
  const second = store.mint(grant(), NOW);

  assert.equal(store.verify(first.token, NOW), undefined, "the old binding is revoked");
  assert.notEqual(store.verify(second.token, NOW), undefined);
  assert.notEqual(store.verify(other.token, NOW), undefined, "other players are untouched");
});

test("bearer parsing accepts only a well-formed Authorization header", () => {
  assert.equal(parseBearer("Bearer scto_x"), "scto_x");
  assert.equal(parseBearer("bearer   scto_x"), "scto_x");
  assert.equal(parseBearer("Basic scto_x"), undefined);
  assert.equal(parseBearer(null), undefined);
});
