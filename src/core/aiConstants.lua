local Constants = {}

Constants.PROTOCOL = "sceatorio.factorio-gateway/1"
Constants.MAX_DATAGRAM_BYTES = 48 * 1024
Constants.TECHNOLOGY = "sceatorio-ai-assistance"
Constants.UPLINK = "sceatorio-ai-uplink"
Constants.INPUT_PORT = "sceatorio-ai-input-port"
Constants.OUTPUT_PORT = "sceatorio-ai-output-port"

Constants.CAPABILITIES = {
  "session:read",
  "production:read",
  "electricity:read",
  "research:read",
  "prototypes:read",
  "factory:read",
  "logistics:read",
  "trains:read",
  "alerts:read",
  "map:read",
  "circuits:read",
  "events:read",
  "blueprints:validate",
  "blueprints:write",
  "control_ports:write",
  "annotations:write"
}

Constants.CAPABILITY_SET = {}
for _, capability in ipairs(Constants.CAPABILITIES) do
  Constants.CAPABILITY_SET[capability] = true
end

Constants.DEFAULT_CAPABILITIES_CSV = table.concat(Constants.CAPABILITIES, ",")

return Constants
