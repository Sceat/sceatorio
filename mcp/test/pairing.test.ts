import assert from "node:assert/strict";
import test from "node:test";

import {
  PairingExchangeError,
  descriptorToAccessGrant,
  exchangePairingCode
} from "../src/pairing.js";
import {MockDatagramPeer} from "../src/transport/datagram-peer.js";
import {
  FACTORIO_GATEWAY_PROTOCOL,
  type PairingDescriptor
} from "../src/transport/protocol.js";

const REQUEST_ID = "00000000-0000-4000-8000-000000000003";

function descriptor(overrides: Partial<PairingDescriptor> = {}): PairingDescriptor {
  return {
    protocol: FACTORIO_GATEWAY_PROTOCOL,
    bindingId: "binding:00000000-0000-4000-8000-000000000004",
    saveId: "save:00000000-0000-4000-8000-000000000005",
    playerId: "player:12",
    forceId: "force:3",
    teamId: "team:9",
    capabilities: ["session:read", "events:read"],
    surfaces: [{
      surfaceId: "surface:1",
      forceId: "force:3",
      kind: "primary" as const,
      visibility: "force-chart" as const
    }],
    preferences: {
      enabled: true,
      requestedCapabilities: ["session:read", "events:read"],
      notifications: "important" as const,
      blueprintDelivery: "inbox-only" as const
    },
    issuedTick: 1_000,
    ...overrides
  };
}

test("one-time pairing exchange returns a server-derived scoped descriptor", async () => {
  const peer = new MockDatagramPeer();
  const pending = exchangePairingCode(peer, "ABCDE-FGHJ-KMNP", {
    idFactory: () => REQUEST_ID,
    timeoutMs: 1_000
  });
  const sent = JSON.parse(new TextDecoder().decode(peer.sent[0]));
  assert.deepEqual(sent, {
    protocol: FACTORIO_GATEWAY_PROTOCOL,
    kind: "pairing.exchange",
    id: REQUEST_ID,
    code: "ABCDE-FGHJ-KMNP"
  });
  assert.equal("forceId" in sent, false, "the caller must not choose a force");
  peer.receive({
    protocol: FACTORIO_GATEWAY_PROTOCOL,
    kind: "pairing.response",
    id: REQUEST_ID,
    ok: true,
    tick: 1_001,
    descriptor: descriptor()
  });
  assert.deepEqual(await pending, descriptor());
});

test("consumed or invalid pairing codes surface a typed stable error", async () => {
  const peer = new MockDatagramPeer();
  const pending = exchangePairingCode(peer, "ABCDE-FGHJ-KMNP", {
    idFactory: () => REQUEST_ID,
    timeoutMs: 1_000
  });
  peer.receive({
    protocol: FACTORIO_GATEWAY_PROTOCOL,
    kind: "pairing.response",
    id: REQUEST_ID,
    ok: false,
    tick: 1_002,
    error: {
      code: "PAIRING_CODE_INVALID",
      message: "Pairing code is invalid or already consumed",
      retryable: false
    }
  });
  await assert.rejects(pending, (error: unknown) =>
    error instanceof PairingExchangeError && error.code === "PAIRING_CODE_INVALID"
  );
});

test("pairing descriptors become external wall-clock access grants", () => {
  const grant = descriptorToAccessGrant(descriptor(), {
    nowMs: 10_000,
    principalId: "local:test",
    tokenId: "pairing:test"
  });
  assert.equal(grant.forceId, "force:3");
  assert.equal(grant.principalId, "local:test");
  assert.equal(grant.expiresAtMs, undefined, "a binding without a wire expiry never expires");

  // A descriptor from a mod older than 2.1.x still carries its 24-hour lifetime.
  const legacy = descriptorToAccessGrant(descriptor({ expiresTick: 87_400 }), { nowMs: 10_000 });
  assert.equal(legacy.expiresAtMs, 1_450_000);
});
