export type DatagramListener = (payload: Uint8Array) => void;

export interface DatagramPeer {
  send(payload: Uint8Array): Promise<void>;
  onMessage(listener: DatagramListener): () => void;
  close(): Promise<void>;
}

export class MockDatagramPeer implements DatagramPeer {
  readonly sent: Uint8Array[] = [];
  private readonly listeners = new Set<DatagramListener>();
  private closed = false;

  async send(payload: Uint8Array): Promise<void> {
    if (this.closed) {
      throw new Error("Mock datagram peer is closed");
    }
    this.sent.push(payload.slice());
  }

  onMessage(listener: DatagramListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  receive(payload: Uint8Array | string | object): void {
    const encoded =
      payload instanceof Uint8Array
        ? payload
        : new TextEncoder().encode(typeof payload === "string" ? payload : JSON.stringify(payload));
    for (const listener of this.listeners) {
      listener(encoded);
    }
  }

  async close(): Promise<void> {
    this.closed = true;
    this.listeners.clear();
  }
}
