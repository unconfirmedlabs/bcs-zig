import type { PayloadType, BenchmarkResult } from "./types";
import { ALL_PAYLOADS, PAYLOAD_SIZES } from "./types";

type WasmExports = {
  roundtrip_simple_struct: () => bigint;
  roundtrip_nested_struct: () => bigint;
  roundtrip_move_call: () => bigint;
  roundtrip_enum: () => bigint;
  roundtrip_u64: () => bigint;
  roundtrip_u128: () => bigint;
  roundtrip_u256: () => bigint;
  roundtrip_option_struct: () => bigint;
  roundtrip_vec_1000_u32: () => bigint;
  roundtrip_address_32b: () => bigint;
};

const EXPORT_MAP: Record<PayloadType, keyof WasmExports> = {
  simple_struct: "roundtrip_simple_struct",
  nested_struct: "roundtrip_nested_struct",
  move_call: "roundtrip_move_call",
  enum_variant: "roundtrip_enum",
  u64: "roundtrip_u64",
  u128: "roundtrip_u128",
  u256: "roundtrip_u256",
  option_struct: "roundtrip_option_struct",
  vec_1000_u32: "roundtrip_vec_1000_u32",
  address_32b: "roundtrip_address_32b",
};

export type WorkerMessage =
  | { type: "start"; iterations: number }
  | { type: "result"; result: BenchmarkResult }
  | { type: "done" };

self.onmessage = async (
  e: MessageEvent<{ type: "start"; iterations: number }>,
) => {
  if (e.data.type !== "start") return;
  const { iterations } = e.data;

  // Load WASM inside the worker
  const result = await WebAssembly.instantiateStreaming(fetch("/bench.wasm"));
  const exports = result.instance.exports as unknown as WasmExports;

  for (const payload of ALL_PAYLOADS) {
    const fn = exports[EXPORT_MAP[payload]];
    const bytesPerOp = PAYLOAD_SIZES[payload];

    // Warm-up
    for (let i = 0; i < 1000; i++) fn();

    // Measure
    const start = performance.now();
    for (let i = 0; i < iterations; i++) fn();
    const elapsedMs = performance.now() - start;

    const elapsedNs = elapsedMs * 1_000_000;
    const opsPerSec = iterations / (elapsedMs / 1000);
    const nsPerOp = elapsedNs / iterations;
    const totalBytes = bytesPerOp * iterations;
    const throughputMBs = totalBytes / 1_000_000 / (elapsedMs / 1000);

    const benchResult: BenchmarkResult = {
      payload,
      elapsedMs,
      iterations,
      opsPerSec,
      nsPerOp,
      throughputMBs,
    };

    self.postMessage({ type: "result", result: benchResult } satisfies WorkerMessage);
  }

  self.postMessage({ type: "done" } satisfies WorkerMessage);
};
