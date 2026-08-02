import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import net from "node:net";
import readline from "node:readline";

import {
  PairingExchangeError,
  descriptorToAccessGrant,
  exchangePairingCode
} from "../../mcp/dist/src/pairing.js";
import {CorrelatedFactorioTransport} from "../../mcp/dist/src/transport/correlated-transport.js";
import {UdpDatagramPeer} from "../../mcp/dist/src/transport/udp-peer.js";

const rconPort = Number(process.env.SCEATORIO_E2E_RCON_PORT);
const factorioPort = Number(process.env.SCEATORIO_E2E_LUA_UDP_PORT);
const rconPassword = process.env.SCEATORIO_E2E_RCON_PASSWORD;
if (!Number.isInteger(rconPort) || !Number.isInteger(factorioPort) || !rconPassword) {
  throw new Error("E2E RCON/UDP environment is incomplete");
}

class Rcon {
  constructor(port, password) {
    this.port = port;
    this.password = password;
    this.socket = new net.Socket();
    this.buffer = Buffer.alloc(0);
    this.packets = [];
    this.waiters = [];
    this.nextId = 10;
  }

  async connect() {
    await new Promise((resolve, reject) => {
      this.socket.once("error", reject);
      this.socket.connect(this.port, "127.0.0.1", () => {
        this.socket.off("error", reject);
        resolve();
      });
    });
    this.socket.on("data", (chunk) => this.onData(chunk));
    this.sendPacket(1, 3, this.password);
    const answer = await this.waitForPacket((packet) => packet.id === 1 || packet.id === -1);
    if (answer.id === -1) throw new Error("RCON authentication failed");
  }

  async command(command) {
    const id = this.nextId++;
    this.sendPacket(id, 2, command);
    const answer = await this.waitForPacket((packet) => packet.id === id);
    return answer.body;
  }

  close() {
    this.socket.destroy();
  }

  sendPacket(id, type, body) {
    const payload = Buffer.from(body, "utf8");
    const packet = Buffer.alloc(14 + payload.length);
    packet.writeInt32LE(10 + payload.length, 0);
    packet.writeInt32LE(id, 4);
    packet.writeInt32LE(type, 8);
    payload.copy(packet, 12);
    packet.writeInt16LE(0, 12 + payload.length);
    this.socket.write(packet);
  }

  onData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 4) {
      const length = this.buffer.readInt32LE(0);
      const total = length + 4;
      if (length < 10 || this.buffer.length < total) return;
      const packet = {
        id: this.buffer.readInt32LE(4),
        type: this.buffer.readInt32LE(8),
        body: this.buffer.subarray(12, total - 2).toString("utf8")
      };
      this.buffer = this.buffer.subarray(total);
      const waiter = this.waiters.find((candidate) => candidate.predicate(packet));
      if (waiter) {
        clearTimeout(waiter.timeout);
        this.waiters = this.waiters.filter((candidate) => candidate !== waiter);
        waiter.resolve(packet);
      } else {
        this.packets.push(packet);
      }
    }
  }

  waitForPacket(predicate) {
    const existing = this.packets.find(predicate);
    if (existing) {
      this.packets = this.packets.filter((packet) => packet !== existing);
      return Promise.resolve(existing);
    }
    return new Promise((resolve, reject) => {
      const waiter = {predicate, resolve, reject, timeout: undefined};
      waiter.timeout = setTimeout(() => {
        this.waiters = this.waiters.filter((candidate) => candidate !== waiter);
        reject(new Error("RCON response timed out"));
      }, 5_000);
      this.waiters.push(waiter);
    });
  }
}

async function pairingCode(rcon) {
  const output = await rcon.command("/sceatorio-ai-dev-code");
  const match = /SCEATORIO_AI_PAIRING_CODE=([A-HJ-NP-Z2-9-]+)/.exec(output);
  assert.ok(match, `development pairing command failed: ${output}`);
  return match[1];
}

async function setGlobalAiEnabled(rcon, enabled) {
  const output = await rcon.command(`/sceatorio-ai-dev-policy ${enabled ? "on" : "off"}`);
  assert.match(output, new RegExp(`SCEATORIO_AI_POLICY_ENABLED=${enabled}`));
}

function scope(descriptor, surfaceId) {
  return {
    bindingId: descriptor.bindingId,
    saveId: descriptor.saveId,
    playerId: descriptor.playerId,
    forceId: descriptor.forceId,
    ...(surfaceId === undefined ? {} : {surfaceId})
  };
}

async function expectFactorioError(transport, operation, requestScope, payload, expectedCode) {
  const response = await transport.request({operation, scope: requestScope, payload});
  assert.equal(response.ok, false, `${operation} unexpectedly succeeded`);
  assert.equal(response.error?.code, expectedCode);
}

