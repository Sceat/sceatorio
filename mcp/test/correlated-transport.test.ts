import assert from "node:assert/strict";
import test from "node:test";

import { MockDatagramPeer } from "../src/transport/datagram-peer.js";
import { CorrelatedFactorioTransport } from "../src/transport/correlated-transport.js";
import {
  FactorioProtocolError,
  FactorioTimeoutError
} from "../src/transport/factorio-transport.js";
import { FACTORIO_GATEWAY_PROTOCOL } from "../src/transport/protocol.js";

const IDS = [
  "00000000-0000-4000-8000-000000000001",
  "00000000-0000-4000-8000-000000000002"
];

function scope() {
  return {
    bindingId: "binding-0000000000000001",
    saveId: "save-1",
    playerId: "player-1",
    forceId: "force-1"
  };
}

function response(id: string, result: unknown) {
  return {
    protocol: FACTORIO_GATEWAY_PROTOCOL,
    kind: "response" as const,
    id,
    ok: true,
    tick: 42,
    worldRevision: 9,
    result
  };
}

test("responses are correlated by request ID even when they arrive out of order", async () => {
  const peer = new MockDatagramPeer();
  let index = 0;
  const transport = new CorrelatedFactorioTransport(peer, {
    idFactory: () => IDS[index++] ?? IDS[0]!,
    defaultTimeoutMs: 1_000
  });

  const first = transport.request({ operation: "session.get", scope: scope(), payload: {} });
  const second = transport.request({ operation: "research.get", scope: scope(), payload: {} });
  assert.equal(peer.sent.length, 2);

  peer.receive(response(IDS[1]!, { order: 2 }));
  peer.receive(response(IDS[0]!, { order: 1 }));

  assert.deepEqual((await first).result, { order: 1 });
  assert.deepEqual((await second).result, { order: 2 });
  await transport.close();
});

test("a missing Factorio response produces a typed timeout", async () => {
  const peer = new MockDatagramPeer();
  const transport = new CorrelatedFactorioTransport(peer, {
    idFactory: () => IDS[0]!,
    defaultTimeoutMs: 15
  });

  await assert.rejects(
    transport.request({ operation: "session.get", scope: scope(), payload: {} }),
    FactorioTimeoutError
  );
  await transport.close();
});

test("a malformed response for a pending request is rejected", async () => {
  const peer = new MockDatagramPeer();
  const transport = new CorrelatedFactorioTransport(peer, {
    idFactory: () => IDS[0]!,
    defaultTimeoutMs: 1_000
  });
  const pending = transport.request({ operation: "session.get", scope: scope(), payload: {} });

  peer.receive({ id: IDS[0], kind: "response", ok: true });
  await assert.rejects(pending, FactorioProtocolError);
  await transport.close();
});
