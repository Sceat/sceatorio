# Sceatorio AI/MCP companion

This directory builds the vendor-neutral TypeScript MCP companion for Sceatorio. It uses the official MCP TypeScript SDK 2.0.0, targets the Factorio 2.1.12 API, and exposes exactly 29 bounded tools. Codex and Claude Code are compatible MCP hosts.

The Factorio mod and companion are versioned together in this open-source repository and every tagged source release contains both. The Factorio Mod Portal ZIP intentionally contains only files Factorio can execute or display: the Lua gateway, prototypes, locale, and graphics. Node.js, this TypeScript source, tests, and dependencies stay in the companion and are never added to every joining player's mod download.

The path is fail-closed: both server policies must enable AI Assistance, the force must research the single **AI Assistance** technology, a force-owned Uplink must stay powered, the player must opt in, and the current pairing must contain the requested capability and surface. Factorio re-checks those conditions for every call and atomically enforces total and expensive budgets at both the per-player and save-wide layers. Long event waits count as expensive.

## Requirements and checks

- Node.js 20 or newer.
- Factorio 2.1.12 started with loopback Lua UDP for live integration.

```sh
cd mcp
npm ci
npm run check
npm run build
```

The TypeScript suite covers authorization, surface grants, pairing schemas, correlation/timeouts, and tool/blueprint validation. From the repository root, `tests/headless/run.sh ai-e2e` adds a real Factorio 2.1.12 gateway and independent stdio-client test.

## Local stdio and pairing

Start the dedicated server with a localhost Lua UDP port:

```sh
factorio --enable-lua-udp=34198 --start-server save.zip
```

In Factorio, enable the global AI setting, research **AI Assistance**, build and power an AI Uplink, and use its GUI to create a short-lived one-time code; creating that code is the player's explicit opt-in. Then exchange the code from the trusted server host:

```sh
cd mcp
npm run build
SCEATORIO_FACTORIO_PORT=34198 \
SCEATORIO_PAIRING_CODE=XXXXX-XXXX-XXXX \
node dist/src/pair.js
```

The command prints the server-derived access-grant JSON. Protect it like local credential material: do not commit it, put it in Factorio settings, or write it to shared logs. Configure the stdio process with:

- `SCEATORIO_FACTORIO_PORT`: Factorio's `--enable-lua-udp` port.
- `SCEATORIO_MCP_UDP_PORT`: optional fixed loopback source port; omit it for an ephemeral port.
- `SCEATORIO_SERVER_POLICY_JSON`: companion policy JSON. It defaults to disabled; the minimal enabled value is `{"enabled":true}`.
- `SCEATORIO_ACCESS_GRANT_JSON`: the exact JSON printed by the pairing command.

With those values in the MCP host's private environment, run `node mcp/dist/src/index.js` over stdio. Regenerate the grant whenever the player revokes it or the team gains authoritative access to a new planet/platform surface. Surface grants are immutable: the new one-time pairing revokes the old binding and includes surfaces known to the team at that moment.

The pairing code expires after five minutes of game time and is consumed once. The resulting grant carries no expiry at all: the binding lasts until it is revoked, which happens on **Revoke** in the Uplink GUI, on a new pairing that supersedes it, on a force change, when the player leaves, or when an administrator turns the gateway off. The code is never stored in the save. Bearer tokens and API keys never enter Factorio UDP or save data. Keep both UDP sockets on loopback; they are not an internet authentication boundary.

## Register with Codex

Build from the checked-out release, then exchange the one-time code while Factorio is running on the same trusted host:

```sh
cd /absolute/path/to/sceatorio/mcp
npm ci
npm run check
npm run build

SCEATORIO_GRANT="$(
  SCEATORIO_FACTORIO_PORT=34198 \
  SCEATORIO_PAIRING_CODE=XXXXX-XXXX-XXXX \
  node dist/src/pair.js
)"
```

Register the absolute compiled entry point and its private environment with Codex:

```sh
codex mcp add sceatorio \
  --env SCEATORIO_FACTORIO_PORT=34198 \
  --env 'SCEATORIO_SERVER_POLICY_JSON={"enabled":true}' \
  --env "SCEATORIO_ACCESS_GRANT_JSON=$SCEATORIO_GRANT" \
  -- node "$PWD/dist/src/index.js"

codex mcp list
unset SCEATORIO_GRANT
```

`codex mcp add` saves the launch environment, including the scoped grant, in Codex's private local configuration. Do not paste that configuration into issues or logs. Start a new Codex session after adding or replacing the server; an already-running session does not acquire the new process or environment. With Factorio still running, ask the new session to call Sceatorio's `get_session` tool to verify the live connection.

Remove the registration when testing is complete or before installing a replacement grant:

```sh
codex mcp remove sceatorio
codex mcp list
```

A revoked or superseded grant cannot be refreshed in place. Create a new code at the powered Uplink, remove the old Codex registration, repeat the exchange and registration commands, then start another new Codex session. Do not expose the Lua UDP port to a remote Codex process; the supported stdio path is deliberately loopback-only.

## Source of truth

- Factorio capabilities and setting defaults: [`../src/core/aiConstants.lua`](../src/core/aiConstants.lua)
- Companion capabilities and policy: [`src/domain/capabilities.ts`](src/domain/capabilities.ts)
- Access-grant and surface authorization: [`src/auth/authorize.ts`](src/auth/authorize.ts)
- Tool schemas: [`src/catalog/schemas.ts`](src/catalog/schemas.ts)
- Exact tool/operation map: [`src/catalog/tools.ts`](src/catalog/tools.ts)
- Pairing and UDP envelopes: [`src/transport/protocol.ts`](src/transport/protocol.ts)

`npm run catalog` prints the machine-readable tool catalog derived from the executable schemas. Do not maintain a parallel handwritten list.

Every catalog entry explicitly declares read-only, destructive, idempotent, and open-world metadata. All 29 tools are closed-world. The dedicated output-port write, the saved-blueprint delete, and the blueprint-book update and delete are destructive/non-idempotent; blueprint save/load, blueprint-book create, and private annotation are non-destructive/non-idempotent.

## Safety and deployment boundary

No tool moves, mines, crafts, fights, teleports, places entities, runs arbitrary Lua/RCON, edits train schedules or logistic requests, or mutates generic factory entities. Writes are limited to the dedicated AI output port, the player's mod-owned blueprint inbox, their clipboard when the caller explicitly asks for cursor delivery, and private TTL annotations.

`createSceatorioMcpHandler()` is available for an integrator-owned Streamable HTTP service, but this repository does not ship an authorization server or public endpoint. Such a deployment must add and test OAuth 2.1 validation, per-request grant resolution, revocation, TLS, redacted logs, and network isolation without exposing Factorio UDP.
