import { randomBytes, randomUUID } from "node:crypto";

import type { AuthInfo, McpRequestContext } from "@modelcontextprotocol/server";

import { materializeAccessGrant, type AccessGrant } from "../auth/authorize.js";
import { descriptorToAccessGrant } from "../pairing.js";
import type { McpLogger } from "../server.js";
import type { PairingDescriptor } from "../transport/protocol.js";
import { CredentialStore, parseBearer } from "./credentials.js";
import type { HttpClient, WebHandler } from "./node-bridge.js";
import { isPairingCode, PairGuard } from "./pair-guard.js";
import { renderPairingPage } from "./pairing-page.js";

/**
 * The whole public surface: a pairing page, a pairing exchange, and the MCP
 * endpoint. Everything fails closed — unknown route 404, bad bearer 401,
 * malformed body 400, and no internal detail ever reaches a response body.
 */

const MAX_PAIR_BODY_BYTES = 1024;
const AUTH_INFO_GRANT = "sceatorioGrant";

export interface McpFetchHandler {
  fetch(request: Request, options?: { authInfo?: AuthInfo }): Promise<Response>;
}

export interface HttpLogger extends McpLogger {
  info?(message: string, metadata?: Readonly<Record<string, unknown>>): void;
}

export interface RouterDependencies {
  /** Absolute base URL players reach this service on, e.g. `https://mcp.example.org`. */
  publicUrl: string;
  credentials: CredentialStore;
  guard: PairGuard;
  /** Performs the loopback UDP `pairing.exchange`; injected so tests need no socket. */
  exchange(code: string): Promise<PairingDescriptor>;
  mcp: McpFetchHandler;
  logger?: HttpLogger | undefined;
  now?: (() => number) | undefined;
  maxInFlight?: number | undefined;
  maxInFlightPerGrant?: number | undefined;
}

/** Reads back the grant the router attached to a verified request. */
export function grantFromContext(context: McpRequestContext): AccessGrant {
  const grant = context.authInfo?.extra?.[AUTH_INFO_GRANT];
  if (grant === undefined) {
    throw new Error("MCP request reached the server without a verified grant");
  }
  return grant as AccessGrant;
}

export function createRouter(dependencies: RouterDependencies): WebHandler {
  const publicUrl = dependencies.publicUrl.replace(/\/+$/u, "");
  const publicHost = new URL(publicUrl).host;
  const now = dependencies.now ?? Date.now;
  const maxInFlight = dependencies.maxInFlight ?? 32;
  const maxInFlightPerGrant = dependencies.maxInFlightPerGrant ?? 4;
  const inFlightByToken = new Map<string, number>();
  let inFlight = 0;

  return async function route(request: Request, client: HttpClient): Promise<Response> {
    const url = new URL(request.url);
    try {
      if (!hostAllowed(url.host, publicHost) || !originAllowed(request, publicUrl)) {
        return json(403, { error: "FORBIDDEN" });
      }
      if (url.pathname === "/healthz") {
        return json(200, { status: "ok" });
      }
      if (url.pathname === "/" || url.pathname === "/index.html") {
        return request.method === "GET" || request.method === "HEAD"
          ? pairingPage(publicUrl)
          : json(405, { error: "METHOD_NOT_ALLOWED" });
      }
      if (url.pathname === "/pair") {
        return request.method === "POST"
          ? await pair(request, client, publicUrl, now(), dependencies)
          : json(405, { error: "METHOD_NOT_ALLOWED" });
      }
      if (url.pathname === "/mcp") {
        const grant = dependencies.credentials.verify(
          parseBearer(request.headers.get("authorization")),
          now()
        );
        if (grant === undefined) {
          return json(401, { error: "UNAUTHORIZED" }, { "www-authenticate": "Bearer" });
        }
        const perGrant = inFlightByToken.get(grant.tokenId) ?? 0;
        if (inFlight >= maxInFlight || perGrant >= maxInFlightPerGrant) {
          return json(503, { error: "BUSY" }, { "retry-after": "1" });
        }
        inFlight += 1;
        inFlightByToken.set(grant.tokenId, perGrant + 1);
        try {
          return await dependencies.mcp.fetch(request, { authInfo: toAuthInfo(grant) });
        } finally {
          inFlight -= 1;
          const remaining = (inFlightByToken.get(grant.tokenId) ?? 1) - 1;
          if (remaining <= 0) {
            inFlightByToken.delete(grant.tokenId);
          } else {
            inFlightByToken.set(grant.tokenId, remaining);
          }
        }
      }
      return json(404, { error: "NOT_FOUND" });
    } catch (error) {
      dependencies.logger?.error("Unhandled HTTP failure", {
        path: url.pathname,
        error: error instanceof Error ? error.message : String(error)
      });
      return json(500, { error: "INTERNAL_ERROR" });
    }
  };
}

