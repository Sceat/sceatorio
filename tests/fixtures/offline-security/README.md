# Offline security runtime fixture

This disposable test mod enables Sceatorio's otherwise production-off developer
interface for a fresh map. It registers one explicit team, builds two real
Factorio 2.1.12 walls, and verifies normal damage, offline invulnerability,
exact restoration, and a preexisting `destructible = false` value.

The harness then reloads the generated save. This covers the server-restart case
where no leave event was persisted: Sceatorio must reconcile the zero-player
force on the first simulation tick and protect both registered assets before the
fixture checks damage again.
