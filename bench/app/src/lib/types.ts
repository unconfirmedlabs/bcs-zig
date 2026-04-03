export type PayloadType =
  | "simple_struct"
  | "nested_struct"
  | "move_call"
  | "enum_variant"
  | "u64"
  | "u128"
  | "u256"
  | "option_struct"
  | "vec_1000_u32"
  | "address_32b";

export const ALL_PAYLOADS: PayloadType[] = [
  "simple_struct",
  "nested_struct",
  "move_call",
  "enum_variant",
  "u64",
  "u128",
  "u256",
  "option_struct",
  "vec_1000_u32",
  "address_32b",
];

export const PAYLOAD_LABELS: Record<PayloadType, string> = {
  simple_struct: "SimpleStruct",
  nested_struct: "NestedStruct",
  move_call: "MoveCall (Sui tx)",
  enum_variant: "Enum variant",
  u64: "u64",
  u128: "u128",
  u256: "u256",
  option_struct: "Option<Struct>",
  vec_1000_u32: "Vec<u32> (1000)",
  address_32b: "Address [32]u8",
};

export const PAYLOAD_SIZES: Record<PayloadType, number> = {
  simple_struct: 41,
  nested_struct: 65,
  move_call: 176,
  enum_variant: 33,
  u64: 8,
  u128: 16,
  u256: 32,
  option_struct: 42,
  vec_1000_u32: 4002,
  address_32b: 32,
};

export interface BenchmarkResult {
  payload: PayloadType;
  elapsedMs: number;
  iterations: number;
  opsPerSec: number;
  nsPerOp: number;
  throughputMBs: number;
}

export type Side = "typescript" | "zig-wasm";
