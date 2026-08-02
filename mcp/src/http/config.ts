import path from "node:path";

import * as z from "zod/v4";

import { ServerPolicySchema, type ServerPolicy } from "../domain/capabilities.js";

export interface HttpConfiguration {
  /** Never defaults to `0.0.0.0`: the production pod is hostNetwork, so a wildcard bind is public. */
  bindAddress: string;
  port: number;
  /** Absolute base URL players reach this service on; printed into the pairing command. */
  publicUrl: string;
  factorioPort: number;
  localPort?: number | undefined;
  /**
   * Absolute path of the bearer verifier file. Unset keeps credentials in
   * memory, which means everyone re-pairs after a restart.
   */
  credentialStorePath?: string | undefined;
  policy: ServerPolicy;
}

const PortSchema = z.coerce.number().int().min(1).max(65_535);

export function loadHttpConfiguration(environment: NodeJS.ProcessEnv): HttpConfiguration {
  const factorioPort = PortSchema.parse(required(environment, "SCEATORIO_FACTORIO_PORT"));
  const localPortValue = environment.SCEATORIO_MCP_UDP_PORT;
  const credentialStorePath = environment.SCEATORIO_CREDENTIAL_STORE;
  const policy = ServerPolicySchema.parse(
    environment.SCEATORIO_SERVER_POLICY_JSON === undefined
      ? {}
      : parseJson(environment.SCEATORIO_SERVER_POLICY_JSON, "SCEATORIO_SERVER_POLICY_JSON")
  );

  return {
    bindAddress: environment.SCEATORIO_HTTP_BIND ?? "127.0.0.1",
    port: PortSchema.parse(environment.SCEATORIO_HTTP_PORT ?? 34_200),
    publicUrl: publicUrl(required(environment, "SCEATORIO_PUBLIC_URL")),
    factorioPort,
    ...(localPortValue === undefined ? {} : { localPort: PortSchema.parse(localPortValue) }),
    ...(credentialStorePath === undefined || credentialStorePath.length === 0
      ? {}
      : { credentialStorePath: absolutePath(credentialStorePath, "SCEATORIO_CREDENTIAL_STORE") }),
    policy
  };
}

function publicUrl(value: string): string {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error("SCEATORIO_PUBLIC_URL must be an absolute URL");
  }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
    throw new Error("SCEATORIO_PUBLIC_URL must be an http(s) URL");
  }
  return `${parsed.origin}${parsed.pathname}`.replace(/\/+$/u, "");
}

/** Relative paths would resolve against whatever cwd the container happens to have. */
function absolutePath(value: string, name: string): string {
  if (!path.isAbsolute(value)) {
    throw new Error(`${name} must be an absolute file path`);
  }
  return path.normalize(value);
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