async function call(transport, descriptor, operation, payload, surfaceId) {
  const response = await transport.request({
    operation,
    scope: scope(descriptor, surfaceId),
    payload
  }, {timeoutMs: operation === "event.wait" ? 5_000 : 2_000});
  assert.equal(response.ok, true, `${operation}: ${JSON.stringify(response.error)}`);
  JSON.stringify(response.result);
  return response.result;
}

async function checkStdioMcp(grant) {
  const child = spawn(process.execPath, ["mcp/dist/src/index.js"], {
    cwd: process.cwd(),
    env: {
      ...process.env,
      SCEATORIO_FACTORIO_PORT: String(factorioPort),
      SCEATORIO_ACCESS_GRANT_JSON: JSON.stringify(grant),
      SCEATORIO_SERVER_POLICY_JSON: JSON.stringify({enabled: true})
    },
    stdio: ["pipe", "pipe", "pipe"]
  });
  const lines = readline.createInterface({input: child.stdout});
  const pending = new Map();
  lines.on("line", (line) => {
    const message = JSON.parse(line);
    const request = pending.get(message.id);
    if (request) {
      pending.delete(message.id);
      request.resolve(message);
    }
  });
  let nextId = 1;
  const rpc = (method, params) => new Promise((resolve, reject) => {
    const id = nextId++;
    const timeout = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`MCP ${method} timed out`));
    }, 5_000);
    pending.set(id, {resolve: (message) => {
      clearTimeout(timeout);
      resolve(message);
    }});
    child.stdin.write(`${JSON.stringify({jsonrpc: "2.0", id, method, params})}\n`);
  });
  try {
    const initialized = await rpc("initialize", {
      protocolVersion: "2025-11-25",
      capabilities: {},
      clientInfo: {name: "sceatorio-headless-e2e", version: "1.0.0"}
    });
    assert.ok(initialized.result, JSON.stringify(initialized));
    child.stdin.write(`${JSON.stringify({
      jsonrpc: "2.0",
      method: "notifications/initialized",
      params: {}
    })}\n`);
    const listed = await rpc("tools/list", {});
    assert.equal(listed.result?.tools?.length, 29, JSON.stringify(listed));
    const session = await rpc("tools/call", {name: "get_session", arguments: {}});
    assert.notEqual(session.result?.isError, true, JSON.stringify(session));
  } finally {
    lines.close();
    child.stdin.end();
    child.kill("SIGTERM");
    await new Promise((resolve) => child.once("exit", resolve));
  }
}

