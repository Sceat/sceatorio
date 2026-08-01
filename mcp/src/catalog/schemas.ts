import * as z from "zod/v4";

const IdentifierSchema = z.string().trim().min(1).max(200);
const SurfaceIdSchema = z.string().trim().min(1).max(128);
const CursorSchema = z.string().min(1).max(512);

export const PositionSchema = z.object({
  x: z.number().finite(),
  y: z.number().finite()
}).strict();

export const AreaSchema = z.object({
  leftTop: PositionSchema,
  rightBottom: PositionSchema
}).strict().superRefine((area, context) => {
  const width = area.rightBottom.x - area.leftTop.x;
  const height = area.rightBottom.y - area.leftTop.y;
  if (width <= 0 || height <= 0) {
    context.addIssue({
      code: "custom",
      message: "rightBottom must be below and to the right of leftTop"
    });
  }
  if (width > 1_024 || height > 1_024) {
    context.addIssue({
      code: "custom",
      message: "A single query may cover at most 1024 by 1024 tiles"
    });
  }
});

export const PaginationSchema = z.object({
  cursor: CursorSchema.optional(),
  limit: z.number().int().min(1).max(200).default(100)
}).strict();

export const EmptyInputSchema = z.object({}).strict();

export const GetProductionInputSchema = z.object({
  surfaceId: SurfaceIdSchema.optional(),
  statistic: z.enum(["item", "fluid", "kill", "build"]),
  names: z.array(IdentifierSchema).max(100).optional(),
  direction: z.enum(["input", "output", "both"]).default("both"),
  window: z.enum(["5s", "1m", "10m", "1h", "10h", "50h", "250h", "total"]),
  pagination: PaginationSchema.optional()
}).strict();

export const GetElectricNetworkInputSchema = z.object({
  surfaceId: SurfaceIdSchema,
  networkId: IdentifierSchema.optional(),
  anchorEntityId: IdentifierSchema,
  pagination: PaginationSchema.optional()
}).strict();

export const GetResearchInputSchema = z.object({
  includeCompleted: z.boolean().default(false),
  pagination: PaginationSchema.optional()
}).strict();

export const GetRecipeInputSchema = z.object({
  name: IdentifierSchema,
  quality: IdentifierSchema.optional()
}).strict();

export const GetPrototypeInputSchema = z.object({
  type: z.enum([
    "entity",
    "item",
    "fluid",
    "recipe",
    "technology",
    "tile",
    "quality"
  ]),
  name: IdentifierSchema
}).strict();

export const GetTransportCapacitiesInputSchema = z.object({
  quality: IdentifierSchema.optional(),
  includeLocked: z.boolean().default(false),
  pagination: PaginationSchema.optional()
}).strict();

export const GetUnlockedTechnologiesInputSchema = z.object({
  pagination: PaginationSchema.optional()
}).strict();

export const QueryEntitiesInputSchema = z.object({
  surfaceId: SurfaceIdSchema,
  area: AreaSchema,
  names: z.array(IdentifierSchema).max(100).optional(),
  types: z.array(IdentifierSchema).max(50).optional(),
  statuses: z.array(IdentifierSchema).max(50).optional(),
  pagination: PaginationSchema.optional()
}).strict();

export const InspectEntityInputSchema = z.object({
  surfaceId: SurfaceIdSchema,
  entityId: IdentifierSchema
}).strict();

export const GetLogisticNetworkInputSchema = z.object({
  surfaceId: SurfaceIdSchema,
  networkId: IdentifierSchema.optional(),
  anchorPosition: PositionSchema.optional(),
  includeContents: z.boolean().default(true),
  pagination: PaginationSchema.optional()
}).strict().superRefine((input, context) => {
  if (input.networkId === undefined && input.anchorPosition === undefined) {
    context.addIssue({
      code: "custom",
      message: "networkId or anchorPosition is required"
    });
  }
});

export const GetTrainsInputSchema = z.object({
  surfaceId: SurfaceIdSchema.optional(),
  states: z.array(IdentifierSchema).max(30).optional(),
  stationName: z.string().trim().min(1).max(200).optional(),
  pagination: PaginationSchema.optional()
}).strict();

export const GetAlertsInputSchema = z.object({
  surfaceId: SurfaceIdSchema.optional(),
  sinceTick: z.number().int().nonnegative().optional(),
  types: z.array(IdentifierSchema).max(50).optional(),
  pagination: PaginationSchema.optional()
}).strict();

export const GetChartedChunksInputSchema = z.object({
  surfaceId: SurfaceIdSchema,
  area: AreaSchema,
  includeKnownResources: z.boolean().default(true),
  includeVisibleEnemies: z.boolean().default(false),
  pagination: PaginationSchema.optional()
}).strict();

export const ReadCircuitPortInputSchema = z.object({
  surfaceId: SurfaceIdSchema,
  portId: IdentifierSchema
}).strict();

export const GetEventsInputSchema = z.object({
  cursor: CursorSchema.optional(),
  types: z.array(IdentifierSchema).max(50).optional(),
  limit: z.number().int().min(1).max(200).default(100)
}).strict();

