# Sceatorio Factorio gateway protocol v1

Status: implemented local wire contract, 2026-08-01.

Protocol identifier: `sceatorio.factorio-gateway/1`.

The Zod schemas in [`mcp/src/transport/protocol.ts`](../mcp/src/transport/protocol.ts) and the tool definitions in [`mcp/src/catalog/tools.ts`](../mcp/src/catalog/tools.ts) are the canonical sources of truth. TypeScript types are inferred from those schemas. Changes to a wire field, capability, tool name, or input schema must begin there and include tests; this prose must then be updated in the same change.

## Datagram binding

The Factorio headless server binds a localhost UDP port with `--enable-lua-udp=<port>`. The sidecar binds its own localhost source port and sends UTF-8 JSON to Factorio. The Lua mod drains server packets with `helpers.recv_udp(0)`, processes `on_udp_packet_received`, and sends the response to the event's `source_port` with `helpers.send_udp(source_port, json, 0)`.

Both sides reject datagrams larger than 48 KiB. Protocol v1 does not fragment messages. UDP is lossy: each request has one UUID, at most one response, and a deadline. Unknown or late response IDs are ignored. The companion does not automatically retry mutations, but a caller may safely resend the exact same envelope and UUID within the bounded replay window described below.

Lua stores completed operation responses per player and binding for at most 64 entries, 512 KiB, and ten game minutes. It revalidates the binding and current authorization before consulting this cache; an identical retry returns the exact encoded response without spending quota or repeating side effects, while the same UUID with different bytes returns `DUPLICATE_REQUEST_ID`. Revocation and global disable therefore cannot be bypassed with a cached success.

## One-time pairing exchange

Before normal requests, the companion sends one `pairing.exchange` envelope containing the short-lived code shown by a powered AI Uplink. Lua keeps at most 64 exact pairing responses/512 KiB for five game minutes. An identical UUID/envelope retry returns that exact response; a conflicting UUID is rejected before the one-time code is consumed. A successful `pairing.response` returns a descriptor derived by the server: binding, save, player, force, team, authorized surfaces, effective capabilities, preferences, and game-tick lifetime. The caller cannot choose those scopes.

The pairing code crosses loopback UDP once. The production GUI flow never stores it in the save or logs it; the explicitly enabled development-only RCON fixture returns a test code in command output and must remain disabled in production. Bearer credentials never enter this protocol. Failed exchange responses contain only a bounded public error.

Pairing descriptors are immutable. When a team later gains authoritative access to a new planet or platform surface, the player creates a fresh one-time pairing; Lua revokes the prior binding and derives a new descriptor from the team's current recorded surfaces. Normal tool requests cannot add surface grants.

## Request

```json
{
  "protocol": "sceatorio.factorio-gateway/1",
  "kind": "request",
  "id": "00000000-0000-4000-8000-000000000001",
  "operation": "statistics.production",
  "scope": {
    "bindingId": "opaque-binding-id",
    "saveId": "save-uuid",
    "playerId": "stable-player-id",
    "forceId": "player-force",
    "surfaceId": "nauvis"
  },
  "payload": {
    "statistic": "item",
    "direction": "both",
    "window": "1m"
  }
}
```

`surfaceId` is omitted for operations that are not bound to one surface. The Lua dispatcher resolves `bindingId` and rejects any mismatch in the asserted save, player, force, surface, or capability. These identifiers are scoping assertions, not authentication secrets.

## Response

Success:

```json
{
  "protocol": "sceatorio.factorio-gateway/1",
  "kind": "response",
  "id": "00000000-0000-4000-8000-000000000001",
  "ok": true,
  "tick": 123456,
  "worldRevision": 81,
  "result": {}
}
```

Failure:

```json
{
  "protocol": "sceatorio.factorio-gateway/1",
  "kind": "response",
  "id": "00000000-0000-4000-8000-000000000001",
  "ok": false,
  "tick": 123456,
  "worldRevision": 81,
  "error": {
    "code": "SURFACE_SCOPE_MISMATCH",
    "message": "Surface is not authorized for this binding",
    "retryable": false
  }
}
```

