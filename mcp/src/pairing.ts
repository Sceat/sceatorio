import { randomUUID } from "node:crypto";

import type { AccessGrantData } from "./auth/authorize.js";
import type { DatagramPeer } from "./transport/datagram-peer.js";
import {
  FACTORIO_GATEWAY_PROTOCOL,
  MAX_GATEWAY_DATAGRAM_BYTES,
  PairingExchangeResponseSchema,
  type PairingDescriptor,
  type PairingExchangeRequest
} from "./transport/protocol.js";

export class PairingExchangeError extends Error {
  constructor(
    readonly code: string,
    message: string
  ) {
    super(message);
    this.name = "PairingExchangeError";
  }
}

export interface PairingExchangeOptions {
  timeoutMs?: number | undefined;
  idFactory?: (() => string) | undefined;
}

export async function exchangePairingCode(
  peer: DatagramPeer,
  code: string,
  options: PairingExchangeOptions = {}
): Promise<PairingDescriptor> {
  const id = (options.idFactory ?? randomUUID)();
  const request: PairingExchangeRequest = {
    protocol: FACTORIO_GATEWAY_PROTOCOL,
    kind: "pairing.exchange",
    id,
    code
  };
  const datagram = new TextEncoder().encode(JSON.stringify(request));
  if (datagram.byteLength > MAX_GATEWAY_DATAGRAM_BYTES) {
    throw new PairingExchangeError("PAIRING_REQUEST_TOO_LARGE", "Pairing request is too large");
  }
  const timeoutMs = options.timeoutMs ?? 5_000;
  if (!Number.isInteger(timeoutMs) || timeoutMs < 100 || timeoutMs > 60_000) {
    throw new RangeError("timeoutMs must be an integer from 100 through 60000");
  }

  return await new Promise<PairingDescriptor>((resolve, reject) => {
    let settled = false;
    const finish = (callback: () => void): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      unsubscribe();
      callback();
    };
    const unsubscribe = peer.onMessage((payload) => {
      if (payload.byteLength > MAX_GATEWAY_DATAGRAM_BYTES) return;
      let decoded: unknown;
      try {
        decoded = JSON.parse(new TextDecoder().decode(payload));
      } catch {
        return;
      }
      if (typeof decoded !== "object" || decoded === null
        || !("id" in decoded) || decoded.id !== id) return;
      const parsed = PairingExchangeResponseSchema.safeParse(decoded);
      if (!parsed.success) {
        const issues = parsed.error.issues
          .map((issue) => `${issue.path.join(".") || "response"}: ${issue.message}`)
          .join("; ");
        finish(() => reject(new PairingExchangeError(
          "MALFORMED_PAIRING_RESPONSE",
          `Factorio returned a malformed pairing response (${issues}); payload=${JSON.stringify(decoded).slice(0, 2_000)}`
        )));
        return;
      }
      if (!parsed.data.ok || parsed.data.descriptor === undefined) {
        const error = parsed.data.error;
        finish(() => reject(new PairingExchangeError(error?.code ?? "PAIRING_FAILED", error?.message ?? "Pairing failed")));
        return;
      }
      finish(() => resolve(parsed.data.descriptor!));
    });
    const timeout = setTimeout(() => {
      finish(() => reject(new PairingExchangeError("PAIRING_TIMEOUT", `Factorio did not answer within ${timeoutMs} ms`)));
    }, timeoutMs);
    void peer.send(datagram).catch((error: unknown) => {
      finish(() => reject(error instanceof Error ? error : new Error(String(error))));
    });
  });
}

export function descriptorToAccessGrant(
  descriptor: PairingDescriptor,
  options: {nowMs?: number; principalId?: string; tokenId?: string} = {}
): AccessGrantData {
  const nowMs = options.nowMs ?? Date.now();
  // No `expiresTick` on the wire means the binding never expires, so the grant
  // carries no `expiresAtMs` either. Older mods that still send one keep it.
  const expiresAtMs = descriptor.expiresTick === undefined
    ? undefined
    : Math.ceil(nowMs + Math.max(1, descriptor.expiresTick - descriptor.issuedTick) * (1_000 / 60));
  return {
    bindingId: descriptor.bindingId,
    principalId: options.principalId ?? `local-mcp:${randomUUID()}`,
    tokenId: options.tokenId ?? `pairing:${randomUUID()}`,
    saveId: descriptor.saveId,
    playerId: descriptor.playerId,
    forceId: descriptor.forceId,
    teamId: descriptor.teamId,
    capabilities: descriptor.capabilities,
    surfaces: descriptor.surfaces,
    preferences: descriptor.preferences,
    issuedAtMs: nowMs,
    ...(expiresAtMs === undefined ? {} : {expiresAtMs})
  };
}
