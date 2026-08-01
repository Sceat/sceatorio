import * as z from "zod/v4";

export const CAPABILITIES = [
  "session:read",
  "production:read",
  "electricity:read",
  "research:read",
  "prototypes:read",
  "factory:read",
  "logistics:read",
  "trains:read",
  "alerts:read",
  "map:read",
  "circuits:read",
  "events:read",
  "blueprints:validate",
  "blueprints:write",
  "control_ports:write",
  "annotations:write"
] as const;

export const CapabilitySchema = z.enum(CAPABILITIES);
export type Capability = z.infer<typeof CapabilitySchema>;

export const ForceTechnologyStateSchema = z.object({
  aiAssistance: z.boolean().default(false)
});
export type ForceTechnologyState = z.infer<typeof ForceTechnologyStateSchema>;

export const PlayerPreferencesSchema = z.object({
  enabled: z.boolean().default(false),
  requestedCapabilities: z.array(CapabilitySchema).default([]),
  notifications: z.enum(["off", "important", "all"]).default("important"),
  blueprintDelivery: z.enum(["inbox-only", "allow-cursor"]).default("inbox-only")
});
export type PlayerPreferences = z.infer<typeof PlayerPreferencesSchema>;

export const ServerPolicySchema = z.object({
  enabled: z.boolean().default(false),
  allowedCapabilities: z.array(CapabilitySchema).default([...CAPABILITIES]),
  maxRequestTimeoutMs: z.number().int().min(100).max(60_000).default(30_000),
  maxPageSize: z.number().int().min(1).max(500).default(200)
});
export type ServerPolicy = z.infer<typeof ServerPolicySchema>;

export const DEFAULT_SERVER_POLICY: Readonly<ServerPolicy> = Object.freeze({
  enabled: false,
  allowedCapabilities: [...CAPABILITIES],
  maxRequestTimeoutMs: 30_000,
  maxPageSize: 200
});

export function resolveCapabilities(
  policy: ServerPolicy,
  technologies: ForceTechnologyState,
  preferences: PlayerPreferences
): Set<Capability> {
  if (!policy.enabled || !preferences.enabled || !technologies.aiAssistance) {
    return new Set();
  }

  const technologyCapabilities = new Set<Capability>(CAPABILITIES);
  const serverCapabilities = new Set(policy.allowedCapabilities);
  return new Set(
    preferences.requestedCapabilities.filter(
      (capability) =>
        serverCapabilities.has(capability) && technologyCapabilities.has(capability)
    )
  );
}
