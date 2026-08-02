import * as z from "zod/v4";

import {
  CapabilitySchema,
  PlayerPreferencesSchema,
  type Capability,
  type PlayerPreferences,
  type ServerPolicy
} from "../domain/capabilities.js";
import { PairingSurfaceGrantSchema } from "../transport/protocol.js";

export const SurfaceGrantSchema = PairingSurfaceGrantSchema;
export type SurfaceGrant = z.infer<typeof SurfaceGrantSchema>;

export const AccessGrantSchema = z.object({
  bindingId: z.string().min(16).max(256),
  principalId: z.string().min(1).max(256),
  tokenId: z.string().min(1).max(256),
  saveId: z.string().min(1).max(256),
  playerId: z.string().min(1).max(256),
  forceId: z.string().min(1).max(128),
  teamId: z.string().min(1).max(128),
  capabilities: z.array(CapabilitySchema),
  surfaces: z.array(SurfaceGrantSchema).min(1),
  preferences: PlayerPreferencesSchema,
  issuedAtMs: z.number().int().nonnegative(),
  /** Absent means the grant never expires; only revocation ends a pairing. */
  expiresAtMs: z.number().int().positive().optional(),
  revokedAtMs: z.number().int().nonnegative().optional()
});
export type AccessGrantData = z.infer<typeof AccessGrantSchema>;

export interface AccessGrant
  extends Omit<AccessGrantData, "capabilities" | "preferences"> {
  capabilities: ReadonlySet<Capability>;
  preferences: Readonly<PlayerPreferences>;
}

export interface AuthorizationTarget {
  saveId: string;
  forceId: string;
  surfaceId?: string | undefined;
}

export type AuthorizationErrorCode =
  | "AI_DISABLED"
  | "PLAYER_NOT_OPTED_IN"
  | "TOKEN_EXPIRED"
  | "TOKEN_REVOKED"
  | "INSUFFICIENT_CAPABILITY"
  | "PLAYER_PREFERENCE_DENIED"
  | "REQUEST_BUDGET_EXCEEDED"
  | "SAVE_SCOPE_MISMATCH"
  | "FORCE_SCOPE_MISMATCH"
  | "SURFACE_SCOPE_MISMATCH";

export class AuthorizationError extends Error {
  readonly code: AuthorizationErrorCode;

  constructor(code: AuthorizationErrorCode, message: string) {
    super(message);
    this.name = "AuthorizationError";
    this.code = code;
  }
}

export function materializeAccessGrant(data: AccessGrantData): AccessGrant {
  return {
    ...data,
    capabilities: new Set(data.capabilities),
    preferences: data.preferences
  };
}

export function authorizeAccess(
  grant: AccessGrant,
  policy: ServerPolicy,
  capability: Capability,
  target: AuthorizationTarget,
  nowMs = Date.now()
): void {
  if (!policy.enabled) {
    throw new AuthorizationError("AI_DISABLED", "AI assistance is disabled by server policy");
  }
  if (!grant.preferences.enabled) {
    throw new AuthorizationError(
      "PLAYER_NOT_OPTED_IN",
      "This player has not enabled AI assistance"
    );
  }
  if (grant.revokedAtMs !== undefined) {
    throw new AuthorizationError("TOKEN_REVOKED", "This pairing has been revoked");
  }
  if (grant.expiresAtMs !== undefined && grant.expiresAtMs <= nowMs) {
    throw new AuthorizationError("TOKEN_EXPIRED", "This access grant has expired");
  }
  if (!policy.allowedCapabilities.includes(capability) || !grant.capabilities.has(capability)) {
    throw new AuthorizationError(
      "INSUFFICIENT_CAPABILITY",
      `Capability ${capability} is not available to this pairing`
    );
  }
  if (grant.saveId !== target.saveId) {
    throw new AuthorizationError("SAVE_SCOPE_MISMATCH", "The request targets another save");
  }
  if (grant.forceId !== target.forceId) {
    throw new AuthorizationError("FORCE_SCOPE_MISMATCH", "The request targets another force");
  }
  if (target.surfaceId !== undefined) {
    const surface = grant.surfaces.find((candidate) => candidate.surfaceId === target.surfaceId);
    if (surface === undefined || surface.forceId !== grant.forceId) {
      throw new AuthorizationError(
        "SURFACE_SCOPE_MISMATCH",
        "The requested surface is outside this player's team scope"
      );
    }
  }
}
