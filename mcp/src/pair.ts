#!/usr/bin/env node

import { descriptorToAccessGrant, exchangePairingCode } from "./pairing.js";
import { UdpDatagramPeer } from "./transport/udp-peer.js";

function required(name: string): string {
  const value = process.env[name];
  if (value === undefined || value.length === 0) throw new Error(`${name} is required`);
  return value;
}

function port(name: string, requiredValue = false): number | undefined {
  const raw = requiredValue ? required(name) : process.env[name];
  if (raw === undefined) return undefined;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 1 || value > 65_535) {
    throw new Error(`${name} must be a TCP/UDP port`);
  }
  return value;
}

async function main(): Promise<void> {
  const factorioPort = port("SCEATORIO_FACTORIO_PORT", true)!;
  const localPort = port("SCEATORIO_MCP_UDP_PORT");
  const peer = new UdpDatagramPeer({
    factorioPort,
    ...(localPort === undefined ? {} : {localPort})
  });
  try {
    const descriptor = await exchangePairingCode(peer, required("SCEATORIO_PAIRING_CODE"));
    const grant = descriptorToAccessGrant(descriptor, {
      ...(process.env.SCEATORIO_PRINCIPAL_ID === undefined
        ? {} : {principalId: process.env.SCEATORIO_PRINCIPAL_ID})
    });
    process.stdout.write(`${JSON.stringify(grant)}\n`);
  } finally {
    await peer.close();
  }
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
