# CLAUDE.md

Guidance for AI agents (and humans) working on Sceatorio. Read this before
touching code; CONTRIBUTING.md and SECURITY.md still apply.

## What this is

Sceatorio is a Factorio 2.1.12 mod (Space Age optional) for friendly persistent
multiplayer **without a shared economy**: each team keeps its own force, spawn,
research, evolution, electricity, and buildings, while chat, discovery, and
notices are shared. It ships with an optional, default-off AI Assistance
feature: an in-game Uplink plus a local TypeScript MCP companion exposing 24
read-mostly, capability-scoped tools over loopback UDP.

## Layout

| Path | Purpose |
|---|---|
| `control.lua`, `settings.lua`, `data.lua` | Mod entry points; `control.lua` wires events to `src/` |
| `src/core/` | `state.lua` (canonical save state), `aiConstants.lua` |
| `src/game/` | One module per feature: `teams`, `spawns`, `planetSpawns`, `evo`/`evolution_math`, `radars` (chart sharing), `security` (electricity), `offlineSecurity`, `robotPolicy`, `playerList`, `chat`, `ai*` (gateway/ops/events/blueprints/telemetry) |
| `mcp/` | TypeScript stdio MCP companion (`mcp/src/catalog/tools.ts` is the tool catalog authority) |
| `portal/` | Mod Portal presentation + `feature-contract.json` (public behavior contract) |
| `scripts/` | `package.py` (deterministic ZIP), `validate.py`, `sync_docs.py`, release tooling |
| `tests/unit/` | Fast Python static-contract tests (no Factorio needed) |
| `tests/fixtures/` + `tests/headless/` | Real Factorio 2.1.12 engine cases, driven by `tests/headless/matrix.json` |
| `tests/e2e/` | Real UDP/stdio MCP end-to-end client |

## Source-of-truth map (never duplicate these elsewhere)

| Concern | Authority |
|---|---|
| Runtime behavior | `control.lua`, `settings.lua`, `src/` |
| Canonical runtime state | `storage.sceatorio` via `src/core/state.lua` — no parallel caches |
| Shipped features/limitations | `portal/feature-contract.json` |
| Feature/settings docs | Generated `docs/features.md` / `docs/settings.md` via `scripts/sync_docs.py --write` — never hand-edit |
| Package contents | `scripts/release-manifest.json` (strict allowlist) |
| Engine test matrix | `tests/headless/matrix.json` (exact Factorio version + SHA-256; never a `latest` alias) |
| MCP tools/schemas | `mcp/src/catalog/tools.ts`, `mcp/src/catalog/schemas.ts` |
| MCP security architecture | `docs/claude-mcp-architecture-v1.md` |
| Headless evidence/limits | `tests/headless/AUDIT.md` |

## Hard invariants (violating any of these is a rejected change)

- **Forces stay separate.** Discovery/chat sharing must never create cease-fire,
  friendship, container access, shared electricity, or a union force.
- **Bounded work only.** No unbudgeted full-surface/full-entity scans in tick
  handlers; recurring work is budgeted, round-robin, and deterministic for
  multiplayer lockstep.
- **Chart sharing never generates terrain.** Every chart write is preceded by
  `surface.is_chunk_generated`; no `request_to_generate_chunks`; remote
  `share_chunk` accepts only one bounded integer chunk already generated and
  charted by the registered source force.
- **Offline protection restores exact prior `destructible` values** —
  event-driven registration, no retrofit world scan, no grace timer.
- **Exact refunds.** Placement rejection refunds the quality-aware item; nothing
  is deleted, moved, or hidden (robot policy pauses producers only).
- **AI/MCP fails closed.** Capability ∩ grant ∩ global policy ∩ force/surface
  scope ∩ quotas rechecked per request; no character control, no arbitrary
  Lua/RCON, no entity placement; writes limited to the output port, private
  blueprint inbox, and private annotations. All transports loopback-only.
  Secrets never enter the save, UDP payloads, blueprints, or mod settings.
- **This repo is public.** No tokens, credentials, saves, or private operator
  data in tracked files. `session.md` is gitignored on purpose.

## Verification (run from repo root; all must pass before any commit)

```sh
sh tests/run.sh                      # 128+ fast static tests
python3 scripts/sync_docs.py --check # generated docs not drifted
python3 scripts/validate.py          # release metadata/contracts/assets
git diff --check                     # whitespace
cd mcp && npm ci && npm run check    # MCP typecheck/tests (when touching mcp/)
```

With a local Factorio 2.1.12 (any exact 2.1.12 binary; harness never touches
your real user-data dir):

```sh
sh tests/headless/run.sh smoke all
sh tests/headless/run.sh fixture base chart-engine   # or another fixture filter
sh tests/headless/run.sh mod-fixture base all
sh tests/headless/run.sh ai-e2e base                 # real UDP/stdio MCP path
sh tests/headless/ci.sh                              # full matrix (CI parity)
```

Bug fixes need a focused fast test; multiplayer-isolation changes also need a
real two-force headless case or a written client test plan.

## Release law

1. Update the top `changelog.txt` entry; bump `info.json`; keep
   `portal/feature-contract.json` and generated docs in sync.
2. `python3 scripts/package.py --output dist` twice → identical bytes.
3. Release happens ONLY via the tagged GitHub Actions workflow (`vX.Y.Z` tag on
   the default branch). It verifies the pinned headless hash, runs the full
   matrix, uploads to the Mod Portal v2 API, and cross-checks public SHA-1 and
   GitHub Release bytes. Never upload ad hoc bytes.
4. Publishing ≠ deploying. The dedicated server lives in the separate
   `Sceat/kubernetes` repo (`domains/sceatorio/`), is pinned by exact ZIP +
   SHA-1 in `mod-lock.yaml`, and is deployed manually through Helmfile with an
   owner-approved maintenance window. A git push or tag never restarts it.

## Working notes

- Target the official Factorio 2.1.12 runtime API; never infer 2.1 behavior
  from 1.1 examples. `factorio-current.log` truth beats assumption: verify API
  fields exist before writing to them (see the `LuaStyle` crash history in
  `changelog.txt`).
- The Mod Portal ZIP is Factorio-only; `mcp/` stays out of the package
  (allowlist-enforced) so joining clients never download Node.js code.
- `scripts/install-local.sh <mods-dir>` builds and installs the exact ZIP
  locally; it refuses same-version overwrite without `--replace`.
- Dev/test tooling (`testMenu.lua`, planet exercises, research-all) must stay
  production-disabled.
