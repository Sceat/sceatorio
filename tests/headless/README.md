# Headless tests

`matrix.json` is the single source of truth for the pinned Factorio version,
load profiles, implemented checks, and planned integration coverage.
It also records the exact versions, portal SHA-1 hashes, licenses, and full
dependency closure for the required external server mod set. External-mod
cases remain marked `blocked-artifacts` until those archives are supplied;
the runner never reads a normal Factorio profile or account token.

The runner never reads or writes the normal Factorio user-data directory. It
copies the current worktree into a `mktemp` mod directory and gives Factorio an
isolated config, mod list, save directory, and server identity.

Run the implemented base and Space Age load checks:

```sh
tests/headless/run.sh smoke all
```

Run a real local multiplayer server startup check:

```sh
tests/headless/run.sh server space-age
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
or `PATH` locations. Set `KEEP_TEST_DATA=1` to retain the isolated directory.
Benchmark length can be changed with `FACTORIO_BENCHMARK_TICKS` and
`FACTORIO_BENCHMARK_RUNS`.
