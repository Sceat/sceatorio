import assert from "node:assert/strict";
import test from "node:test";

import {
  AuthorizationError,
  authorizeAccess,
  type AccessGrant
} from "../src/auth/authorize.js";
import {
  DEFAULT_SERVER_POLICY,
  resolveCapabilities,
  type ServerPolicy
} from "../src/domain/capabilities.js";

const NOW = 1_000;

function grant(overrides: Partial<AccessGrant> = {}): AccessGrant {
  return {
    bindingId: "binding-0000000000000001",
    principalId: "ai-user-1",
    tokenId: "token-1",
    saveId: "save-1",
    playerId: "player-1",
    forceId: "force-1",
    teamId: "team-1",
    capabilities: new Set(["session:read", "map:read", "blueprints:write"]),
    surfaces: [
      {
        surfaceId: "nauvis",
        forceId: "force-1",
        kind: "primary",
        visibility: "force-chart"
      },
      {
        surfaceId: "vulcanus-team-1",
        forceId: "force-1",
        kind: "team-secondary",
        visibility: "force-chart"
      }
    ],
    preferences: {
      enabled: true,
      requestedCapabilities: ["session:read", "map:read", "blueprints:write"],
      notifications: "important",
      blueprintDelivery: "inbox-only"
    },
    issuedAtMs: 500,
    expiresAtMs: 2_000,
    ...overrides
  };
}

function policy(overrides: Partial<ServerPolicy> = {}): ServerPolicy {
  return {
    ...DEFAULT_SERVER_POLICY,
    enabled: true,
    ...overrides
  };
}

function expectAuthorizationCode(callback: () => void, code: string): void {
  assert.throws(callback, (error: unknown) => {
    assert.ok(error instanceof AuthorizationError);
    assert.equal(error.code, code);
    return true;
  });
}

test("AI assistance is denied by default at the global policy layer", () => {
  expectAuthorizationCode(
    () =>
      authorizeAccess(
        grant(),
        DEFAULT_SERVER_POLICY,
        "session:read",
        { saveId: "save-1", forceId: "force-1" },
        NOW
      ),
    "AI_DISABLED"
  );
});

test("a force unlock does not bypass per-player opt-in", () => {
  const optedOut = grant({
    preferences: {
      enabled: false,
      requestedCapabilities: [],
      notifications: "off",
      blueprintDelivery: "inbox-only"
    }
  });
  expectAuthorizationCode(
    () =>
      authorizeAccess(
        optedOut,
        policy(),
        "session:read",
        { saveId: "save-1", forceId: "force-1" },
        NOW
      ),
    "PLAYER_NOT_OPTED_IN"
  );
});

test("save, force and capability scopes are all enforced", () => {
  const access = grant();
  expectAuthorizationCode(
    () =>
      authorizeAccess(
        access,
        policy(),
        "session:read",
        { saveId: "save-2", forceId: "force-1" },
        NOW
      ),
    "SAVE_SCOPE_MISMATCH"
  );
  expectAuthorizationCode(
    () =>
      authorizeAccess(
        access,
        policy(),
        "session:read",
        { saveId: "save-1", forceId: "force-2" },
        NOW
      ),
    "FORCE_SCOPE_MISMATCH"
  );
  expectAuthorizationCode(
    () =>
      authorizeAccess(
        access,
        policy(),
        "blueprints:validate",
        { saveId: "save-1", forceId: "force-1" },
        NOW
      ),
    "INSUFFICIENT_CAPABILITY"
  );
});

test("a grant without an expiry never expires, but revocation and legacy expiry still bite", () => {
  const target = { saveId: "save-1", forceId: "force-1" };
  const decade = NOW + 10 * 365 * 24 * 60 * 60 * 1_000;
  assert.doesNotThrow(() =>
    authorizeAccess(grant({ expiresAtMs: undefined }), policy(), "session:read", target, decade)
  );
  expectAuthorizationCode(
    () => authorizeAccess(grant(), policy(), "session:read", target, 2_000),
    "TOKEN_EXPIRED"
  );
  expectAuthorizationCode(
    () => authorizeAccess(grant({ revokedAtMs: NOW }), policy(), "session:read", target, NOW),
    "TOKEN_REVOKED"
  );
});

test("team-owned secondary planet surfaces are allowed but foreign surfaces are denied", () => {
  const access = grant();
  assert.doesNotThrow(() =>
    authorizeAccess(
      access,
      policy(),
      "map:read",
      { saveId: "save-1", forceId: "force-1", surfaceId: "vulcanus-team-1" },
      NOW
    )
  );
  expectAuthorizationCode(
    () =>
      authorizeAccess(
        access,
        policy(),
        "map:read",
        { saveId: "save-1", forceId: "force-1", surfaceId: "gleba-team-2" },
        NOW
      ),
    "SURFACE_SCOPE_MISMATCH"
  );
});

test("effective capabilities are the intersection of policy, technology and player choice", () => {
  const capabilities = resolveCapabilities(
    policy({ allowedCapabilities: ["session:read", "blueprints:write"] }),
    {
      aiAssistance: true
    },
    {
      enabled: true,
      requestedCapabilities: ["session:read", "blueprints:write"],
      notifications: "important",
      blueprintDelivery: "inbox-only"
    }
  );
  assert.deepEqual([...capabilities].sort(), ["blueprints:write", "session:read"]);
});
