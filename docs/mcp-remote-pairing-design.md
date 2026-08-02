# Remote pairing: a player links their own Claude to the server

Status: IMPLEMENTED, 2026-08-02. Built, deployed and live at `https://sceatorio-mcp.sceat.xyz`.
This file is the single source of truth for the feature; it links to the contracts it depends on
instead of copying them.

**What the service is:** one small HTTPS endpoint, run beside the game server, that turns a
one-time code from the in-game AI Uplink into a bearer credential a player pastes into their own
Claude Code — nothing to install, no server access, no Node, no kubectl.

Scale it is designed for: **a private server, 3–4 friends.** Every decision below picks the
smallest thing that works at that scale, and §6 lists what was deliberately not built.

## 1. What a player does

| # | Step | Detail |
|---|---|---|
| 1 | Build and power an **AI Uplink**, open it | Requires the AI Assistance technology; the GUI is shipped (`src/game/aiGateway.lua` `render_gui`) |
| 2 | Click **Create pairing code** | 15 chars, `XXXXX-XXXX-XXXX`, single use, **5 game-minutes** (`PAIRING_CODE_LIFETIME_TICKS`) |
| 3 | Open `https://sceatorio-mcp.sceat.xyz/`, paste the code, press Pair | One static page served by the companion. This is the only reason the page exists |
| 4 | Copy the finished command the page prints and run it | Shown once — the secret is never stored in plaintext or displayed again |
| 5 | Confirm with `/mcp` in Claude Code | 25 tools appear (`mcp/src/catalog/tools.ts` is the list; do not restate it) |

```
claude mcp add --transport http --scope user sceatorio \
  https://sceatorio-mcp.sceat.xyz/mcp \
  --header "Authorization: Bearer scto_<id>_<secret>"
```

Syntax verified 2026-08-01 against `https://code.claude.com/docs/en/mcp` — the page's own Bearer
example is `claude mcp add --transport http secure-api https://api.example.com/mcp --header
"Authorization: Bearer your-token"`, and it documents `-t`/`-H` short forms plus
`--scope user|project|local`.

**Expiry — there is none.** A pairing is permanent: link once, never again. The mod stamps no
expiry on a binding and the descriptor it returns carries no `expiresTick`, so the grant the
companion derives carries no `expiresAtMs` and nothing can answer `TOKEN_EXPIRED`. Superseded
2026-08-02: the old fixed 24 *game*-hours (`BINDING_LIFETIME_HOURS`) bought nothing that revocation
does not already buy, and cost a relink every day. The code stays finite — 5 game-minutes, single
use — because that is the only thing a leak of it would hand over.

`TOKEN_EXPIRED` survives in the companion's vocabulary for exactly one case: a descriptor from a
mod older than 2.1.x that still sends `expiresTick`. Such grants keep their original lifetime and
are still swept.

**Revoke.** Uplink GUI → the binding row → **Revoke**; it takes effect on the player's next
request, because Lua re-authorizes the live binding on every single call. Also automatic on:
re-pairing (the old binding is revoked), changing force, leaving the game permanently, and the
admin flipping `sceatorio-ai-enabled` off (revokes everyone — the kill switch).

## 2. Decisions (each one line of why)

