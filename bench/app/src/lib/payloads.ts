import { bcs } from "@mysten/bcs";
import type { PayloadType } from "./types";

// ── Schema definitions (byte-identical to bench/lib.zig types) ───────

const InnerMetaSchema = bcs.struct("InnerMeta", {
  version: bcs.u16(),
  flags: bcs.u64(),
  tag: bcs.fixedArray(8, bcs.u8()),
});

const SimpleStructSchema = bcs.struct("SimpleStruct", {
  a: bcs.u64(),
  b: bcs.bool(),
  c: bcs.fixedArray(32, bcs.u8()),
});

const NestedStructSchema = bcs.struct("NestedStruct", {
  id: bcs.u64(),
  name: bcs.string(),
  scores: bcs.vector(bcs.u32()),
  active: bcs.bool(),
  metadata: InnerMetaSchema,
});

const MoveCallSchema = bcs.struct("MoveCall", {
  sender: bcs.fixedArray(32, bcs.u8()),
  package: bcs.fixedArray(32, bcs.u8()),
  module_name: bcs.string(),
  function_name: bcs.string(),
  type_args: bcs.vector(bcs.string()),
  args: bcs.vector(bcs.vector(bcs.u8())),
  gas_budget: bcs.u64(),
  gas_price: bcs.u64(),
});

const EnumSchema = bcs.enum("Enum", {
  unit: null,
  with_u64: bcs.u64(),
  with_bytes: bcs.fixedArray(32, bcs.u8()),
  with_string: bcs.string(),
});

// ── Test values (matching throughput.zig / bench/lib.zig exactly) ────

const SIMPLE_VAL = {
  a: 42n,
  b: true,
  c: Array.from({ length: 32 }, () => 0xab),
};

const NESTED_VAL = {
  id: 999999n,
  name: "hello_world_test",
  scores: [100, 200, 300, 400, 500],
  active: true,
  metadata: {
    version: 3,
    flags: 0xdeadbeefn,
    tag: [0x4d, 0x45, 0x54, 0x41, 0x54, 0x41, 0x47, 0x00], // "METATAG\0"
  },
};

const MOVE_VAL = {
  sender: Array.from({ length: 32 }, () => 0x01),
  package: Array.from({ length: 32 }, () => 0x02),
  module_name: "coin",
  function_name: "transfer",
  type_args: ["0x2::sui::SUI", "0x2::coin::Coin"],
  args: [
    Array.from({ length: 32 }, () => 0xaa),
    Array.from({ length: 16 }, () => 0xbb),
  ],
  gas_budget: 50_000_000n,
  gas_price: 1000n,
};

const ENUM_VAL = {
  with_bytes: Array.from({ length: 32 }, () => 0xff),
};

const U64_VAL = 0xdeadbeefcafebaben;

const VEC_VAL = Array.from({ length: 1000 }, (_, i) => i);

const ADDR_VAL = Array.from({ length: 32 }, () => 0x42);

const U128_VAL = 0xDEADBEEFCAFEBABE_0123456789ABCDEFn;
const U256_VAL = 0xDEADBEEFCAFEBABE_0123456789ABCDEF_FEDCBA9876543210_BAADF00DCAFEBABEn;

const OptionStructSchema = bcs.option(SimpleStructSchema);
const OPTION_VAL = SIMPLE_VAL;

// ── Pre-created schemas for primitives ───────────────────────────────
const u64Schema = bcs.u64();
const u128Schema = bcs.u128();
const u256Schema = bcs.u256();
const vecU32Schema = bcs.vector(bcs.u32());
const addr32Schema = bcs.fixedArray(32, bcs.u8());

// ── Benchmark runner per payload ─────────────────────────────────────

type PayloadEntry = {
  roundtrip: () => void;
};

function makeEntry<T>(
  schema: {
    serialize: (val: T) => { toBytes: () => Uint8Array };
    parse: (bytes: Uint8Array) => T;
  },
  value: T,
): PayloadEntry {
  return {
    roundtrip: () => {
      const bytes = schema.serialize(value).toBytes();
      schema.parse(bytes);
    },
  };
}

const entries: Record<PayloadType, PayloadEntry> = {
  simple_struct: makeEntry(SimpleStructSchema, SIMPLE_VAL),
  nested_struct: makeEntry(NestedStructSchema, NESTED_VAL),
  move_call: makeEntry(MoveCallSchema, MOVE_VAL),
  enum_variant: makeEntry(EnumSchema, ENUM_VAL),
  u64: makeEntry(u64Schema, U64_VAL),
  u128: makeEntry(u128Schema, U128_VAL),
  u256: makeEntry(u256Schema, U256_VAL),
  option_struct: makeEntry(OptionStructSchema, OPTION_VAL),
  vec_1000_u32: makeEntry(vecU32Schema, VEC_VAL),
  address_32b: makeEntry(addr32Schema, ADDR_VAL),
};

export function getPayloadEntry(payload: PayloadType): PayloadEntry {
  return entries[payload];
}
