local setting = data.raw["bool-setting"]["sceatorio-dev-tools-enabled"]
if setting then setting.default_value = true end

local safety = data.raw["int-setting"]["sceatorio-planet-spawn-safety-radius"]
if safety then safety.default_value = 16 end

local separation = data.raw["int-setting"]["sceatorio-planet-spawn-separation"]
if separation then separation.default_value = 128 end
