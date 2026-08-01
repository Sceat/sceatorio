import type { FactorioResponse, GatewayScope } from "./protocol.js";

export interface FactorioCall {
  operation: string;
  scope: GatewayScope;
  payload: unknown;
}

export interface FactorioCallOptions {
  timeoutMs?: number | undefined;
  signal?: AbortSignal | undefined;
}

export interface FactorioTransport {
  request(call: FactorioCall, options?: FactorioCallOptions): Promise<FactorioResponse>;
  close(): Promise<void>;
}

export class FactorioTimeoutError extends Error {
  readonly requestId: string;
  readonly timeoutMs: number;

  constructor(requestId: string, timeoutMs: number) {
    super(`Factorio request ${requestId} timed out after ${timeoutMs} ms`);
    this.name = "FactorioTimeoutError";
    this.requestId = requestId;
    this.timeoutMs = timeoutMs;
  }
}

export class FactorioProtocolError extends Error {
  readonly requestId?: string | undefined;

  constructor(message: string, requestId?: string) {
    super(message);
    this.name = "FactorioProtocolError";
    this.requestId = requestId;
  }
}

export class FactorioRemoteError extends Error {
  readonly code: string;
  readonly retryable: boolean;
  readonly details: unknown;

  constructor(code: string, message: string, retryable: boolean, details?: unknown) {
    super(message);
    this.name = "FactorioRemoteError";
    this.code = code;
    this.retryable = retryable;
    this.details = details;
  }
}

export class FactorioTransportClosedError extends Error {
  constructor() {
    super("The Factorio transport is closed");
    this.name = "FactorioTransportClosedError";
  }
}
