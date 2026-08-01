import { randomUUID } from "node:crypto";

import type { DatagramPeer } from "./datagram-peer.js";
import {
  FactorioProtocolError,
  FactorioTimeoutError,
  FactorioTransportClosedError,
  type FactorioCall,
  type FactorioCallOptions,
  type FactorioTransport
} from "./factorio-transport.js";
import {
  FACTORIO_GATEWAY_PROTOCOL,
  FactorioResponseSchema,
  MAX_GATEWAY_DATAGRAM_BYTES,
  type FactorioRequest,
  type FactorioResponse
} from "./protocol.js";

interface PendingRequest {
  resolve: (response: FactorioResponse) => void;
  reject: (error: Error) => void;
  timeout: NodeJS.Timeout;
  removeAbortListener: () => void;
}

export interface CorrelatedFactorioTransportOptions {
  defaultTimeoutMs?: number | undefined;
  maxDatagramBytes?: number | undefined;
  idFactory?: (() => string) | undefined;
}

export class CorrelatedFactorioTransport implements FactorioTransport {
  private readonly pending = new Map<string, PendingRequest>();
  private readonly defaultTimeoutMs: number;
  private readonly maxDatagramBytes: number;
  private readonly idFactory: () => string;
  private readonly unsubscribe: () => void;
  private closed = false;

  constructor(
    private readonly peer: DatagramPeer,
    options: CorrelatedFactorioTransportOptions = {}
  ) {
    this.defaultTimeoutMs = options.defaultTimeoutMs ?? 10_000;
    this.maxDatagramBytes = options.maxDatagramBytes ?? MAX_GATEWAY_DATAGRAM_BYTES;
    this.idFactory = options.idFactory ?? randomUUID;
    this.unsubscribe = peer.onMessage((payload) => this.handleDatagram(payload));
  }

  async request(
    call: FactorioCall,
    options: FactorioCallOptions = {}
  ): Promise<FactorioResponse> {
    if (this.closed) {
      throw new FactorioTransportClosedError();
    }

    const id = this.idFactory();
    const request: FactorioRequest = {
      protocol: FACTORIO_GATEWAY_PROTOCOL,
      kind: "request",
      id,
      operation: call.operation,
      scope: call.scope,
      payload: call.payload
    };
    const datagram = new TextEncoder().encode(JSON.stringify(request));
    if (datagram.byteLength > this.maxDatagramBytes) {
      throw new FactorioProtocolError(
        `Gateway request is ${datagram.byteLength} bytes; maximum is ${this.maxDatagramBytes}`,
        id
      );
    }

    const timeoutMs = options.timeoutMs ?? this.defaultTimeoutMs;
    if (!Number.isInteger(timeoutMs) || timeoutMs <= 0) {
      throw new RangeError("timeoutMs must be a positive integer");
    }
    if (options.signal?.aborted === true) {
      throw options.signal.reason instanceof Error
        ? options.signal.reason
        : new Error("Factorio request aborted");
    }

    const responsePromise = new Promise<FactorioResponse>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new FactorioTimeoutError(id, timeoutMs));
      }, timeoutMs);

      const onAbort = (): void => {
        const pending = this.pending.get(id);
        if (pending === undefined) {
          return;
        }
        clearTimeout(pending.timeout);
        this.pending.delete(id);
        reject(
          options.signal?.reason instanceof Error
            ? options.signal.reason
            : new Error("Factorio request aborted")
        );
      };
      options.signal?.addEventListener("abort", onAbort, { once: true });

      this.pending.set(id, {
        resolve,
        reject,
        timeout,
        removeAbortListener: () => options.signal?.removeEventListener("abort", onAbort)
      });
    });

    try {
      await this.peer.send(datagram);
    } catch (error) {
      const pending = this.pending.get(id);
      if (pending !== undefined) {
        clearTimeout(pending.timeout);
        pending.removeAbortListener();
        this.pending.delete(id);
      }
      throw error;
    }
    return responsePromise;
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.unsubscribe();
    const error = new FactorioTransportClosedError();
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timeout);
      pending.removeAbortListener();
      pending.reject(error);
    }
    this.pending.clear();
    await this.peer.close();
  }

  private handleDatagram(payload: Uint8Array): void {
    if (payload.byteLength > this.maxDatagramBytes) {
      return;
    }
    let decoded: unknown;
    try {
      decoded = JSON.parse(new TextDecoder().decode(payload));
    } catch {
      return;
    }

    const candidateId =
      typeof decoded === "object" && decoded !== null && "id" in decoded
        ? (decoded as { id?: unknown }).id
        : undefined;
    if (typeof candidateId !== "string") {
      return;
    }
    const pending = this.pending.get(candidateId);
    if (pending === undefined) {
      return;
    }

    const parsed = FactorioResponseSchema.safeParse(decoded);
    clearTimeout(pending.timeout);
    pending.removeAbortListener();
    this.pending.delete(candidateId);
    if (!parsed.success) {
      pending.reject(new FactorioProtocolError("Malformed Factorio response", candidateId));
      return;
    }
    pending.resolve(parsed.data);
  }
}
