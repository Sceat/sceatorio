#!/usr/bin/env node

import { loadHttpConfiguration } from "./http/config.js";
import { InMemoryCredentialStore } from "./http/credentials.js";
import { createNodeServer } from "./http/node-bridge.js";
import { PairGuard } from "./http/pair-guard.js";
import { createRouter, grantFromContext, type HttpLogger } from "./http/routes.js";
import { exchangePairingCode } from "./pairing.js";
import { createSceatorioMcpHandler } from "./server.js";
import { CorrelatedFactorioTransport } from "./transport/correlated-transport.js";
import { UdpDatagramPeer } from "./transport/udp-peer.js";

/**
 * Remote entry point: one HTTP listener serving the pairing page, the pairing
 * exchange and the Streamable HTTP MCP endpoint. The stdio entry (`index.ts`)
 * is untouched and still the local-operator path.
 */

const SWEEP_INTERVAL_MS = 60_000;

const logger: HttpLogger = {
  error: (message, metadata) => console.error(message, metadata ?? {}),
  info: (message, metadata) => console.error(message, metadata ?? {})
};

async function main(): Promise<void> {
  const configuration = loadHttpConfiguration(process.env);
  const peer = new UdpDatagramPeer({
    factorioPort: configuration.factorioPort,
    ...(configuration.localPort === undefined ? {} : { localPort: configuration.localPort })
  });
  const factorio = new CorrelatedFactorioTransport(peer, {
    defaultTimeoutMs: configuration.policy.maxRequestTimeoutMs
  });
  const credentials = new InMemoryCredentialStore();
  const mcp = createSceatorioMcpHandler({
    factorio,
    policy: configuration.policy,
    resolveGrant: grantFromContext,
    logger
  });
  const server = createNodeServer(
    createRouter({
      publicUrl: configuration.publicUrl,
      credentials,
      guard: new PairGuard(),
      exchange: (code) => exchangePairingCode(peer, code),
      mcp,
      logger
    })
  );

  const sweep = setInterval(() => credentials.sweep(), SWEEP_INTERVAL_MS);
  sweep.unref();

  let shutdownPromise: Promise<void> | undefined;
  const shutdown = (): Promise<void> => {
    shutdownPromise ??= (async () => {
      clearInterval(sweep);
      await new Promise<void>((resolve) => server.close(() => resolve()));
      server.closeAllConnections();
      await mcp.close();
      await factorio.close();
    })();
    return shutdownPromise;
  };
  process.once("SIGINT", () => void shutdown());
  process.once("SIGTERM", () => void shutdown());

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(configuration.port, configuration.bindAddress, () => resolve());
  });
  if (configuration.bindAddress === "0.0.0.0" || configuration.bindAddress === "::") {
    console.error("WARNING: binding a wildcard address publishes this endpoint on every interface");
  }
  console.error(
    `Sceatorio MCP server is listening on http://${configuration.bindAddress}:${configuration.port}`,
    { publicUrl: configuration.publicUrl }
  );
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
