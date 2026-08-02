import * as z from "zod/v4";

import { CapabilitySchema, PlayerPreferencesSchema } from "../domain/capabilities.js";

export const FACTORIO_GATEWAY_PROTOCOL = "sceatorio.factorio-gateway/1" as const;

export const GatewayScopeSchema = z.object({
  bindingId: z.string().min(16).max(256),
  saveId: z.string().min(1).max(256),
  playerId: z.string().min(1).max(256),
  forceId: z.string().min(1).max(128),
  surfaceId: z.string().min(1).max(128).optional()
});
export type GatewayScope = z.infer<typeof GatewayScopeSchema>;

export const FactorioRequestSchema = z.object({
  protocol: z.literal(FACTORIO_GATEWAY_PROTOCOL),
  kind: z.literal("request"),
  id: z.string().uuid(),
  operation: z.string().regex(/^[a-z][a-z0-9_.-]{0,95}$/),
  scope: GatewayScopeSchema,
  payload: z.unknown()
});
export type FactorioRequest = z.infer<typeof FactorioRequestSchema>;

export const FactorioErrorSchema = z.object({
  code: z.string().regex(/^[A-Z][A-Z0-9_]{0,63}$/),
  message: z.string().min(1).max(1_000),
  retryable: z.boolean().default(false),
  details: z.unknown().optional()
});
export type FactorioError = z.infer<typeof FactorioErrorSchema>;

export const FactorioResponseSchema = z.object({
  protocol: z.literal(FACTORIO_GATEWAY_PROTOCOL),
  kind: z.literal("response"),
  id: z.string().uuid(),
  ok: z.boolean(),
  tick: z.number().int().nonnegative(),
  worldRevision: z.number().int().nonnegative(),
  result: z.unknown().optional(),
  error: FactorioErrorSchema.optional()
}).superRefine((response, context) => {
  if (response.ok && response.error !== undefined) {
    context.addIssue({
      code: "custom",
      path: ["error"],
      message: "Successful responses cannot contain an error"
    });
  }
  if (!response.ok && response.error === undefined) {
    context.addIssue({
      code: "custom",
      path: ["error"],
      message: "Failed responses must contain an error"
    });
  }
});
export type FactorioResponse = z.infer<typeof FactorioResponseSchema>;

export const PairingSurfaceGrantSchema = z.object({
  surfaceId: z.string().min(1).max(128),
  forceId: z.string().min(1).max(128),
  kind: z.enum(["primary", "team-secondary", "space-platform"]),
  visibility: z.literal("force-chart")
});
export type PairingSurfaceGrant = z.infer<typeof PairingSurfaceGrantSchema>;

export const PairingDescriptorSchema = z.object({
  protocol: z.literal(FACTORIO_GATEWAY_PROTOCOL),
  bindingId: z.string().min(16).max(256),
  saveId: z.string().min(1).max(256),
  playerId: z.string().min(1).max(256),
  forceId: z.string().min(1).max(128),
  teamId: z.string().min(1).max(128),
  capabilities: z.array(CapabilitySchema),
  surfaces: z.array(PairingSurfaceGrantSchema).min(1),
  preferences: PlayerPreferencesSchema,
  issuedTick: z.number().int().nonnegative(),
  /** Absent means the binding never expires — the only thing that ends it is revocation. */
  expiresTick: z.number().int().positive().optional()
}).superRefine((descriptor, context) => {
  if (descriptor.expiresTick !== undefined && descriptor.expiresTick <= descriptor.issuedTick) {
    context.addIssue({
      code: "custom",
      path: ["expiresTick"],
      message: "Pairing expiry must be after issuance"
    });
  }
  for (const [index, surface] of descriptor.surfaces.entries()) {
    if (surface.forceId !== descriptor.forceId) {
      context.addIssue({
        code: "custom",
        path: ["surfaces", index, "forceId"],
        message: "Surface grants must use the paired force"
      });
    }
  }
});
export type PairingDescriptor = z.infer<typeof PairingDescriptorSchema>;

export const PairingExchangeRequestSchema = z.object({
  protocol: z.literal(FACTORIO_GATEWAY_PROTOCOL),
  kind: z.literal("pairing.exchange"),
  id: z.string().uuid(),
  code: z.string().regex(/^[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/)
});
export type PairingExchangeRequest = z.infer<typeof PairingExchangeRequestSchema>;

export const PairingExchangeResponseSchema = z.object({
  protocol: z.literal(FACTORIO_GATEWAY_PROTOCOL),
  kind: z.literal("pairing.response"),
  id: z.string().uuid(),
  ok: z.boolean(),
  tick: z.number().int().nonnegative(),
  descriptor: PairingDescriptorSchema.optional(),
  error: FactorioErrorSchema.optional()
}).superRefine((response, context) => {
  if (response.ok && (response.descriptor === undefined || response.error !== undefined)) {
    context.addIssue({code: "custom", message: "Successful pairing requires only a descriptor"});
  }
  if (!response.ok && (response.error === undefined || response.descriptor !== undefined)) {
    context.addIssue({code: "custom", message: "Failed pairing requires only an error"});
  }
});
export type PairingExchangeResponse = z.infer<typeof PairingExchangeResponseSchema>;

export const MAX_GATEWAY_DATAGRAM_BYTES = 48 * 1024;
