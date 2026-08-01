import * as z from "zod/v4";

import { CAPABILITIES } from "../domain/capabilities.js";
import {
  FACTORIO_GATEWAY_PROTOCOL,
  FactorioRequestSchema,
  FactorioResponseSchema,
  MAX_GATEWAY_DATAGRAM_BYTES
} from "../transport/protocol.js";
import { V1_TOOL_DEFINITIONS } from "./tools.js";

const manifest = {
  gateway: {
    protocol: FACTORIO_GATEWAY_PROTOCOL,
    maxDatagramBytes: MAX_GATEWAY_DATAGRAM_BYTES,
    requestSchema: z.toJSONSchema(FactorioRequestSchema),
    responseSchema: z.toJSONSchema(FactorioResponseSchema)
  },
  capabilities: CAPABILITIES,
  tools: V1_TOOL_DEFINITIONS.map((definition) => ({
    name: definition.name,
    operation: definition.operation,
    description: definition.description,
    capability: definition.capability,
    readOnly: definition.readOnly,
    destructive: definition.destructive,
    idempotent: definition.idempotent,
    openWorld: definition.openWorld,
    inputSchema: z.toJSONSchema(definition.inputSchema)
  }))
};

process.stdout.write(`${JSON.stringify(manifest, null, 2)}\n`);
