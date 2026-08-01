#!/usr/bin/env node

import { serveStdio } from "@modelcontextprotocol/server/stdio";

import { loadStdioConfiguration } from "./config.js";
import { createSceatorioMcpServer } from "./server.js";
import { CorrelatedFactorioTransport } from "./transport/correlated-transport.js";
import { UdpDatagramPeer } from "./transport/udp-peer.js";

async function main(): Promise<void> {
  const configuration = loadStdioConfiguration(process.env);
  const peer = new UdpDatagramPeer({
    factorioPort: configuration.factorioPort,
    ...(configuration.localPort === undefined ? {} : { localPort: configuration.localPort })
  });
  const factorio = new CorrelatedFactorioTransport(peer, {
    defaultTimeoutMs: configuration.policy.maxRequestTimeoutMs
  });

  const handle = serveStdio(() =>
    createSceatorioMcpServer({
      factorio,
      policy: configuration.policy,
      grant: configuration.grant,
      logger: {
        error: (message, metadata) => console.error(message, metadata ?? {})
      }
    })
  );

  let shutdownPromise: Promise<void> | undefined;
  const shutdown = (): Promise<void> => {
    shutdownPromise ??= (async () => {
      await handle.close();
      await factorio.close();
    })();
    return shutdownPromise;
  };
  process.once("SIGINT", () => void shutdown());
  process.once("SIGTERM", () => void shutdown());
  process.stdin.once("end", () => void shutdown());
  console.error("Sceatorio MCP server is running on stdio");
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
