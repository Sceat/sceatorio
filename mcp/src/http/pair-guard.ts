/**
 * The companion is the only process that can reach the mod's UDP socket, so it
 * is the sole gatekeeper in front of the Lua gateway's global failed-pairing
 * limiter (10 failures per game-minute). Capping *forwarded* failures at 5 per
 * rolling minute keeps that limiter permanently out of reach from the
 * internet; a per-IP attempt bucket stops one client grinding codes.
 */

const PAIRING_CODE_PATTERN = /^[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/u;

/** Mirrors `valid_pairing_code` / `PAIRING_ALPHABET` in `src/game/aiGateway.lua`. */
export function isPairingCode(value: unknown): value is string {
  return typeof value === "string" && PAIRING_CODE_PATTERN.test(value);
}

export type PairGuardVerdict = "allow" | "ip-throttled" | "shedding";

export interface PairGuardOptions {
  maxForwardedFailures?: number | undefined;
  failureWindowMs?: number | undefined;
  maxAttemptsPerIp?: number | undefined;
  attemptWindowMs?: number | undefined;
  maxTrackedIps?: number | undefined;
}

export class PairGuard {
  private readonly maxForwardedFailures: number;
  private readonly failureWindowMs: number;
  private readonly maxAttemptsPerIp: number;
  private readonly attemptWindowMs: number;
  private readonly maxTrackedIps: number;
  private readonly attempts = new Map<string, number[]>();
  private failures: number[] = [];

  constructor(options: PairGuardOptions = {}) {
    this.maxForwardedFailures = options.maxForwardedFailures ?? 5;
    this.failureWindowMs = options.failureWindowMs ?? 60_000;
    this.maxAttemptsPerIp = options.maxAttemptsPerIp ?? 5;
    this.attemptWindowMs = options.attemptWindowMs ?? 600_000;
    this.maxTrackedIps = options.maxTrackedIps ?? 1_024;
  }

  /** Decides whether one pairing attempt may proceed, and books it if so. */
  admit(ip: string, nowMs: number = Date.now()): PairGuardVerdict {
    this.failures = withinWindow(this.failures, nowMs, this.failureWindowMs);
    if (this.failures.length >= this.maxForwardedFailures) {
      return "shedding";
    }
    const booked = withinWindow(this.attempts.get(ip) ?? [], nowMs, this.attemptWindowMs);
    if (booked.length >= this.maxAttemptsPerIp) {
      this.attempts.set(ip, booked);
      return "ip-throttled";
    }
    booked.push(nowMs);
    this.attempts.set(ip, booked);
    this.evictStale(nowMs);
    return "allow";
  }

  /** Books a failure the game actually saw; only these count toward the forwarded cap. */
  recordFailure(nowMs: number = Date.now()): void {
    this.failures = withinWindow(this.failures, nowMs, this.failureWindowMs);
    this.failures.push(nowMs);
  }

  /** A completed pairing frees the player's bucket so re-pairing is never blocked by past tries. */
  recordSuccess(ip: string): void {
    this.attempts.delete(ip);
  }

  private evictStale(nowMs: number): void {
    if (this.attempts.size <= this.maxTrackedIps) {
      return;
    }
    for (const [ip, booked] of this.attempts) {
      const live = withinWindow(booked, nowMs, this.attemptWindowMs);
      if (live.length === 0) {
        this.attempts.delete(ip);
      } else {
        this.attempts.set(ip, live);
      }
    }
    while (this.attempts.size > this.maxTrackedIps) {
      const oldest = this.attempts.keys().next();
      if (oldest.done === true) {
        return;
      }
      this.attempts.delete(oldest.value);
    }
  }
}

/**
 * Drops entries older than the window. A clock stepped backwards would
 * otherwise erase the window and hand the mod's limiter back to the internet,
 * so future stamps are clamped to now instead: the guard stays closed and
 * heals one window later.
 */
function withinWindow(stamps: readonly number[], nowMs: number, windowMs: number): number[] {
  return stamps
    .map((stamp) => Math.min(stamp, nowMs))
    .filter((stamp) => stamp > nowMs - windowMs);
}
