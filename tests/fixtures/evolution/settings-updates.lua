local time = data.raw["double-setting"]["sceatorio-evolution-time-per-minute"]
if time then time.default_value = 0.5 end

local worm = data.raw["double-setting"]["sceatorio-evolution-worm-per-kill"]
if worm then worm.default_value = 0.1 end

local spawner = data.raw["double-setting"]["sceatorio-evolution-spawner-per-kill"]
if spawner then spawner.default_value = 0.3 end

local pollution = data.raw["double-setting"]["sceatorio-evolution-pollution-per-unit"]
if pollution then pollution.default_value = 0.002 end

local development = data.raw["bool-setting"]["sceatorio-dev-tools-enabled"]
if development then development.default_value = true end
