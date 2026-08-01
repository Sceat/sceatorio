local ai = data.raw["bool-setting"]["sceatorio-ai-enabled"]
if ai then ai.default_value = true end

local development = data.raw["bool-setting"]["sceatorio-dev-tools-enabled"]
if development then development.default_value = true end