Error messages are safe for the paired player. Internal stack traces, paths, credentials, pairing codes, and UDP payload dumps are never returned.

## Operation and tool mapping

MCP tool names stay human-readable while UDP operation names are namespaced. The single canonical mapping, schema, description, required capability, and explicit read-only/destructive/idempotent/open-world hints is `V1_TOOL_DEFINITIONS` in [`tools.ts`](../mcp/src/catalog/tools.ts). Every tool is closed-world. `write_control_port` is destructive and non-idempotent; blueprint save/load and annotation are non-destructive but non-idempotent.

The v1 surface contains these groups:

- Session and raw statistics.
- Electric, research, recipe, prototype, and transport-capacity reads.
- Bounded entity, logistic-network, train, alert, chart, and circuit-port reads.
- Cursor-based event reads and bounded waits.
- Structured blueprint validation, objective analysis, immutable save/list/load, and player-controlled delivery.
- Dedicated control-port writes and temporary private map annotations.

It contains no character-control, free-form entity mutation, arbitrary code execution, or convenience diagnosis/build tools. Tests assert that the forbidden character-control names do not enter the catalog.

## Pagination and revisions

- Page limits are at most 200 in the public schemas and may be lower by server policy.
- Cursors use validated operation-specific formats and bounded offsets/ring positions. Every use is independently authorized against the current binding, force, and surface, so editing a cursor cannot broaden scope.
- Every response includes the tick at which the snapshot was read. The current Lua implementation uses the monotonically increasing game tick as `worldRevision`.
- An invalidated entity ID or cursor returns a stable error rather than silently targeting a replacement object.

## Events

`get_events` returns immediately after an opaque cursor. `wait_for_events` waits at most 25 seconds and returns the new cursor even when no event matches. Wait registration consumes normal and expensive per-player quota plus the save-wide total and expensive quotas. Factorio checks at most 16 of the 256 pending waits every six ticks in round-robin order and scans the 512-entry event ring only when its cursor advanced or its deadline is due. Consequently, a saturated queue may complete up to roughly 1.6 game-seconds after its nominal deadline; the companion reserves a two-second transport margin. Events are filtered before leaving Lua and retain only fields authorized for the binding. MCP itself does not keep Claude running; a persistent Claude Code or Agent SDK process owns the loop.

## Blueprint limits and semantics

The canonical structured layout schema validates entity-number uniqueness and connection references before transport. V1 accepts at most 512 entities and 2,048 tiles, subject to the 48 KiB encoded datagram limit and stricter server policy.

Factorio remains authoritative for entity/tile prototypes, quality, recipe/category/unlock state, connection targets, wire names, a numeric connector-ID range, and optional non-mutating entity-placement validation. It does not prove prototype-specific connector compatibility, simulate tile collisions, or analyze complete factory connectivity. It computes build-item cost and rejects arbitrary entity settings. A successful `blueprint.save` creates a new immutable, canonicalized virtual record in the player's mod-owned AI library/inbox; it does not create an inventory item unless the player separately requested and allowed cursor delivery. The library retains the newest 100 records within a 512 KiB canonical-layout budget and reports any oldest-first eviction in the save result; only a layout that individually exceeds that budget is rejected. V1 records always use revision `1`; the wire field is reserved for future compatibility and does not imply update history. It never places ghosts or writes directly to native **My Blueprints**.

## MCP-facing errors

The sidecar converts gateway and authorization failures into bounded MCP tool errors:

- Policy/scope failures are non-retryable.
- UDP timeouts and transport unavailability are retryable.
- Malformed protocol responses are non-retryable and audited.
- Lua declares domain errors retryable only when repeating the same request can safely succeed.
- Unknown internal errors expose only `INTERNAL_ERROR`; full details go to redacted server logs.

## Compatibility

The MCP server uses the stable official TypeScript SDK 2.0.0 and the MCP 2026-07-28 stateless core. Its HTTP factory can also serve the SDK's compatibility path for older clients. Local stdio uses the same server/tool factory.

The Factorio gateway protocol is independently versioned. A sidecar must reject an unsupported `protocol` before dispatch. Additive result fields are allowed in v1. Removing or changing the meaning/type of a field, operation, or error requires a new gateway protocol version.
