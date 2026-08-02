import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { mock } from "node:test";

import type { AccessGrant } from "../src/auth/authorize.js";
import { CredentialStore, parseBearer } from "../src/http/credentials.js";

const NOW = 1_000_000;

function storePath(): string {
  return path.join(fs.mkdtempSync(path.join(os.tmpdir(), "sceatorio-creds-")), "credentials.json");
}

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
    ...overrides
  };
}

test("a minted bearer verifies once and only in its own exact form", () => {
  const store = new CredentialStore();
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
    const store = new CredentialStore();
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

test("a grant carries no expiry, so the bearer outlives any clock", () => {
  const store = new CredentialStore();
  const credential = store.mint(grant(), NOW);

  assert.equal(credential.expiresAtMs, undefined);
  assert.notEqual(store.verify(credential.token, NOW + 10 * 365 * 24 * 3_600_000), undefined);
  store.sweep(NOW + 10 * 365 * 24 * 3_600_000);
  assert.equal(store.size, 1, "a permanent credential is never swept");
});

test("a legacy grant that still has an expiry is refused and dropped", () => {
  const store = new CredentialStore();
  const credential = store.mint(grant({ expiresAtMs: NOW + 1_000 }), NOW);

  assert.notEqual(store.verify(credential.token, NOW + 999), undefined);
  assert.equal(store.verify(credential.token, NOW + 1_000), undefined, "expiry is exclusive");
  assert.equal(store.size, 0, "an expired credential is not kept around");
});

test("re-pairing a player replaces that player's credential", () => {
  const store = new CredentialStore();
  const first = store.mint(grant(), NOW);
  const other = store.mint(grant({ playerId: "player-2" }), NOW);
  const second = store.mint(grant(), NOW);

  assert.equal(store.verify(first.token, NOW), undefined, "the old binding is revoked");
  assert.notEqual(store.verify(second.token, NOW), undefined);
  assert.notEqual(store.verify(other.token, NOW), undefined, "other players are untouched");
});

test("a persisted store reloads its verifiers into a fresh instance", () => {
  const file = storePath();
  const first = new CredentialStore({ path: file });
  const credential = first.mint(grant(), NOW);

  const reloaded = new CredentialStore({ path: file });
  assert.equal(reloaded.size, 1);
  const verified = reloaded.verify(credential.token, NOW + 10 * 365 * 24 * 3_600_000);
  assert.equal(verified?.playerId, "player-1");
  assert.equal(verified?.bindingId, "binding-0000000000000001");
  assert.deepEqual([...verified!.capabilities], ["session:read"]);

  const [, , secret] = /^scto_([0-9a-f]{18})_([0-9a-f]{64})$/.exec(credential.token)!;
  const wrong = credential.token.replace(/.$/u, (last) => (last === "a" ? "b" : "a"));
  assert.equal(reloaded.verify(wrong, NOW), undefined, "a wrong secret still fails after a reload");

  const raw = fs.readFileSync(file, "utf8");
  assert.equal(raw.includes(secret!), false, "the plaintext secret is never written to disk");
  assert.equal(raw.includes(credential.token), false);
  assert.match(raw, new RegExp(crypto.createHash("sha256").update(secret!).digest("hex"), "u"));
  assert.equal(fs.statSync(file).mode & 0o777, 0o600, "the verifier file is owner-only");
});

test("revoking and re-pairing survive a reload", () => {
  const file = storePath();
  const first = new CredentialStore({ path: file });
  const stale = first.mint(grant(), NOW);
  const fresh = first.mint(grant(), NOW);
  const other = first.mint(grant({ playerId: "player-2" }), NOW);
  first.revoke(other.tokenId);

  const reloaded = new CredentialStore({ path: file });
  assert.equal(reloaded.size, 1);
  assert.equal(reloaded.verify(stale.token, NOW), undefined, "a replaced bearer stays dead");
  assert.equal(reloaded.verify(other.token, NOW), undefined, "a revoked bearer stays dead");
  assert.notEqual(reloaded.verify(fresh.token, NOW), undefined);
});

test("a missing, empty or malformed store starts empty instead of throwing", () => {
  const file = storePath();
  const logged: string[] = [];
  const logger = { error: (message: string) => logged.push(message) };

  assert.equal(new CredentialStore({ path: file, logger }).size, 0, "a missing file is normal");
  assert.deepEqual(logged, [], "a first boot is not an error");

  for (const content of ["", "   ", "{", '{"version":9,"credentials":[]}', "[]",
    '{"version":1,"credentials":[{"tokenId":"nope","secretHash":"x","grant":{}}]}']) {
    fs.writeFileSync(file, content);
    const store = new CredentialStore({ path: file, logger });
    assert.equal(store.size, 0, `content ${content} must not load credentials`);
    // Still usable: a bad file costs one re-pair, never the endpoint.
    assert.notEqual(store.verify(store.mint(grant(), NOW).token, NOW), undefined);
  }
  assert.equal(logged.length, 4, "an empty file is silent, each of the 4 malformed ones logs once");
});

test("bearer parsing accepts only a well-formed Authorization header", () => {
  assert.equal(parseBearer("Bearer scto_x"), "scto_x");
  assert.equal(parseBearer("bearer   scto_x"), "scto_x");
  assert.equal(parseBearer("Basic scto_x"), undefined);
  assert.equal(parseBearer(null), undefined);
});
