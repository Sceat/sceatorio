import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

import * as z from "zod/v4";

import {
  AccessGrantSchema,
  materializeAccessGrant,
  type AccessGrant
} from "../auth/authorize.js";

/**
 * First-party bearer credentials.
 *
 * The store holds `sha256(secret)` and never the secret itself, and the
 * comparison is timing-safe — it is a verifier file like `/etc/shadow`, not a
 * credential vault. Without `SCEATORIO_CREDENTIAL_STORE` it stays in memory;
 * with it, the same verifiers survive a restart so a player pairs once and
 * never again. Revocation stays authoritative in-game: Lua re-authorizes the
 * live binding on every call, so a reloaded verifier buys no access back.
 */

const TOKEN_ID_BYTES = 9;
const SECRET_BYTES = 32;
const TOKEN_PATTERN = /^scto_([0-9a-f]{18})_([0-9a-f]{64})$/u;
const BEARER_PATTERN = /^bearer +(\S+)$/iu;
const STORE_VERSION = 1;

/** Compared against when no credential matches, so unknown ids cost the same as wrong secrets. */
const ABSENT_HASH = sha256("sceatorio:absent");

const StoredCredentialSchema = z.object({
  tokenId: z.string().regex(/^[0-9a-f]{18}$/u),
  secretHash: z.string().regex(/^[0-9a-f]{64}$/u),
  grant: AccessGrantSchema
});

const CredentialFileSchema = z.object({
  version: z.literal(STORE_VERSION),
  credentials: z.array(StoredCredentialSchema)
});

export interface MintedCredential {
  /** Shown to the player exactly once; never stored in this form. */
  token: string;
  tokenId: string;
  /** Absent when the pairing never expires, which is every pairing since 2.1.x. */
  expiresAtMs?: number | undefined;
}

export interface CredentialStoreLogger {
  error(message: string, metadata?: Readonly<Record<string, unknown>>): void;
}

export interface CredentialStoreOptions {
  /** Absolute path of the verifier file. Omitted keeps the store in memory only. */
  path?: string | undefined;
  logger?: CredentialStoreLogger | undefined;
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

export class CredentialStore {
  private readonly credentials = new Map<string, StoredCredential>();
  private readonly path: string | undefined;
  private readonly logger: CredentialStoreLogger | undefined;

  constructor(options: CredentialStoreOptions = {}) {
    this.path = options.path;
    this.logger = options.logger;
    this.load();
  }

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
    this.persist();
    return {
      token: `scto_${tokenId}_${secret}`,
      tokenId,
      ...(grant.expiresAtMs === undefined ? {} : { expiresAtMs: grant.expiresAtMs })
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
    if (expired(stored.grant, nowMs)) {
      this.credentials.delete(match![1]!);
      this.persist();
      return undefined;
    }
    return stored.grant;
  }

  revoke(tokenId: string): void {
    if (this.credentials.delete(tokenId)) {
      this.persist();
    }
  }

  revokePlayer(saveId: string, playerId: string): void {
    let removed = false;
    for (const [tokenId, credential] of this.credentials) {
      if (credential.grant.saveId === saveId && credential.grant.playerId === playerId) {
        this.credentials.delete(tokenId);
        removed = true;
      }
    }
    if (removed) {
      this.persist();
    }
  }

  /** Only pre-2.1.x grants carry an expiry at all; the sweep is their retirement path. */
  sweep(nowMs: number = Date.now()): void {
    let removed = false;
    for (const [tokenId, credential] of this.credentials) {
      if (expired(credential.grant, nowMs)) {
        this.credentials.delete(tokenId);
        removed = true;
      }
    }
    if (removed) {
      this.persist();
    }
  }

  /**
   * A missing, empty or malformed file is not fatal: the server starts with an
   * empty store and everyone re-pairs once, which beats refusing to boot.
   */
  private load(): void {
    if (this.path === undefined) {
      return;
    }
    let text: string;
    try {
      text = fs.readFileSync(this.path, "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        this.logger?.error("Credential store is unreadable; starting empty", {
          error: (error as NodeJS.ErrnoException).code ?? "UNKNOWN"
        });
      }
      return;
    }
    if (text.trim().length === 0) {
      return;
    }
    const parsed = CredentialFileSchema.safeParse(parseJson(text));
    if (!parsed.success) {
      this.logger?.error("Credential store is malformed; starting empty");
      return;
    }
    for (const entry of parsed.data.credentials) {
      this.credentials.set(entry.tokenId, {
        secretHash: Buffer.from(entry.secretHash, "hex"),
        grant: materializeAccessGrant(entry.grant)
      });
    }
    this.sweep();
  }

  /**
   * Atomic by construction: a fresh 0600 temp file in the same directory is
   * renamed over the target, so a crash mid-write leaves the previous file
   * intact. A write failure is logged and never propagated — losing durability
   * must not take the endpoint down.
   */
  private persist(): void {
    if (this.path === undefined) {
      return;
    }
    const payload = `${JSON.stringify({
      version: STORE_VERSION,
      credentials: [...this.credentials].map(([tokenId, credential]) => ({
        tokenId,
        secretHash: credential.secretHash.toString("hex"),
        grant: {
          ...credential.grant,
          capabilities: [...credential.grant.capabilities]
        }
      }))
    })}\n`;
    const temporary = `${this.path}.${crypto.randomBytes(6).toString("hex")}.tmp`;
    try {
      fs.mkdirSync(path.dirname(this.path), { recursive: true });
      fs.writeFileSync(temporary, payload, { mode: 0o600, flag: "wx" });
      fs.renameSync(temporary, this.path);
    } catch (error) {
      this.logger?.error("Failed to persist the credential store", {
        error: error instanceof Error ? error.message : String(error)
      });
      try {
        fs.rmSync(temporary, { force: true });
      } catch {
        // The temp file is already gone or unreachable; nothing else to do.
      }
    }
  }
}

function expired(grant: AccessGrant, nowMs: number): boolean {
  return grant.expiresAtMs !== undefined && grant.expiresAtMs <= nowMs;
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}