| Decision | Why |
|---|---|
| Streamable HTTP through the existing Cloudflare Tunnel | The only remote transport Claude Code speaks, and the cluster has no ingress controller — a tunnel route to a ClusterIP Service is the whole exposure story |
| Opaque first-party bearer `scto_<tokenId>_<secret>` (9 + 32 random bytes, `node:crypto`) | We have no authorization server and the player already proved identity in-game; OAuth would be a month of work for four friends |
| **Credentials persist to one file** — `SCEATORIO_CREDENTIAL_STORE`, a JSON array of `{tokenId, sha256(secret), grant}` written 0600 via temp-file + rename | Superseded 2026-08-02: "re-pair after a restart" was priced at one restart a month and the pod restarts several times a day, so the design was buying a relink treadmill for nothing. Only verifiers land on disk — the file is `/etc/shadow`, not a vault: whoever holds it can *check* a bearer, never mint or replay one. Unset the variable and the store is in memory again |
| A missing/empty/malformed store file starts empty and logs, never throws | The failure mode of a bad file is one re-pair; the failure mode of a strict loader is a dead endpoint |
| The bearer is minted by the companion, never derived from the code or `bindingId` | Both come from Factorio's deterministic lockstep RNG and are therefore **not secrets** |
| Pairing page is served by the same process at `/` | Avoids a mod change, avoids teaching players `curl`, and gives the copy button a home |
| No new kill-switch setting | `sceatorio-ai-enabled` already revokes every binding; deleting the tunnel route already kills the endpoint |
| Hostname `sceatorio-mcp.sceat.xyz` (owner's choice, 2026-08-01) | Single-level subdomain on purpose: Cloudflare Universal SSL covers `zone` and `*.zone` but NOT `*.*.zone`, so a two-level name would need paid Advanced Certificate Manager |

## 3. Security

The threat model, capability scoping, and per-request authorization are specified in
[`docs/claude-mcp-architecture-v1.md`](./claude-mcp-architecture-v1.md); shipped public claims live
in [`portal/feature-contract.json`](../portal/feature-contract.json). Not restated here. What this
design adds on top:

| Property | Mechanism |
|---|---|
| The game socket stays private | Factorio's Lua UDP and RCON remain loopback-only; the companion binds the node's **vSwitch** IP, never `0.0.0.0`, so nothing listens on the public node address |
| The credential never reaches the save | Only the pairing *code* crosses UDP — the same claim `scripts/validate.py:397` already asserts, and it stays true |
| Revocation is authoritative in-game | Lua re-checks binding/force/surface/capability per request; a stolen bearer dies the moment the player clicks Revoke |
| No enumeration | One generic error for invalid/expired/consumed codes; 401 makes no distinction between unknown, expired, and revoked tokens; bearers and codes are never logged (log `tokenId` and `playerId` only) |

**Honest ceiling of a stolen bearer.** It can read that one player's force (production, power,
research, logistics, trains, map, circuits, alerts) and it can write exactly three things: toggle
that player's own `sceatorio-ai-output-port` entities (1 change / 5 s, save-wide budget), drop
blueprints into that player's inbox (their cursor only when the call asks for it), and place map
annotations while that player is connected. It cannot move, mine, craft, fight, place entities,
run Lua or RCON, touch another force, exceed the per-player quota, or survive one click of Revoke.
That bounded write surface is why a first-party bearer is proportionate here. Since 2026-08-02 no
clock retires it either — Revoke is the whole cleanup story, which is the price of not relinking
daily, and it is paid in-game where the player can see the binding.

## 4. Does it work on 2.0.7?

**Yes — every required part runs against the shipped 2.0.7 mod with no mod change.** The mod cannot
tell whether the companion was driven by stdio or by HTTP: the companion still sits on the node and
still speaks the same loopback UDP protocol.

| Capability | 2.0.7 | Why |
|---|---|---|
| Code creation + GUI display | Works now | `render_gui` / `ai_create_pairing` shipped |
| `pairing.exchange` over loopback UDP | Works now | `handle_pairing_exchange` (`aiGateway.lua:903`) is transport-blind; `exchangePairingCode` (`mcp/src/pairing.ts`) already speaks it |
| All 25 tools over HTTP | Works now | `createSceatorioMcpHandler({resolveGrant})` (`mcp/src/server.ts:63`) already exists and is unused; `createMcpHandler` verifies no tokens — auth is ours, passed through as `authInfo` |
| Per-request re-authorization, `TOKEN_REVOKED` | Works now | `authorize` in `aiGateway.lua`, checked on every call — this is why a reloaded verifier file cannot resurrect a revoked pairing |
| GUI revoke, re-pair revokes the old binding, force-change/removal revoke | Works now | `aiGateway.lua:978`, `:1374`, `:1403`, `:1566-1576` |
| Per-player + save-wide quotas, capability policy, page caps | Works now | `consume_quota` + the `sceatorio-ai-*` runtime settings |
| **Global failed-pairing limiter** (10 failures / game-minute, `aiGateway.lua:814`) | Works now, **fixed in the companion, not the mod** | Only the companion can reach the UDP socket, so it is the sole gatekeeper: it validates code shape, rate-limits per source IP, and **caps forwarded failures at 5 per minute** — the mod's global counter is then unreachable from the internet. Residual risk: a real player fluffing 5+ codes blocks pairing for the rest of that game-minute. At 3–4 friends, tolerable |
| In-game "your code was just redeemed" notice; per-client failure buckets in Lua | **Needs a mod change** | Nice-to-have polish, deliberately deferred to a later version — neither is required to expose the endpoint safely |

## 5. Implementation

