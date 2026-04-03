import type { PayloadType, BenchmarkResult } from "./types";
import { ALL_PAYLOADS, PAYLOAD_SIZES } from "./types";
import { getPayloadEntry } from "./payloads";

export type WorkerMessage =
  | { type: "start"; iterations: number }
  | { type: "result"; result: BenchmarkResult }
  | { type: "done" };

self.onmessage = (e: MessageEvent<{ type: "start"; iterations: number }>) => {
  if (e.data.type !== "start") return;
  const { iterations } = e.data;

  for (const payload of ALL_PAYLOADS) {
    const entry = getPayloadEntry(payload);
    const bytesPerOp = PAYLOAD_SIZES[payload];

    // Warm-up
    for (let i = 0; i < 1000; i++) entry.roundtrip();

    // Measure
    const start = performance.now();
    for (let i = 0; i < iterations; i++) entry.roundtrip();
    const elapsedMs = performance.now() - start;

    const elapsedNs = elapsedMs * 1_000_000;
    const opsPerSec = iterations / (elapsedMs / 1000);
    const nsPerOp = elapsedNs / iterations;
    const totalBytes = bytesPerOp * iterations;
    const throughputMBs = totalBytes / 1_000_000 / (elapsedMs / 1000);

    const result: BenchmarkResult = {
      payload,
      elapsedMs,
      iterations,
      opsPerSec,
      nsPerOp,
      throughputMBs,
    };

    self.postMessage({ type: "result", result } satisfies WorkerMessage);
  }

  self.postMessage({ type: "done" } satisfies WorkerMessage);
};
