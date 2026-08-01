local AiConstants = require("src.core.aiConstants")

data:extend({
  {
    type = "bool-setting",
    name = "sceatorio-evolution-enabled",
    setting_type = "runtime-global",
    default_value = true,
    order = "a[evolution]-a[enabled]"
  },
  {
    type = "double-setting",
    name = "sceatorio-evolution-time-per-minute",
    setting_type = "runtime-global",
    default_value = 0.00005,
    minimum_value = 0,
    maximum_value = 1,
    order = "a[evolution]-b[time]"
  },
  {
    type = "double-setting",
    name = "sceatorio-evolution-worm-per-kill",
    setting_type = "runtime-global",
    default_value = 0.001,
    minimum_value = 0,
    maximum_value = 1,
    order = "a[evolution]-c[worm]"
  },
  {
    type = "double-setting",
    name = "sceatorio-evolution-spawner-per-kill",
    setting_type = "runtime-global",
    default_value = 0.007,
    minimum_value = 0,
    maximum_value = 1,
    order = "a[evolution]-d[spawner]"
  },
  {
    type = "double-setting",
    name = "sceatorio-evolution-pollution-per-unit",
    setting_type = "runtime-global",
    default_value = 0.0000009,
    minimum_value = 0,
    maximum_value = 1,
    order = "a[evolution]-e[pollution]"
  },
  {
    type = "string-setting",
    name = "sceatorio-vanilla-evolution-policy",
    setting_type = "runtime-global",
    default_value = "disable",
    allowed_values = {"disable", "preserve"},
    order = "a[evolution]-f[vanilla-policy]"
  },
  {
    type = "bool-setting",
    name = "sceatorio-electricity-isolation",
    setting_type = "runtime-global",
    default_value = true,
    order = "b[security]-a[electricity-isolation]"
  },
  {
    type = "string-setting",
    name = "sceatorio-electricity-sharing-policy",
    setting_type = "runtime-global",
    default_value = "mutual",
    allowed_values = {"mutual", "isolated"},
    order = "b[security]-b[electricity-sharing-policy]"
  },
  {
    type = "int-setting",
    name = "sceatorio-electricity-audit-budget",
    setting_type = "runtime-global",
    default_value = 64,
    minimum_value = 1,
    maximum_value = 1024,
    order = "b[security]-c[electricity-audit-budget]"
  },
  {
    type = "int-setting",
    name = "sceatorio-electricity-migration-chunks-per-audit",
    setting_type = "runtime-global",
    default_value = 2,
    minimum_value = 1,
    maximum_value = 32,
    order = "b[security]-d[electricity-migration]"
  },
  {
    type = "bool-setting",
    name = "sceatorio-offline-defense-enabled",
    setting_type = "runtime-global",
    default_value = true,
    order = "b[security]-e[offline-defense-enabled]"
  },
  {
    type = "bool-setting",
    name = "sceatorio-planet-spawns-enabled",
    setting_type = "runtime-global",
    default_value = true,
    order = "c[planet-spawns]-a[enabled]"
  },
  {
    type = "int-setting",
    name = "sceatorio-planet-spawn-safety-radius",
    setting_type = "runtime-global",
    default_value = 48,
    minimum_value = 16,
    maximum_value = 256,
    order = "c[planet-spawns]-b[safety-radius]"
  },
  {
    type = "int-setting",
    name = "sceatorio-planet-spawn-separation",
    setting_type = "runtime-global",
    default_value = 1024,
    minimum_value = 128,
    maximum_value = 16384,
    order = "c[planet-spawns]-c[separation]"
  },
  {
    type = "string-setting",
    name = "sceatorio-robot-policy-mode",
    setting_type = "runtime-global",
    default_value = "enforce",
    allowed_values = {"disabled", "warn", "enforce"},
    order = "d[robots]-a[mode]"
  },
  {
    type = "int-setting",
    name = "sceatorio-logistic-robot-cap",
    setting_type = "runtime-global",
    default_value = 500,
    minimum_value = 0,
    maximum_value = 1000000,
    order = "d[robots]-b[logistic-cap]"
  },
  {
    type = "int-setting",
    name = "sceatorio-construction-robot-cap",
    setting_type = "runtime-global",
    default_value = 5000,
    minimum_value = 0,
    maximum_value = 1000000,
    order = "d[robots]-c[construction-cap]"
  },
  {
    type = "bool-setting",
    name = "sceatorio-ai-enabled",
    setting_type = "runtime-global",
    default_value = false,
    order = "e[ai]-a[enabled]"
  },
  {
    type = "string-setting",
    name = "sceatorio-ai-allowed-capabilities",
    setting_type = "runtime-global",
    default_value = AiConstants.DEFAULT_CAPABILITIES_CSV,
    order = "e[ai]-b[allowed-capabilities]"
  },
  {
    type = "int-setting",
    name = "sceatorio-ai-requests-per-minute",
    setting_type = "runtime-global",
    default_value = 120,
    minimum_value = 1,
    maximum_value = 3600,
    order = "e[ai]-c[requests-per-minute]"
  },
  {
    type = "int-setting",
    name = "sceatorio-ai-expensive-requests-per-minute",
    setting_type = "runtime-global",
    default_value = 20,
    minimum_value = 1,
    maximum_value = 600,
    order = "e[ai]-d[expensive-requests-per-minute]"
  },
  {
    type = "int-setting",
    name = "sceatorio-ai-global-requests-per-minute",
    setting_type = "runtime-global",
    default_value = 600,
    minimum_value = 1,
    maximum_value = 36000,
    order = "e[ai]-e[global-requests-per-minute]"
  },
  {
    type = "int-setting",
    name = "sceatorio-ai-global-expensive-requests-per-minute",
    setting_type = "runtime-global",
    default_value = 120,
    minimum_value = 1,
    maximum_value = 36000,
    order = "e[ai]-f[global-expensive-requests-per-minute]"
  },
  {
    type = "int-setting",
    name = "sceatorio-ai-binding-lifetime-hours",
    setting_type = "runtime-global",
    default_value = 24,
    minimum_value = 1,
    maximum_value = 720,
    order = "e[ai]-g[binding-lifetime]"
  },
  {
    type = "int-setting",
    name = "sceatorio-ai-max-page-size",
    setting_type = "runtime-global",
    default_value = 100,
    minimum_value = 1,
    maximum_value = 200,
    order = "e[ai]-h[max-page-size]"
  },
  {
    type = "bool-setting",
    name = "sceatorio-ai-assistance-enabled",
    setting_type = "runtime-per-user",
    default_value = false,
    order = "e[ai]-i[player-enabled]"
  },
  {
    type = "string-setting",
    name = "sceatorio-ai-requested-capabilities",
    setting_type = "runtime-per-user",
    default_value = AiConstants.DEFAULT_CAPABILITIES_CSV,
    order = "e[ai]-j[player-capabilities]"
  },
  {
    type = "bool-setting",
    name = "sceatorio-ai-blueprint-cursor-delivery",
    setting_type = "runtime-per-user",
    default_value = false,
    order = "e[ai]-k[cursor-delivery]"
  },
  {
    type = "bool-setting",
    name = "sceatorio-dev-tools-enabled",
    setting_type = "runtime-global",
    default_value = false,
    order = "z[development]-a[enabled]"
  }
})
