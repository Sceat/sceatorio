# Contributing

Thanks for improving Sceatorio. Keep changes reviewable, deterministic, and honest about what a multiplayer server can protect.

## Before a pull request

1. Base gameplay work on Factorio 2.1.12's official runtime/prototype API. Do not infer 2.1 behavior from a 1.1 example.
2. Keep canonical state under `storage.sceatorio`; avoid parallel caches or documentation that can silently drift.
3. Add a focused fast test for bug fixes. Multiplayer isolation changes also need a real two-force headless or client test plan.
4. Update the top `changelog.txt` entry for user-visible behavior.
5. If settings change, update their locale and run `python3 scripts/sync_docs.py --write`. Do not hand-edit generated `docs/settings.md`.
6. If public behavior changes, update `portal/feature-contract.json`, its evidence, and regenerate `docs/features.md`. Portal and README claims must remain within that contract.
7. Do not commit saves, account tokens, RCON passwords, portal API keys, OAuth credentials, generated build output, or a normal Factorio user-data directory.

Run the required checks from the repository root:

```sh
sh tests/run.sh
python3 scripts/sync_docs.py --check
python3 scripts/validate.py

cd mcp
npm ci
npm run check
```

If Factorio 2.1.12 is installed, also run:

```sh
tests/headless/run.sh smoke all
tests/headless/run.sh server space-age
```

For packaging changes, build twice and compare hashes. The CI workflow performs the same check using the explicit allowlist in `scripts/release-manifest.json`.

## Design expectations

- Bound recurring work; never add an unbudgeted full-surface or full-entity scan to a tick event.
- Scope team state by stable team ID and surface index. Space platforms and remote view need deliberate handling.
- Prefer event-driven accounting and deterministic iteration/state transitions suitable for multiplayer lockstep.
- Offline protection must snapshot only tracked team-owned entities when the last human leaves and restore every exact prior `destructible` value when the first returns. Keep registration event-driven; do not add a retrofit world scan.
- Player/robot rejection needs exact refunds and bounded warnings. Script-created entities require compatibility-aware behavior.
- AI tools remain low-level, capability-scoped, force/surface-scoped, and off by default. Do not add arbitrary Lua/RCON or autonomous character control.

Third-party code or assets require an identified source, compatible license, and preserved notice. Generated assets require actual provenance and must never be presented as gameplay screenshots.
