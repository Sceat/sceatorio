import { createSocket, type RemoteInfo, type Socket } from "node:dgram";

import type { DatagramListener, DatagramPeer } from "./datagram-peer.js";

export interface UdpDatagramPeerOptions {
  factorioPort: number;
  localPort?: number | undefined;
  host?: "127.0.0.1" | undefined;
}

export class UdpDatagramPeer implements DatagramPeer {
  private readonly socket: Socket;
  private readonly factorioPort: number;
  private readonly localPort: number;
  private readonly host: "127.0.0.1";
  private readonly listeners = new Set<DatagramListener>();
  private bindPromise: Promise<void> | undefined;
  private closed = false;

  constructor(options: UdpDatagramPeerOptions) {
    this.factorioPort = options.factorioPort;
    this.localPort = options.localPort ?? 0;
    this.host = options.host ?? "127.0.0.1";
    this.socket = createSocket("udp4");
    this.socket.on("message", (payload, remote) => this.handleMessage(payload, remote));
    // Keep late socket errors from becoming uncaught process errors. Individual
    // bind/send operations still surface their own failures to their callers.
    this.socket.on("error", () => undefined);
  }

  async send(payload: Uint8Array): Promise<void> {
    if (this.closed) {
      throw new Error("UDP peer is closed");
    }
    await this.ensureBound();
    await new Promise<void>((resolve, reject) => {
      this.socket.send(payload, this.factorioPort, this.host, (error) => {
        if (error === null) {
          resolve();
        } else {
          reject(error);
        }
      });
    });
  }

  onMessage(listener: DatagramListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.listeners.clear();
    if (this.bindPromise === undefined) {
      return;
    }
    try {
      await this.bindPromise;
      await new Promise<void>((resolve) => this.socket.close(() => resolve()));
    } catch {
      // A failed bind leaves no live UDP handle to close.
    }
  }

  private ensureBound(): Promise<void> {
    if (this.bindPromise !== undefined) {
      return this.bindPromise;
    }
    this.bindPromise = new Promise<void>((resolve, reject) => {
      const onError = (error: Error): void => {
        this.socket.off("listening", onListening);
        reject(error);
      };
      const onListening = (): void => {
        this.socket.off("error", onError);
        resolve();
      };
      this.socket.once("error", onError);
      this.socket.once("listening", onListening);
      this.socket.bind(this.localPort, this.host);
    });
    return this.bindPromise;
  }

  private handleMessage(payload: Uint8Array, remote: RemoteInfo): void {
    if (remote.address !== this.host || remote.port !== this.factorioPort) {
      return;
    }
    for (const listener of this.listeners) {
      listener(payload);
    }
  }
}