export const WaitForEventsInputSchema = z.object({
  cursor: CursorSchema.optional(),
  types: z.array(IdentifierSchema).max(50).optional(),
  timeoutMs: z.number().int().min(100).max(25_000).default(10_000),
  limit: z.number().int().min(1).max(200).default(100)
}).strict();

export type JsonValue = null | boolean | number | string | JsonValue[] | {
  [key: string]: JsonValue;
};

export const JsonValueSchema: z.ZodType<JsonValue> = z.lazy(() =>
  z.union([
    z.null(),
    z.boolean(),
    z.number().finite(),
    z.string().max(4_096),
    z.array(JsonValueSchema).max(256),
    z.record(z.string().min(1).max(128), JsonValueSchema)
  ])
);

export const BlueprintConnectionSchema = z.object({
  fromConnectorId: z.number().int().min(0).max(8).optional(),
  toEntityNumber: z.number().int().positive(),
  toConnectorId: z.number().int().min(0).max(8).optional(),
  wire: z.enum(["red", "green", "copper"])
}).strict();

export const BlueprintEntitySchema = z.object({
  entityNumber: z.number().int().positive(),
  prototype: IdentifierSchema,
  position: PositionSchema,
  direction: z.number().int().min(0).max(15).optional(),
  quality: IdentifierSchema.optional(),
  recipe: IdentifierSchema.optional(),
  items: z.record(IdentifierSchema, z.number().int().positive()).optional(),
  connections: z.array(BlueprintConnectionSchema).max(64).optional(),
  settings: z.record(z.string().min(1).max(128), JsonValueSchema).optional()
}).strict();

export const BlueprintTileSchema = z.object({
  prototype: IdentifierSchema,
  position: PositionSchema
}).strict();

export const BlueprintExpectedOutputSchema = z.object({
  type: z.enum(["item", "fluid"]),
  name: IdentifierSchema,
  perSecond: z.number().positive().finite()
}).strict();

export const BlueprintLayoutSchema = z.object({
  name: z.string().trim().min(1).max(100),
  description: z.string().trim().max(1_000).default(""),
  entities: z.array(BlueprintEntitySchema).min(1).max(512),
  tiles: z.array(BlueprintTileSchema).max(2_048).default([]),
  expectedOutputs: z.array(BlueprintExpectedOutputSchema).max(32).default([])
}).strict().superRefine((layout, context) => {
  const numbers = new Set<number>();
  for (const [index, entity] of layout.entities.entries()) {
    if (numbers.has(entity.entityNumber)) {
      context.addIssue({
        code: "custom",
        path: ["entities", index, "entityNumber"],
        message: "entityNumber values must be unique"
      });
    }
    numbers.add(entity.entityNumber);
  }
  for (const [entityIndex, entity] of layout.entities.entries()) {
    for (const [connectionIndex, connection] of (entity.connections ?? []).entries()) {
      if (!numbers.has(connection.toEntityNumber)) {
        context.addIssue({
          code: "custom",
          path: ["entities", entityIndex, "connections", connectionIndex, "toEntityNumber"],
          message: "Connection references an entityNumber that is not in this layout"
        });
      }
    }
  }
});

export const ValidateBlueprintInputSchema = z.object({
  layout: BlueprintLayoutSchema,
  surfaceId: SurfaceIdSchema.optional(),
  placementOrigin: PositionSchema.optional()
}).strict();

export const AnalyzeBlueprintInputSchema = z.object({
  layout: BlueprintLayoutSchema
}).strict();

export const SaveBlueprintInputSchema = z.object({
  layout: BlueprintLayoutSchema,
  delivery: z.enum(["inbox", "cursor"]).default("inbox")
}).strict();

export const ListAiBlueprintsInputSchema = z.object({
  query: z.string().trim().max(200).optional(),
  pagination: PaginationSchema.optional()
}).strict();

export const LoadAiBlueprintInputSchema = z.object({
  blueprintId: IdentifierSchema,
  revision: z.number().int().positive().optional(),
  delivery: z.enum(["inbox", "cursor"]).default("inbox")
}).strict();

export const CircuitSignalSchema = z.object({
  type: z.enum(["item", "fluid", "virtual"]),
  name: IdentifierSchema,
  quality: IdentifierSchema.optional(),
  value: z.number().int().min(-2_147_483_648).max(2_147_483_647)
}).strict();

export const WriteControlPortInputSchema = z.object({
  surfaceId: SurfaceIdSchema,
  portId: IdentifierSchema,
  signals: z.array(CircuitSignalSchema).max(32),
  ttlSeconds: z.number().int().min(5).max(3_600).default(30)
}).strict();

export const AddMapAnnotationInputSchema = z.object({
  surfaceId: SurfaceIdSchema,
  position: PositionSchema,
  text: z.string().trim().min(1).max(200),
  ttlSeconds: z.number().int().min(10).max(86_400).default(3_600)
}).strict();