| # | File | Change | Gate |
|---|---|---|---|
| 1 | `mcp/src/http/credentials.ts` (new) | mint / verify (`timingSafeEqual` over SHA-256) / revoke / legacy-expiry sweep, persisted to `SCEATORIO_CREDENTIAL_STORE` when set | unit: verify, wrong secret, unknown id, expired, revoked-then-401, reload keeps verifiers, malformed file starts empty, no plaintext on disk |
| 2 | `mcp/src/http/pair-guard.ts` (new) | per-`CF-Connecting-IP` bucket (5 / 10 min), global shed, hard cap of 5 forwarded failures per minute | unit incl. clock jump; proves the mod's limiter is never reached |
| 3 | `mcp/src/http/node-bridge.ts` (new) | `node:http` ↔ WHATWG `Request`/`Response` with body/time ceilings — first check whether `@modelcontextprotocol/server` already ships an adapter; no new framework dep either way | unit over a real socket |
| 4 | `mcp/src/http/routes.ts` (new) | `GET /` pairing page, `POST /pair`, `GET /healthz`, `/mcp` → `createSceatorioMcpHandler`; bearer → `authInfo` → `resolveGrant`; Host/Origin validation | unit + integration against a fake UDP peer |
| 5 | `mcp/src/http.ts` (new entry), `package.json` bin, `mcp/Dockerfile` (new) | distroless, non-root, `readOnlyRootFilesystem` stays true — the credential store needs exactly one writable path, so it lives on a mounted volume (`SCEATORIO_CREDENTIAL_STORE` points into it) and the root filesystem is untouched | `npm run check`; `docker run` serves `/healthz` |
| 6 | `tests/headless/` | real Factorio + HTTP companion + an MCP client over HTTP, incl. revoke mid-session → `TOKEN_REVOKED` | `tests/headless/run.sh` |
| 7 | `~/dev/kubernetes` (separate commit, devops pass) | enable the `mcp` sidecar, HTTP bind/port, selector-less Service + EndpointSlice, network policy, image digest, and one small writable volume mounted for `SCEATORIO_CREDENTIAL_STORE` (without it every restart still forces a re-pair) | `helmfile template` + `tests/test-chart.sh` extended: bind address is never `0.0.0.0` |
| 8 | `portal/feature-contract.json`, `portal/description.md`, `portal/faq.md` | rewrite the `production-ai-endpoint` claim and its `portal_phrase` in all three (the validator requires the phrase verbatim in the portal copy). **Do not touch** the neighbouring "bearer credentials never enter Factorio UDP or the save" claim — it stays true | `python scripts/validate.py` |
| 9 | `docs/claude-mcp-architecture-v1.md`, `mcp/README.md` | `:115-118,126` — the "unshipped multiplayer target" ships; state that auth is a first-party bearer, not OAuth 2.1, and link back here | `scripts/validate.py` |

Order: 1–6 (companion, self-contained), then 7 (deploy), then 8–9 in the same PR as the deploy, or
the repo ships a lie.

## 6. Deliberately not built

OAuth 2.1 / an authorization server · a *secret* store of any kind (the persisted file holds
SHA-256 verifiers only, and losing it costs one re-pair, so it needs no backup story) · a
path-form credential variant (`/t/<id>/<secret>/mcp`) for header-less clients — Claude Code takes
headers, so Claude Desktop connector support is not worth an extra credential surface at this
scale · companion-side minting of pairing codes · per-tenant machinery beyond the per-request
`resolveGrant` that already exists · a new runtime kill-switch setting · multiple concurrent
bindings per player (re-pairing revokes; one active binding is the simplest revocation story) ·
requiring the Factorio account name at pairing (public info, no entropy, pure friction).

## Appendix — minimum infra facts

- The Factorio pod is `hostNetwork: true`, pinned to node `general-2` (vSwitch `10.0.0.3`). Any
  listener lives in the node's netns: **bind `10.0.0.3:34200`, never `0.0.0.0`** — that bind is the
  real access control. Game UDP 34197 stays public; Lua UDP 34198 and RCON 27015 stay on loopback.
- The `mcp` sidecar has never been deployed (`mcp.enabled: false`, empty image): this is a first
  deploy. Image builds to the in-cluster zot registry and is pinned by digest.
- No ingress controller and no cert-manager exist. Exposure is a **Cloudflare Tunnel** route,
  added manually in the Zero Trust dashboard:
  `sceatorio-mcp.sceat.xyz → http://sceatorio-mcp.sceatorio.svc.cluster.local:80`. TLS is
  Cloudflare's.
- The Service is `ClusterIP`, **selector-less**, with a templated `EndpointSlice` pointing at
  `10.0.0.3:34200` — a hostNetwork pod's endpoint IP would otherwise be the public node IP.
- Blocking deploy checks: `nc -zv <public-node-ip> 34200` **must fail**; `curl
  http://10.0.0.3:34200/healthz` from a debug pod **must succeed** (this proves cloudflared can
  traverse the vSwitch — the single riskiest assumption); `curl https://mcp.…/mcp` with no bearer
  **must return 401**.
- `SCEATORIO_CREDENTIAL_STORE` must be an **absolute** path on a writable, node-local or
  persistent volume; the companion refuses a relative one at startup, creates the parent directory
  if needed, and writes 0600 through a same-directory temp file + `rename`. Unset it and the
  companion logs a warning at boot and behaves exactly as before (memory only).
- Companion concurrency ceiling: the mod's ingress queue is 64 packets, 4 per tick, so the
  companion caps in-flight requests (4 per grant, 32 process-wide) or one client starves the others.
