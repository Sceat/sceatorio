# MCP end-to-end release gate

Status: **local Lua/stdio gate passed on Factorio 2.1.12; public HTTP/OAuth deployment is not shipped.**

Run the isolated gate with:

```sh
tests/headless/run.sh ai-e2e
```

The harness uses a private user-data directory, builds the TypeScript companion, starts the real Factorio 2.1.12 dedicated binary with `--enable-lua-udp`, enables the otherwise default-off AI and development fixture settings, and drives the real UDP gateway plus an independent stdio MCP client. Success ends with:

```text
SCEATORIO_AI_E2E_PASS: pairing, <catalog size>-tool gateway, stdio MCP, scope, replay, policy disable, expiry, and revoke verified
```

## Automated evidence

The gate verifies:

- one pairing exchange emits exactly one response datagram;
- an exact pairing retry replays the same response, a conflicting UUID is rejected before consuming the code, a consumed code cannot mint another binding, and an expired code is rejected;
- Factorio derives the binding's save, player, force, team, surfaces, and 16-capability intersection;
- re-pairing revokes the old binding without resetting that logical player's shared quota;
- an identical completed operation retry returns the exact response without repeating the effect or spending quota, while a conflicting UUID is rejected;
- authorization is revalidated before replay-cache lookup, so explicit revocation cannot replay a cached success;
- global disable revokes bindings, cancels waits, clears one-time/replay state, stops UDP draining, and a stale buffered request fails closed after re-enable;
- 24 of the catalog's operation paths reach the real Lua dispatcher, with 23 successful headless operations and the private annotation path correctly returning `PLAYER_REQUIRED` without a connected human; the saved-blueprint delete path and the four blueprint-book paths are covered by the static and TypeScript suites instead;
- wrong-force and wrong-surface requests fail closed;
- the compiled stdio server completes MCP initialization, offers exactly the tool set `mcp/src/catalog/tools.ts` declares, and calls `get_session` against the live save;
- explicit revocation rejects the next request.

Static and TypeScript tests additionally cover malformed schemas, explicit tool safety annotations, policy/capability authorization, secondary-surface grant rules, correlation, timeouts, bounded binding/replay history, and capability re-checks while an event wait is pending.

## Evidence still required for broader deployment claims

The automated fixture deliberately uses development-only RCON hooks to create a virtual headless player and entities. Before claiming a fully player-driven host integration, capture a separate manual run through the production Uplink GUI with two connected human teams, a Space Age secondary planet, save/restart persistence, cursor delivery, and revocation during an active client session. Development hooks are disabled by default and are not a production pairing path.

Before enabling any internet-facing Streamable HTTP endpoint, independently test OAuth issuer/audience validation, protected-resource metadata, per-request grant resolution, TLS/reverse-proxy behavior, revocation, sanitized logs, and horizontal-session behavior. This repository includes only a handler factory for integrators; it does not ship an authorization server, public endpoint, MCP image, or Helm sidecar. Factorio's Lua UDP port must remain loopback-only.
