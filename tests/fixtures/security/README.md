# Security runtime fixture

This Factorio scenario is a black-box check against the production mod. It first
proves that empty third-party forces are ignored—even when one occupies an
internal-looking name—explicitly registers two teams through
`sceatorio_teams.register_force`, and verifies the paired-enemy relation matrix
without changing human-team diplomacy. The narrow
`sceatorio_radars.share_chunk` interoperability wrapper rejects both an
ungenerated chunk and a generated chunk that the source team has not charted.
It also proves that rejecting the far fixture chunk does not generate it. The
separate chart-engine fixture owns the positive player/radar sharing path. No
engine event is fabricated and there is no map-wide queue or catch-up path.

Finally, it registers two substations through `script_raised_built` and adds a
manual cross-team copper wire after placement. It also emulates Cargo Oil Rig's
composite build shape: a visible powered parent raises its build event, remains
safe for the creating script to access, and is then joined by an unannounced
same-force pole that supplies a pre-existing foreign consumer. The bounded
next-tick audit removes the silent pole and rejects the parent while preserving
the foreign team's entity.
After the wire audit, it merges two registered human forces and asserts that the
source team and its paired enemy both disappear, the destination registration
remains idempotent, and the enemy isolation matrix is rebuilt.
After the production 30-tick audit it emits:

```text
SCEATORIO_SECURITY_PASS: force isolation, generated-only chart rejection, force merge, and wire audit passed
```

Script-raised conflicts are destroyed only after their creator resumes, avoiding
an invalid-LuaEntity crash inside another mod's build callback. Player and robot
placements take the strict reject-and-refund path; the exact temporary inventory
capture remains a real-client/robot fixture boundary.

The generic isolated Factorio runner lives under `tests/headless`; this fixture
contains no account token, user-data path, or machine-specific configuration.
