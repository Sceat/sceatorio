import assert from "node:assert/strict";
import test from "node:test";

import type { AuthInfo } from "@modelcontextprotocol/server";

import type { AccessGrant } from "../src/auth/authorize.js";
import { InMemoryCredentialStore } from "../src/http/credentials.js";
import { PairGuard } from "../src/http/pair-guard.js";
import { createRouter, grantFromContext } from "../src/http/routes.js";
import { PairingExchangeError } from "../src/pairing.js";
import {
  FACTORIO_GATEWAY_PROTOCOL,
  type PairingDescriptor
} from "../src/transport/protocol.js";

const PUBLIC_URL = "https://mcp.example.test";
const CODE = "ABCDE-FGHJ-KMNP";
const NOW = 1_000_000;

function descriptor(): PairingDescriptor {
  return {
    protocol: FACTORIO_GATEWAY_PROTOCOL,
    bindingId: "binding:00000000-0000-4000-8000-000000000004",
    saveId: "save:1",
    playerId: "player:12",
    forceId: "force:3",
    teamId: "team:9",
    capabilities: ["session:read"],
    surfaces: [
      { surfaceId: "surface:1", forceId: "force:3", kind: "primary", visibility: "force-chart" }
    ],
    preferences: {
      enabled: true,
      requestedCapabilities: ["session:read"],
      notifications: "important",
      blueprintDelivery: "inbox-only"
    },
    issuedTick: 0,
    expiresTick: 60 * 60
  };
}

function harness(exchange?: (code: string) => Promise<PairingDescriptor>) {
  const forwarded: string[] = [];
  const served: AccessGrant[] = [];
  let clock = NOW;
  const router = createRouter({
    publicUrl: PUBLIC_URL,
    credentials: new InMemoryCredentialStore(),
    guard: new PairGuard(),
    exchange: async (code) => {
      forwarded.push(code);
      return await (exchange === undefined ? Promise.resolve(descriptor()) : exchange(code));
    },
    mcp: {
      fetch: async (_request: Request, options?: { authInfo?: AuthInfo }) => {
        const grant = grantFromContext({
          era: "modern",
          ...(options?.authInfo === undefined ? {} : { authInfo: options.authInfo })
        });
        served.push(grant);
        return new Response(JSON.stringify({ playerId: grant.playerId }), { status: 200 });
      }
    },
    now: () => clock
  });

  return {
    forwarded,
    served,
    advance: (ms: number) => { clock += ms; },
    get: async (path: string) =>
      await router(new Request(`${PUBLIC_URL}${path}`), { ip: "10.0.0.1" }),
    raw: async (request: Request) => await router(request, { ip: "10.0.0.1" }),
    pair: async (code: unknown, ip = "10.0.0.1") =>
      await router(
        new Request(`${PUBLIC_URL}/pair`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ code })
        }),
        { ip }
      ),
    call: async (authorization?: string) =>
      await router(
        new Request(`${PUBLIC_URL}/mcp`, {
          method: "POST",
          headers: {
            "content-type": "application/json",
            ...(authorization === undefined ? {} : { authorization })
          },
          body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" })
        }),
        { ip: "10.0.0.1" }
      )
  };
}

test("the pairing page is self-contained and carries the public endpoint", async () => {
  const app = harness();
  const response = await app.get("/");
  const body = await response.text();

  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html/);
  assert.match(body, /https:\/\/mcp\.example\.test\/mcp/);
  assert.equal(/<(script|link|img)[^>]+(src|href)=/i.test(body), false, "no external asset");
  assert.match(response.headers.get("content-security-policy") ?? "", /default-src 'none'/);
});

test("pairing mints a bearer that authorizes MCP calls, and nothing else does", async () => {
  const app = harness();
  const paired = await app.pair(CODE);
  const body = await paired.json() as { token: string; command: string; expiresAtMs: number };

  assert.equal(paired.status, 200);
  assert.deepEqual(app.forwarded, [CODE]);
  assert.match(body.token, /^scto_[0-9a-f]{18}_[0-9a-f]{64}$/);
  assert.equal(
    body.command,
    "claude mcp add --transport http --scope user sceatorio https://mcp.example.test/mcp "
      + `--header "Authorization: Bearer ${body.token}"`
  );
  assert.equal(body.expiresAtMs, NOW + 60_000);

  const authorized = await app.call(`Bearer ${body.token}`);
  assert.equal(authorized.status, 200);
  assert.deepEqual(await authorized.json(), { playerId: "player:12" });
  assert.equal(app.served[0]?.forceId, "force:3");

  for (const header of [undefined, "Bearer nope", `Bearer ${body.token}x`, body.token]) {
    const rejected = await app.call(header);
    assert.equal(rejected.status, 401, `header ${String(header)} must not authorize`);
    assert.equal(rejected.headers.get("www-authenticate"), "Bearer");
  }
  assert.equal(app.served.length, 1, "no unauthorized request ever reached the MCP server");
});

test("an expired binding stops authorizing", async () => {
  const app = harness();
  const body = await (await app.pair(CODE)).json() as { token: string };

  app.advance(59_999);
  assert.equal((await app.call(`Bearer ${body.token}`)).status, 200);
  app.advance(1);
  assert.equal((await app.call(`Bearer ${body.token}`)).status, 401);
});

test("malformed codes and the sixth failure of a minute never reach the game", async () => {
  const app = harness(async () => {
    throw new PairingExchangeError("PAIRING_CODE_INVALID", "Pairing code is invalid");
  });

  for (const malformed of ["", "not-a-code", "ABCDE-FGHI-KMNP", 42, null]) {
    const response = await app.pair(malformed);
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), {
      error: "PAIRING_FAILED",
      message: "That code is invalid or expired. Create a fresh one at the Uplink."
    });
  }
  assert.deepEqual(app.forwarded, [], "an impossible code is never forwarded over UDP");

  // Distinct addresses, so only the global cap can be doing the work here.
  for (let attempt = 0; attempt < 5; attempt += 1) {
    assert.equal((await app.pair(CODE, `10.1.0.${attempt}`)).status, 400);
  }
  assert.equal(app.forwarded.length, 5);

  const shed = await app.pair(CODE, "10.1.0.99");
  assert.equal(shed.status, 429);
  assert.equal(shed.headers.get("retry-after"), "60");
  assert.equal(
    app.forwarded.length,
    5,
    "the mod's own 10-per-minute limiter stays unreachable from the internet"
  );
});

test("unknown routes, wrong media types and foreign origins fail closed", async () => {
  const app = harness();
  assert.equal((await app.get("/admin")).status, 404);
  assert.equal((await app.get("/mcp")).status, 401, "no bearer, no answer, whatever the method");
  assert.equal((await app.get("/healthz")).status, 200);

  const formPost = await app.raw(
    new Request(`${PUBLIC_URL}/pair`, {
      method: "POST",
      headers: { "content-type": "text/plain" },
      body: CODE
    })
  );
  assert.equal(formPost.status, 415);

  const crossOrigin = await app.raw(
    new Request(`${PUBLIC_URL}/pair`, {
      method: "POST",
      headers: { "content-type": "application/json", origin: "https://evil.test" },
      body: JSON.stringify({ code: CODE })
    })
  );
  assert.equal(crossOrigin.status, 403, "a browser on another origin cannot drive pairing");
  assert.deepEqual(app.forwarded, [], "neither attempt touched the game");
});
