local policy = data.raw["string-setting"]["sceatorio-robot-policy-mode"]
if policy then policy.default_value = "enforce" end

local logistic = data.raw["int-setting"]["sceatorio-logistic-robot-cap"]
if logistic then logistic.default_value = 500 end

local construction = data.raw["int-setting"]["sceatorio-construction-robot-cap"]
if construction then construction.default_value = 5000 end
