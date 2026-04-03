import type { PayloadType, BenchmarkResult } from "./types";
import { PAYLOAD_SIZES } from "./types";

type WasmExports = {
  roundtrip_simple_struct: () => bigint;
  roundtrip_nested_struct: () => bigint;
  roundtrip_move_call: () => bigint;
  roundtrip_enum: () => bigint;
  roundtrip_u64: () => bigint;
  roundtrip_vec_1000_u32: () => bigint;
  roundtrip_address_32b: () => bigint;
};

const EXPORT_MAP: Record<PayloadType, keyof WasmExports> = {
  simple_struct: "roundtrip_simple_struct",
  nested_struct: "roundtrip_nested_struct",
  move_call: "roundtrip_move_call",
  enum_variant: "roundtrip_enum",
  u64: "roundtrip_u64",
  vec_1000_u32: "roundtrip_vec_1000_u32",
  address_32b: "roundtrip_address_32b",
};

let wasmExports: WasmExports | null = null;

export async function initWasm(): Promise<void> {
  if (wasmExports) return;
  const result = await WebAssembly.instantiateStreaming(fetch("/bench.wasm"));
  wasmExports = result.instance.exports as unknown as WasmExports;
}

export async function runWasmBenchmark(
  payload: PayloadType,
  iterations: number,
  warmup = 1000,
): Promise<BenchmarkResult> {
  await initWasm();
  const fn = wasmExports![EXPORT_MAP[payload]];
  const bytesPerOp = PAYLOAD_SIZES[payload];

  for (let i = 0; i < warmup; i++) fn();

  const start = performance.now();
  for (let i = 0; i < iterations; i++) fn();
  const elapsedMs = performance.now() - start;

  const elapsedNs = elapsedMs * 1_000_000;
  const opsPerSec = iterations / (elapsedMs / 1000);
  const nsPerOp = elapsedNs / iterations;
  const totalBytes = bytesPerOp * iterations;
  const throughputMBs = totalBytes / 1_000_000 / (elapsedMs / 1000);

  return { payload, elapsedMs, iterations, opsPerSec, nsPerOp, throughputMBs };
}
