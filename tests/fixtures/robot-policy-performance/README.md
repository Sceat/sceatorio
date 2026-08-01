# Robot policy performance fixture

This synthetic, deterministic Factorio 2.1.12 workload creates 64 separate
fixed roboport networks, puts 499 logistic and 4,999 construction robots in
their engine inventories, and registers 1,024 vanilla assembling machines.
Of those machines, 256 make logistic robots, 256 make construction robots, and
512 use a non-robot recipe while remaining legitimate candidates for later
manual recipe changes.

The fixture repeatedly adds the final robot of each class to exercise the
real default 500/5,000 thresholds, measures first/all stop and resume latency,
checks that the unrelated 512 assemblers never pause, and reloads an enforced
checkpoint. It logs both deterministic operation counts and a Factorio
`LuaProfiler` wall-time sample. The profiler includes the fixture verifier and
engine work during each transition; the separate checkpoint benchmark is the
repeatable steady-state update measurement.

This is intentionally a synthetic policy workload. Robots remain docked in
unpowered, disconnected roboports, so it is not evidence about pathfinding,
charging congestion, active logistic jobs, or a real megabase.

Run it with:

```sh
tests/headless/run.sh mod-fixture base robot-policy-performance
```
