local AI_ASSISTANCE_ICON = "__Sceatorio__/graphics/technology/ai-assistance.png"
local AI_ASSISTANCE_ICON_SIZE = 256

local uplink = table.deepcopy(data.raw.radar["radar"])
uplink.name = "sceatorio-ai-uplink"
uplink.localised_name = {"entity-name.sceatorio-ai-uplink"}
uplink.localised_description = {"entity-description.sceatorio-ai-uplink"}
uplink.icon = AI_ASSISTANCE_ICON
uplink.icon_size = AI_ASSISTANCE_ICON_SIZE
uplink.icons = nil
uplink.minable = {mining_time = 0.5, result = "sceatorio-ai-uplink"}
uplink.fast_replaceable_group = nil
uplink.next_upgrade = nil
uplink.energy_usage = "500kW"
uplink.energy_per_sector = "1TJ"
uplink.energy_per_nearby_scan = "1TJ"
uplink.max_distance_of_sector_revealed = 0
uplink.max_distance_of_nearby_sector_revealed = 0
uplink.connects_to_other_radars = false
uplink.allow_copy_paste = false
uplink.radius_minimap_visualisation_color = {0.45, 0.18, 0.72, 0.35}

local uplink_item = table.deepcopy(data.raw.item["radar"])
uplink_item.name = "sceatorio-ai-uplink"
uplink_item.localised_name = {"entity-name.sceatorio-ai-uplink"}
uplink_item.localised_description = {"entity-description.sceatorio-ai-uplink"}
uplink_item.icon = AI_ASSISTANCE_ICON
uplink_item.icon_size = AI_ASSISTANCE_ICON_SIZE
uplink_item.icons = nil
uplink_item.place_result = "sceatorio-ai-uplink"
uplink_item.order = "d[radar]-b[ai-uplink]"
uplink_item.stack_size = 10

local uplink_recipe = {
  type = "recipe",
  name = "sceatorio-ai-uplink",
  localised_name = {"entity-name.sceatorio-ai-uplink"},
  icon = AI_ASSISTANCE_ICON,
  icon_size = AI_ASSISTANCE_ICON_SIZE,
  enabled = false,
  energy_required = 10,
  ingredients = {
    {type = "item", name = "electronic-circuit", amount = 20},
    {type = "item", name = "iron-plate", amount = 30},
    {type = "item", name = "copper-cable", amount = 20}
  },
  results = {
    {type = "item", name = "sceatorio-ai-uplink", amount = 1}
  }
}

local function circuit_port(name, order, allow_copy_paste)
  local entity = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
  entity.name = name
  entity.localised_name = {"entity-name." .. name}
  entity.localised_description = {"entity-description." .. name}
  entity.minable = {mining_time = 0.2, result = name}
  entity.fast_replaceable_group = nil
  entity.next_upgrade = nil
  entity.allow_copy_paste = allow_copy_paste

  local item = table.deepcopy(data.raw.item["constant-combinator"])
  item.name = name
  item.localised_name = {"entity-name." .. name}
  item.localised_description = {"entity-description." .. name}
  item.place_result = name
  item.order = order

  local recipe = {
    type = "recipe",
    name = name,
    localised_name = {"entity-name." .. name},
    enabled = false,
    energy_required = 2,
    ingredients = {
      {type = "item", name = "electronic-circuit", amount = 5},
      {type = "item", name = "copper-cable", amount = 5},
      {type = "item", name = "iron-plate", amount = 5}
    },
    results = {{type = "item", name = name, amount = 1}}
  }
  return entity, item, recipe
end

local input_port, input_port_item, input_port_recipe = circuit_port(
  "sceatorio-ai-input-port",
  "c[combinators]-z[ai]-a[input]",
  true
)
local output_port, output_port_item, output_port_recipe = circuit_port(
  "sceatorio-ai-output-port",
  "c[combinators]-z[ai]-b[output]",
  false
)

local assistance = {
  type = "technology",
  name = "sceatorio-ai-assistance",
  localised_name = {"technology-name.sceatorio-ai-assistance"},
  localised_description = {"technology-description.sceatorio-ai-assistance"},
  icon = AI_ASSISTANCE_ICON,
  icon_size = AI_ASSISTANCE_ICON_SIZE,
  prerequisites = {"radar"},
  effects = {
    {type = "unlock-recipe", recipe = "sceatorio-ai-uplink"},
    {type = "unlock-recipe", recipe = "sceatorio-ai-input-port"},
    {type = "unlock-recipe", recipe = "sceatorio-ai-output-port"}
  },
  unit = {
    count = 100,
    ingredients = {
      {"automation-science-pack", 1}
    },
    time = 15
  },
  order = "a-b-d[sceatorio-ai-assistance]"
}

data:extend({
  uplink,
  uplink_item,
  uplink_recipe,
  input_port,
  input_port_item,
  input_port_recipe,
  output_port,
  output_port_item,
  output_port_recipe,
  assistance
})
