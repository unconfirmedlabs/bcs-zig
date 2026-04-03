import type { PayloadType, BenchmarkResult } from "./types";
import { PAYLOAD_SIZES } from "./types";
import { getPayloadEntry } from "./payloads";

export function runTsBenchmark(
  payload: PayloadType,
  iterations: number,
  warmup = 1000,
): BenchmarkResult {
  const entry = getPayloadEntry(payload);
  const bytesPerOp = PAYLOAD_SIZES[payload];

  for (let i = 0; i < warmup; i++) entry.roundtrip();

  const start = performance.now();
  for (let i = 0; i < iterations; i++) entry.roundtrip();
  const elapsedMs = performance.now() - start;

  const elapsedNs = elapsedMs * 1_000_000;
  const opsPerSec = iterations / (elapsedMs / 1000);
  const nsPerOp = elapsedNs / iterations;
  const totalBytes = bytesPerOp * iterations;
  const throughputMBs = totalBytes / 1_000_000 / (elapsedMs / 1000);

  return { payload, elapsedMs, iterations, opsPerSec, nsPerOp, throughputMBs };
}
