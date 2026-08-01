import * as z from "zod/v4";

import { AccessGrantSchema, materializeAccessGrant, type AccessGrant } from "./auth/authorize.js";
import { ServerPolicySchema, type ServerPolicy } from "./domain/capabilities.js";

export interface StdioConfiguration {
  factorioPort: number;
  localPort?: number | undefined;
  grant: AccessGrant;
  policy: ServerPolicy;
}

const PortSchema = z.coerce.number().int().min(1).max(65_535);

export function loadStdioConfiguration(environment: NodeJS.ProcessEnv): StdioConfiguration {
  const factorioPort = PortSchema.parse(required(environment, "SCEATORIO_FACTORIO_PORT"));
  const localPortValue = environment.SCEATORIO_MCP_UDP_PORT;
  const grantData = AccessGrantSchema.parse(
    parseJson(required(environment, "SCEATORIO_ACCESS_GRANT_JSON"), "SCEATORIO_ACCESS_GRANT_JSON")
  );
  const policy = ServerPolicySchema.parse(
    environment.SCEATORIO_SERVER_POLICY_JSON === undefined
      ? {}
      : parseJson(environment.SCEATORIO_SERVER_POLICY_JSON, "SCEATORIO_SERVER_POLICY_JSON")
  );

  return {
    factorioPort,
    ...(localPortValue === undefined ? {} : { localPort: PortSchema.parse(localPortValue) }),
    grant: materializeAccessGrant(grantData),
    policy
  };
}

function required(environment: NodeJS.ProcessEnv, name: string): string {
  const value = environment[name];
  if (value === undefined || value.length === 0) {
    throw new Error(`${name} is required`);
  }
  return value;
}

function parseJson(value: string, name: string): unknown {
  try {
    return JSON.parse(value);
  } catch {
    throw new Error(`${name} must contain valid JSON`);
  }
}
