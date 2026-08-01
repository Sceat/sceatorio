# Offline-security transition performance fixture

This synthetic, deterministic Factorio 2.1.12 workload registers 10,000 real
vanilla stone walls on Nauvis for one explicit team. Nine thousand begin with
the ordinary `destructible = true` state and one thousand deliberately begin
false. The fixture profiles immediate protect/unprotect calls, then checks all
10,000 entities synchronously after each call. Unprotect must restore every
entity's exact prior boolean rather than making the preexisting false subset
destructible.

The measured call uses the production-disabled development interface without
requesting its separate registry-status report. This isolates the actual
in-place force-bucket transition; a static contract additionally rejects an
O(N) registration snapshot inside that traversal. A protected checkpoint is
then loaded by a second Factorio process, and both exact restoration and
re-protection are profiled and verified again.

This is a dense wall grid on generated, paved Nauvis terrain. It exercises
registry traversal and `destructible` writes, not a representative mixed
factory, combat load, player join latency over a network, or a megabase UPS
comparison. Profiler results depend on the host and current engine build.

Run it with:

```sh
tests/headless/run.sh mod-fixture base offline-security-performance
```