const rcon = new Rcon(rconPort, rconPassword);
const peer = new UdpDatagramPeer({factorioPort});
let transport;
let replayTransport;
try {
  await rcon.connect();
  const code = await pairingCode(rcon);
  const pairingRequestId = "00000000-0000-4000-8000-000000000099";
  let pairingResponseCount = 0;
  const stopCounting = peer.onMessage((payload) => {
    try {
      const message = JSON.parse(new TextDecoder().decode(payload));
      if (message.id === pairingRequestId && message.kind === "pairing.response") {
        pairingResponseCount += 1;
      }
    } catch {
      // Unrelated malformed datagrams are ignored by the real transport too.
    }
  });
  let descriptor = await exchangePairingCode(peer, code, {
    idFactory: () => pairingRequestId
  });
  const retriedDescriptor = await exchangePairingCode(peer, code, {
    idFactory: () => pairingRequestId
  });
  assert.deepEqual(
    retriedDescriptor,
    descriptor,
    "an identical pairing retry must replay the exact completed response"
  );
  await new Promise((resolve) => setTimeout(resolve, 150));
  stopCounting();
  assert.equal(pairingResponseCount, 2, "each identical exchange must receive exactly one response datagram");
  assert.equal(descriptor.capabilities.length, 16);
  assert.equal(descriptor.forceId, "force:1");

  transport = new CorrelatedFactorioTransport(peer, {defaultTimeoutMs: 2_000});
  const firstSession = await call(transport, descriptor, "session.get", {});
  assert.equal(firstSession.budgets.globalRequestsPerMinute, 600);
  assert.equal(firstSession.budgets.globalExpensiveRequestsPerMinute, 120);
  assert.equal(firstSession.budgets.globalRequestsRemaining, 599);
  assert.equal(firstSession.budgets.globalExpensiveRequestsRemaining, 120);

  await assert.rejects(
    exchangePairingCode(peer, code),
    (error) => error instanceof PairingExchangeError && error.code === "PAIRING_CODE_INVALID"
  );
  const expired = await pairingCode(rcon);
  const expireOutput = await rcon.command(`/sceatorio-ai-dev-expire-code ${expired}`);
  assert.match(expireOutput, /SCEATORIO_AI_PAIRING_EXPIRED=/);
  await assert.rejects(
    exchangePairingCode(peer, expired),
    (error) => error instanceof PairingExchangeError && error.code === "PAIRING_CODE_EXPIRED"
  );

  const repairedCode = await pairingCode(rcon);
  await assert.rejects(
    exchangePairingCode(peer, repairedCode, {idFactory: () => pairingRequestId}),
    (error) => error instanceof PairingExchangeError && error.code === "DUPLICATE_REQUEST_ID"
  );
  const repairedDescriptor = await exchangePairingCode(peer, repairedCode);
  await expectFactorioError(
    transport,
    "session.get",
    scope(descriptor),
    {},
    "TOKEN_REVOKED"
  );
  const repairedSession = await call(transport, repairedDescriptor, "session.get", {});
  assert.equal(
    repairedSession.budgets.requestsRemaining,
    firstSession.budgets.requestsRemaining - 1,
    "re-pairing must retain the logical player's current quota window"
  );
  assert.equal(
    repairedSession.budgets.globalRequestsRemaining,
    firstSession.budgets.globalRequestsRemaining - 1,
    "re-pairing must retain the save-wide quota window"
  );
  descriptor = repairedDescriptor;
  const replayRequestId = "00000000-0000-4000-8000-000000000100";
  replayTransport = new CorrelatedFactorioTransport(peer, {
    defaultTimeoutMs: 2_000,
    idFactory: () => replayRequestId
  });
  const replayCall = {
    operation: "session.get",
    scope: scope(descriptor),
    payload: {}
  };
  const firstReplayResponse = await replayTransport.request(replayCall);
  assert.equal(firstReplayResponse.ok, true, JSON.stringify(firstReplayResponse.error));
  const repeatedReplayResponse = await replayTransport.request(replayCall);
  assert.deepEqual(
    repeatedReplayResponse,
    firstReplayResponse,
    "an identical completed operation retry must replay the exact response without spending quota"
  );
  await expectFactorioError(
    replayTransport,
    "session.get",
    scope(descriptor),
    {differentRequest: true},
    "DUPLICATE_REQUEST_ID"
  );
  const grant = descriptorToAccessGrant(descriptor, {
    principalId: "headless-e2e",
    tokenId: "headless-e2e"
  });
  const session = await call(transport, descriptor, "session.get", {});
  const surfaceId = session.surfaces[0].surfaceId;
  const query = await call(transport, descriptor, "entity.query", {
    surfaceId,
    area: {leftTop: {x: 0, y: 0}, rightBottom: {x: 320, y: 320}},
    names: [
      "electric-energy-interface",
      "substation",
      "sceatorio-ai-uplink",
      "sceatorio-ai-input-port",
      "sceatorio-ai-output-port",
      "roboport"
    ],
    pagination: {limit: 100}
  }, surfaceId);
  const byName = Object.fromEntries(query.entities.map((entity) => [entity.name, entity]));
  for (const name of ["substation", "sceatorio-ai-uplink", "sceatorio-ai-input-port", "sceatorio-ai-output-port", "roboport"]) {
    assert.ok(byName[name]?.entityId, `missing fixture ${name}`);
  }

  await call(transport, descriptor, "statistics.production", {
    surfaceId, statistic: "item", direction: "both", window: "total", pagination: {limit: 20}
  }, surfaceId);
  await call(transport, descriptor, "electric.network", {
    surfaceId, anchorEntityId: byName.substation.entityId, pagination: {limit: 20}
  }, surfaceId);
  await call(transport, descriptor, "research.get", {includeCompleted: true, pagination: {limit: 20}});
  await call(transport, descriptor, "prototype.recipe", {name: "iron-gear-wheel"});
  await call(transport, descriptor, "prototype.get", {type: "entity", name: "transport-belt"});
  await call(transport, descriptor, "prototype.transport-capacities", {
    includeLocked: true, pagination: {limit: 20}
  });
  await call(transport, descriptor, "research.unlocked-technologies", {pagination: {limit: 20}});
  await call(transport, descriptor, "entity.inspect", {
    surfaceId, entityId: byName["sceatorio-ai-uplink"].entityId
  }, surfaceId);
  await call(transport, descriptor, "logistics.network", {
    surfaceId,
    anchorPosition: byName.roboport.position,
    includeContents: true,
    pagination: {limit: 20}
  }, surfaceId);
  await call(transport, descriptor, "train.list", {surfaceId, pagination: {limit: 20}}, surfaceId);
  await call(transport, descriptor, "alert.list", {surfaceId, pagination: {limit: 20}}, surfaceId);
  await call(transport, descriptor, "map.charted-chunks", {
    surfaceId,
    area: {leftTop: {x: 64, y: 64}, rightBottom: {x: 192, y: 192}},
    includeKnownResources: true,
    includeVisibleEnemies: false,
    pagination: {limit: 20}
  }, surfaceId);
  await call(transport, descriptor, "circuit.port.read", {
    surfaceId, portId: byName["sceatorio-ai-input-port"].entityId
  }, surfaceId);
  const events = await call(transport, descriptor, "event.list", {limit: 20});
  const beforeWait = await call(transport, descriptor, "session.get", {});
  await call(transport, descriptor, "event.wait", {
    cursor: events.latestCursor,
    timeoutMs: 100,
    limit: 20
  });
  const afterWait = await call(transport, descriptor, "session.get", {});
  assert.equal(
    afterWait.budgets.expensiveRequestsRemaining,
    beforeWait.budgets.expensiveRequestsRemaining - 1,
    "event.wait must consume the per-player expensive quota"
  );
  assert.equal(
    afterWait.budgets.globalExpensiveRequestsRemaining,
    beforeWait.budgets.globalExpensiveRequestsRemaining - 1,
    "event.wait must consume the save-wide expensive quota"
  );

  const layout = {
    name: "E2E belt",
    description: "Headless safe subset fixture",
    entities: [{entityNumber: 1, prototype: "transport-belt", position: {x: 0, y: 0}}],
    tiles: [],
    expectedOutputs: []
  };
  await call(transport, descriptor, "blueprint.validate", {layout});
  await call(transport, descriptor, "blueprint.analyze", {layout});
  const saved = await call(transport, descriptor, "blueprint.save", {layout, delivery: "inbox"});
  await call(transport, descriptor, "blueprint.library.list", {pagination: {limit: 20}});
  await call(transport, descriptor, "blueprint.library.load", {
    blueprintId: saved.blueprintId,
    revision: saved.revision,
    delivery: "inbox"
  });
  await call(transport, descriptor, "circuit.port.write", {
    surfaceId,
    portId: byName["sceatorio-ai-output-port"].entityId,
    signals: [{type: "item", name: "iron-plate", value: 42}],
    ttlSeconds: 5
  }, surfaceId);
  await expectFactorioError(transport, "map.annotation.add", scope(descriptor, surfaceId), {
    surfaceId,
    position: {x: 128, y: 128},
    text: "private headless annotation",
    ttlSeconds: 10
  }, "PLAYER_REQUIRED");

  await expectFactorioError(
    transport,
    "session.get",
    {...scope(descriptor), forceId: "force:999"},
    {},
    "FORCE_SCOPE_MISMATCH"
  );
  await expectFactorioError(
    transport,
    "entity.query",
    {...scope(descriptor), surfaceId: "surface:999"},
    {
      surfaceId: "surface:999",
      area: {leftTop: {x: 0, y: 0}, rightBottom: {x: 32, y: 32}}
    },
    "SURFACE_SCOPE_MISMATCH"
  );

  await checkStdioMcp(grant);

  await setGlobalAiEnabled(rcon, false);
  let staleRequestSettled = false;
  let earlyStaleResponse;
  const staleRequest = replayTransport.request(replayCall).then((response) => {
    staleRequestSettled = true;
    earlyStaleResponse = response;
    return response;
  });
  await new Promise((resolve) => setTimeout(resolve, 150));
  assert.equal(
    staleRequestSettled,
    false,
    `disabled server policy must not drain buffered AI UDP requests; response=${JSON.stringify(earlyStaleResponse)}`
  );
  await setGlobalAiEnabled(rcon, true);
  const staleResponse = await staleRequest;
  assert.equal(staleResponse.ok, false, "a buffered request must fail after policy re-enable");
  assert.equal(
    staleResponse.error?.code,
    "TOKEN_REVOKED",
    "policy disable must revoke bindings before a buffered request can reach the completed-response cache"
  );

  const finalCode = await pairingCode(rcon);
  const finalDescriptor = await exchangePairingCode(peer, finalCode);
  const revoke = await rcon.command(`/sceatorio-ai-dev-revoke ${finalDescriptor.bindingId}`);
  assert.match(revoke, /SCEATORIO_AI_REVOKED=/);
  await expectFactorioError(
    transport,
    "session.get",
    scope(finalDescriptor),
    {},
    "TOKEN_REVOKED"
  );
  console.log("SCEATORIO_AI_E2E_PASS: pairing, 29-tool gateway, stdio MCP, scope, replay, policy disable, expiry, and revoke verified");
} finally {
  if (replayTransport) await replayTransport.close();
  else if (transport) await transport.close();
  else await peer.close();
  rcon.close();
}
