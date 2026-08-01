import crypto from "node:crypto";

import type { AccessGrant } from "../auth/authorize.js";

/**
 * First-party bearer credentials, in memory only.
 *
 * A restart means "pair again" at the Uplink: there is no disk, no PVC and no
 * long-lived secret anywhere. Only sha256(secret) is kept, and the comparison
 * is timing-safe, so the map is worthless to anyone who reads process memory
 * after the fact.
 */

const TOKEN_ID_BYTES = 9;
const SECRET_BYTES = 32;
const TOKEN_PATTERN = /^scto_([0-9a-f]{18})_([0-9a-f]{64})$/u;
const BEARER_PATTERN = /^bearer +(\S+)$/iu;

/** Compared against when no credential matches, so unknown ids cost the same as wrong secrets. */
const ABSENT_HASH = sha256("sceatorio:absent");

export interface MintedCredential {
  /** Shown to the player exactly once; never stored in this form. */
  token: string;
  tokenId: string;
  expiresAtMs: number;
}

interface StoredCredential {
  secretHash: Buffer;
  grant: AccessGrant;
}

export function sha256(value: string): Buffer {
  return crypto.createHash("sha256").update(value, "utf8").digest();
}

/** Constant-time over equal-length digests; length is public information. */
export function secretsMatch(candidate: Buffer, expected: Buffer): boolean {
  return candidate.length === expected.length && crypto.timingSafeEqual(candidate, expected);
}

export function parseBearer(header: string | null | undefined): string | undefined {
  if (typeof header !== "string") {
    return undefined;
  }
  const match = BEARER_PATTERN.exec(header.trim());
  return match === null ? undefined : match[1];
}

export class InMemoryCredentialStore {
  private readonly credentials = new Map<string, StoredCredential>();

  get size(): number {
    return this.credentials.size;
  }

  /**
   * Mints `scto_<tokenId>_<secret>` for a freshly paired grant. Re-pairing
   * replaces the player's previous credential, mirroring the mod's own
   * one-binding-per-player rule.
   */
  mint(grant: AccessGrant, nowMs: number = Date.now()): MintedCredential {
    this.sweep(nowMs);
    this.revokePlayer(grant.saveId, grant.playerId);
    const tokenId = crypto.randomBytes(TOKEN_ID_BYTES).toString("hex");
    const secret = crypto.randomBytes(SECRET_BYTES).toString("hex");
    this.credentials.set(tokenId, {
      secretHash: sha256(secret),
      grant: { ...grant, tokenId }
    });
    return {
      token: `scto_${tokenId}_${secret}`,
      tokenId,
      expiresAtMs: grant.expiresAtMs
    };
  }

  /** Returns the grant, or `undefined` for unknown, malformed, expired and revoked alike. */
  verify(token: string | undefined, nowMs: number = Date.now()): AccessGrant | undefined {
    const match = token === undefined ? null : TOKEN_PATTERN.exec(token);
    const stored = match === null ? undefined : this.credentials.get(match[1]!);
    const candidate = match === null ? ABSENT_HASH : sha256(match[2]!);
    if (!secretsMatch(candidate, stored?.secretHash ?? ABSENT_HASH) || stored === undefined) {
      return undefined;
    }
    if (stored.grant.revokedAtMs !== undefined) {
      return undefined;
    }
    if (stored.grant.expiresAtMs <= nowMs) {
      this.credentials.delete(match![1]!);
      return undefined;
    }
    return stored.grant;
  }

  revoke(tokenId: string): void {
    this.credentials.delete(tokenId);
  }

  revokePlayer(saveId: string, playerId: string): void {
    for (const [tokenId, credential] of this.credentials) {
      if (credential.grant.saveId === saveId && credential.grant.playerId === playerId) {
        this.credentials.delete(tokenId);
      }
    }
  }

  sweep(nowMs: number = Date.now()): void {
    for (const [tokenId, credential] of this.credentials) {
      if (credential.grant.expiresAtMs <= nowMs) {
        this.credentials.delete(tokenId);
      }
    }
  }
}
