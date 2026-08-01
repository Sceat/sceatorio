# Headless tests

`matrix.json` is the single source of truth for the pinned Factorio version,
free Linux headless filename/version URL/SHA-256, load profiles, implemented
checks, and planned integration coverage. GitHub Actions reads those values
through `matrix.py headless-env`, verifies the downloaded bytes, and never uses
a `latest` or `experimental` download alias.
It also records the exact versions, portal SHA-1 hashes, licenses, and full
dependency closure for the required external server mod set. External-mod
cases remain marked `blocked-artifacts` until those archives are supplied;
the runner never reads a normal Factorio profile or account token.

The runner never reads or writes the normal Factorio user-data directory. It
copies the current worktree into a `mktemp` mod directory and gives Factorio an
isolated config, mod list, save directory, and server identity.

Run the same time-bounded first-party matrix used by CI and tagged releases:

```sh
sh tests/headless/ci.sh
```

This includes base and Space Age loads, Space Age server startup, the real
security/evolution/offline/robot/planet fixtures, and the Lua UDP/stdio AI E2E.
It deliberately excludes third-party artifact cases.

Run the implemented base and Space Age load checks:

```sh
tests/headless/run.sh smoke all
```

Run a real local multiplayer server startup check:

```sh
tests/headless/run.sh server space-age
```

Run the exact immediate offline-protection stress fixture (10,000 registered
Nauvis walls, including 1,000 with a preexisting false destructible state):

```sh
tests/headless/run.sh mod-fixture base offline-security-performance
```

Run the exact default-cap robot stress fixture (64 fixed networks, 5,500
docked robots, and 1,024 candidate assemblers):

```sh
tests/headless/run.sh mod-fixture base robot-policy-performance
```

Reproduce the longer five-run checkpoint timing used in the audit with:

```sh
FACTORIO_FIXTURE_BENCHMARK_TICKS=3600 \
FACTORIO_FIXTURE_BENCHMARK_RUNS=5 \
  tests/headless/run.sh mod-fixture base robot-policy-performance
```

After downloading the six archives pinned under `external_mod_sets.required-server`
to a dedicated staging directory, exercise that exact closure without exposing an
account token or the normal user-data directory:

```sh
FACTORIO_EXTERNAL_MOD_DIR=/path/to/staged-mods \
  tests/headless/run.sh smoke space-age required-server
FACTORIO_EXTERNAL_MOD_DIR=/path/to/staged-mods \
  tests/headless/run.sh server space-age required-server
```

The runner requires exact `name_version.zip` filenames and verifies every portal
SHA-1 before copying the archives into its disposable mod directory.

Run the repeatable engine benchmark (defaults to 3,600 ticks, three runs):

```sh
tests/headless/run.sh benchmark space-age
```

Set `FACTORIO_BIN` when the executable is outside the detected macOS, Linux,
or `PATH` locations. Successful and failed runs remove their exact isolated
directory by default. To inspect a failure, rerun it with `KEEP_TEST_DATA=1`;
that explicit opt-in retains the directory and prints its path.
Benchmark length can be changed with `FACTORIO_BENCHMARK_TICKS` and
`FACTORIO_BENCHMARK_RUNS`. Mod-fixture checkpoint timing uses the separate
`FACTORIO_FIXTURE_BENCHMARK_TICKS` and `FACTORIO_FIXTURE_BENCHMARK_RUNS`
variables shown above, defaulting to 900 ticks and one run.