async function pair(
  request: Request,
  client: HttpClient,
  publicUrl: string,
  nowMs: number,
  dependencies: RouterDependencies
): Promise<Response> {
  if (!isJsonRequest(request)) {
    return json(415, { error: "UNSUPPORTED_MEDIA_TYPE" });
  }
  const verdict = dependencies.guard.admit(client.ip, nowMs);
  if (verdict !== "allow") {
    return json(
      429,
      {
        error: "PAIRING_RATE_LIMITED",
        message: "Too many pairing attempts right now; wait a minute and try again."
      },
      { "retry-after": "60" }
    );
  }

  const body = await readJson(request);
  const code = typeof body === "object" && body !== null && "code" in body
    ? (body as { code?: unknown }).code
    : undefined;
  // A code that cannot be valid is never forwarded: the game's UDP socket only
  // ever sees well-formed candidates.
  if (!isPairingCode(code)) {
    return json(400, {
      error: "PAIRING_FAILED",
      message: "That code is invalid or expired. Create a fresh one at the Uplink."
    });
  }

  let descriptor: PairingDescriptor;
  try {
    descriptor = await dependencies.exchange(code);
  } catch (error) {
    dependencies.guard.recordFailure(nowMs);
    const unavailable = error instanceof Error
      && /^(PAIRING_TIMEOUT|PAIRING_RATE_LIMITED)$/u.test(codeOf(error));
    dependencies.logger?.error("Pairing exchange rejected", { code: codeOf(error) });
    return unavailable
      ? json(503, {
          error: "PAIRING_UNAVAILABLE",
          message: "The game server did not answer. Try again in a moment."
        })
      : json(400, {
          error: "PAIRING_FAILED",
          message: "That code is invalid or expired. Create a fresh one at the Uplink."
        });
  }

  dependencies.guard.recordSuccess(client.ip);
  const grant = descriptorToAccessGrant(descriptor, {
    nowMs,
    principalId: `remote-mcp:${randomUUID()}`
  });
  const credential = dependencies.credentials.mint(materializeAccessGrant(grant), nowMs);
  // Codes and bearers are never logged; the token id and player id are enough to trace a pairing.
  dependencies.logger?.info?.("Pairing minted", {
    tokenId: credential.tokenId,
    playerId: grant.playerId
  });
  return json(200, {
    token: credential.token,
    command: `claude mcp add --transport http --scope user sceatorio ${publicUrl}/mcp `
      + `--header "Authorization: Bearer ${credential.token}"`,
    // Omitted when the pairing never expires, which the page reads as "permanent".
    ...(credential.expiresAtMs === undefined ? {} : { expiresAtMs: credential.expiresAtMs })
  });
}

/** The bearer itself never travels onward; the server only needs the grant. */
function toAuthInfo(grant: AccessGrant): AuthInfo {
  return {
    token: grant.tokenId,
    clientId: grant.principalId,
    scopes: [...grant.capabilities],
    ...(grant.expiresAtMs === undefined
      ? {}
      : { expiresAt: Math.floor(grant.expiresAtMs / 1000) }),
    extra: { [AUTH_INFO_GRANT]: grant }
  };
}

function pairingPage(publicUrl: string): Response {
  const nonce = randomBytes(16).toString("base64url");
  return new Response(renderPairingPage({ publicUrl, nonce }), {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-security-policy": "default-src 'none'; base-uri 'none'; form-action 'none'; "
        + `frame-ancestors 'none'; connect-src 'self'; style-src 'nonce-${nonce}'; `
        + `script-src 'nonce-${nonce}'`,
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
      "x-frame-options": "DENY"
    }
  });
}

async function readJson(request: Request): Promise<unknown> {
  const text = await request.text();
  if (text.length === 0 || text.length > MAX_PAIR_BODY_BYTES) {
    return undefined;
  }
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

function isJsonRequest(request: Request): boolean {
  const contentType = request.headers.get("content-type") ?? "";
  return contentType.split(";", 1)[0]!.trim().toLowerCase() === "application/json";
}

/**
 * DNS-rebinding guard: only the public hostname or a literal address (the
 * loopback/vSwitch bind used by health checks) may address this service.
 */
function hostAllowed(host: string, publicHost: string): boolean {
  if (host === publicHost) {
    return true;
  }
  const hostname = host.replace(/:\d+$/u, "");
  return hostname === "localhost"
    || /^\[?[0-9a-fA-F:.]+\]?$/u.test(hostname) && /[.:]/u.test(hostname);
}

function originAllowed(request: Request, publicUrl: string): boolean {
  const origin = request.headers.get("origin");
  if (origin === null) {
    return true;
  }
  try {
    return new URL(origin).origin === new URL(publicUrl).origin;
  } catch {
    return false;
  }
}

function codeOf(error: unknown): string {
  return typeof error === "object" && error !== null && "code" in error
    && typeof (error as { code?: unknown }).code === "string"
    ? (error as { code: string }).code
    : "UNKNOWN";
}

function json(
  status: number,
  body: Record<string, unknown>,
  headers: Record<string, string> = {}
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      ...headers
    }
  });
}
