# Security runtime fixture

This Factorio scenario is a black-box check against the production mod. It first
proves that empty third-party forces are ignored—even when one occupies an
internal-looking name—explicitly registers two teams through
`sceatorio_teams.register_force`, and verifies the paired-enemy relation matrix
without changing human-team diplomacy. It charts a fixture area and registers a
third team, executing production chart-copy reconciliation while proving that the
bulk copy cannot recursively enter the incremental queue. Production intentionally
exposes no remote map-reveal test helper.

Factorio 2.1.12 does not emit `on_chunk_charted` for `LuaForce.chart` or a powered
radar belonging to a playerless force, so the native player/radar event source
still needs a connected-client fixture. In particular, these deliberately
playerless fixture forces do not establish visible chart data through
`LuaForce.chart`, so this test does not pretend it can prove visible fanout. The
narrow `sceatorio_radars.share_chunk` mod-interoperability wrapper does let the
fixture fill the real 4,096-chunk queue, exercise bounded generated-chunk
reconciliation, saturate the queue again during an active pass, and prove the
versioned retry completes before the surface job retires. No engine event is
fabricated.

Finally, it registers two substations through `script_raised_built` and adds a
manual cross-team copper wire after placement. It also emulates Cargo Oil Rig's
composite build shape: a visible powered parent raises its build event, remains
safe for the creating script to access, and is then joined by an unannounced
same-force pole that supplies a pre-existing foreign consumer. The bounded
next-tick audit removes the silent pole and rejects the parent while preserving
the foreign team's entity.
After the wire audit, it merges two registered human forces and asserts that the
source team and its paired enemy both disappear, the destination registration
remains idempotent, and the enemy isolation matrix is rebuilt. It then waits for
the bounded propagation queue, versioned surface catch-up, and suppression
counters to drain to zero without an event storm.
After the production 30-tick audit it emits:

```text
SCEATORIO_SECURITY_PASS: force isolation, chart sync, and wire audit passed
```

Script-raised conflicts are destroyed only after their creator resumes, avoiding
an invalid-LuaEntity crash inside another mod's build callback. Player and robot
placements take the strict reject-and-refund path; the exact temporary inventory
capture remains a real-client/robot fixture boundary.

The generic isolated Factorio runner lives under `tests/headless`; this fixture
contains no account token, user-data path, or machine-specific configuration.
