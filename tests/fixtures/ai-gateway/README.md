# AI gateway runtime fixture

This dependent test mod enables the otherwise default-off AI gateway and
administrator development hooks in an isolated Factorio 2.1.12 data directory.
The E2E runner obtains a one-time code over RCON, exchanges it over real Lua UDP,
and then exercises the scoped gateway and stdio MCP server. It is never part of
a release archive.
