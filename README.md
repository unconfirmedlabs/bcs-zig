# bcs-zig

BCS (Binary Canonical Serialization) for Zig. Comptime-driven serialization with zero framework overhead.

BCS is the binary encoding used by Sui, Aptos, and other Move-based blockchains. This library provides serialize/deserialize for all BCS types using Zig's comptime reflection — no proc macros, no derive, no serde.

## Usage

```zig
const bcs = @import("bcs");

const MoveCall = struct {
    package: [32]u8,
    module: bcs.String,
    function: bcs.String,
    amount: u64,
};

// Serialize
const bytes = try bcs.serialize(allocator, MoveCall{
    .package = address,
    .module = bcs.String.init("coin"),
    .function = bcs.String.init("transfer"),
    .amount = 1_000_000,
});
defer allocator.free(bytes);

// Deserialize
const call = try bcs.deserialize(MoveCall, allocator, bytes);
defer bcs.freeDeserialized(MoveCall, allocator, call);
```

### Supported types

| Zig type | BCS encoding |
|----------|-------------|
| `bool` | 1 byte (0x00/0x01) |
| `u8`..`u256`, `i8`..`i128` | Fixed-size little-endian |
| `[]const u8` | ULEB128 length + bytes |
| `bcs.String` | ULEB128 length + UTF-8 bytes |
| `[]const T` | ULEB128 length + elements |
| `[N]T` | N elements, no length prefix |
| `?T` | 0x00 (null) or 0x01 + value |
| `struct` | Fields serialized in declaration order |
| `union(enum)` | ULEB128 variant index + data |
| `enum` | ULEB128 variant index |
| `bcs.Map(K, V)` | ULEB128 count + entries sorted by BCS key bytes |
| `void` | Zero bytes |
| Tuples | Fields in order, no depth increment |

### Strings vs bytes

`[]const u8` is raw bytes, matching Rust `Vec<u8>` / `&[u8]`.

`bcs.String` is the Rust-compatible string type. It uses the same wire format as bytes, but `serialize` and `deserialize` validate UTF-8 and return `error.Utf8` for invalid data, matching Rust `bcs` string semantics.

### Maps

BCS maps require canonical key ordering. Use `bcs.Map(K, V)`:

```zig
const M = bcs.Map(bcs.String, u64);
const map = M{ .entries = &.{
    .{ .key = bcs.String.init("alice"), .value = 100 },
    .{ .key = bcs.String.init("bob"), .value = 200 },
} };
const bytes = try bcs.serialize(allocator, map);
```

Entries are automatically sorted by their BCS-encoded key bytes during serialization. Duplicate serialized keys are deduplicated the same way as Rust `bcs` (stable sort, keep first), while deserialization still rejects out-of-order or duplicate keys.

### Zero-allocation serialization

For fixed-size types (no slices, optionals, maps, or unions), `serializeInto` writes directly to a caller-provided buffer with zero heap allocations:

```zig
var buf: [41]u8 = undefined;
const n = try bcs.serializeInto(&buf, MyStruct{ .a = 42, .b = true, .c = address });
// buf[0..n] contains the BCS bytes — no allocator needed
```

Custom container-depth limits are also available when you need Rust-style `_with_limit` behavior:

```zig
const bytes = try bcs.serializeWithLimit(allocator, value, 128);
defer allocator.free(bytes);

const size = try bcs.serializedSizeWithLimit(value, 128);
const decoded = try bcs.deserializeWithLimit(MyType, allocator, bytes, 128);
defer bcs.freeDeserialized(MyType, allocator, decoded);
```

Limit-aware variants are available for all existing entry points:
- `serializeIntoWithLimit`
- `serializeWithLimit`
- `serializeAppendWithLimit`
- `serializeWriterWithLimit`
- `serializedSizeWithLimit`
- `deserializeWithLimit`
- `deserializePartialWithLimit`
- `deserializeReaderWithLimit`
- `deserializeSeedWithLimit`
- `deserializeReaderSeedWithLimit`

Passing a limit above [`bcs.max_container_depth`](README.md) returns `error.NotSupported`, matching the Rust crate's "limit exceeds the max allowed depth" behavior.

### Partial deserialization

```zig
const result = try bcs.deserializePartial(u32, allocator, buffer);
// result.value: u32
// result.bytes_read: usize — how far into the buffer we consumed
```

### Seed-style deserialization

Rust's `from_bytes_seed` / `from_reader_seed` behavior is available through Zig-native seed objects. A seed declares `pub const Value` and `pub fn deserialize(self, de: *bcs.SeedDeserializer)`.

Available entry points:
- `deserializeSeed`
- `deserializeSeedWithLimit`
- `deserializeReaderSeed`
- `deserializeReaderSeedWithLimit`

### Memory management

For types containing slices (`[]const T`), the deserializer allocates via the provided allocator. Use `bcs.freeDeserialized` to recursively free all allocations:

```zig
const decoded = try bcs.deserialize(MyType, allocator, bytes);
defer bcs.freeDeserialized(MyType, allocator, decoded);
```

For fixed-size types (structs of primitives, arrays), no heap allocation occurs.

## Install

Add to `build.zig.zon`:

```zig
.dependencies = .{
    .bcs = .{
        .url = "https://github.com/unconfirmedlabs/bcs-zig/archive/<commit>.tar.gz",
        .hash = "...",
    },
},
```

Then in `build.zig`:

```zig
const bcs = b.dependency("bcs", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("bcs", bcs.module("bcs"));
```

## Performance

Benchmarked against Rust `bcs` v0.1.6 (serde-based). 1M iterations, Apple Silicon (aarch64), `c_allocator`.

### Serialization

| Type | Zig | Rust | Zig vs Rust |
|------|-----|------|-------------|
| u64 (8B) | 10.8 ns | 12.5 ns | 1.2x |
| SimpleStruct (41B) | 17.3 ns | 89.8 ns | **5.2x** |
| Address [32]u8 (32B) | 12.3 ns | 51.2 ns | **4.2x** |
| NestedStruct (65B) | 28.2 ns | 83.7 ns | **3.0x** |
| MoveCall (176B) | 67.2 ns | 150.9 ns | **2.2x** |
| Enum variant (33B) | 17.3 ns | 70.4 ns | **4.1x** |
| Vec\<u32\> x1000 (4002B) | 79.7 ns | 536.1 ns | **6.7x** |

Both `serialize` and `to_bytes` allocate and return owned output buffers.

### Deserialization

Only types with real heap allocation are shown — fixed-size types like u64, SimpleStruct, and Address deserialize in <1 ns in both languages due to compiler optimizations, making comparison unreliable.

| Type | Zig | Rust | Zig vs Rust |
|------|-----|------|-------------|
| NestedStruct (65B) | 30.8 ns | 41.1 ns | **1.3x** |
| MoveCall (176B) | 121.2 ns | 286.9 ns | **2.4x** |
| Enum variant (33B) | 3.8 ns | 51.1 ns | **13.4x** |
| Vec\<u32\> x1000 (4002B) | 53.0 ns | 1,994 ns | **37.6x** |

### Why it's faster

The speed comes from Zig's comptime, not from the Rust BCS code being slow. Rust `bcs` sits on serde's Serializer/Deserializer visitor pattern with runtime trait dispatch. Zig's `@typeInfo` resolves all type dispatch at compile time — for fixed-size types, the compiler unrolls serialization into direct memory operations (a few loads/stores). A hand-written Rust serializer without serde would be similarly fast.

Additional optimizations:
- **Bulk memcpy** for integer slices/arrays on little-endian platforms (verified correct at comptime)
- **Exact pre-allocation** for fixed-size types via comptime size calculation
- **Zero-allocation path** (`serializeInto`) bypasses the allocator entirely
- **ULEB128 batch writes** into stack buffer instead of per-byte appends

### Reproducing

```bash
# Build benchmarks
cd bcs-zig
zig build-exe -OReleaseFast --dep bcs -Mroot=bench/throughput.zig -Mbcs=src/bcs.zig --name throughput-zig -lc
cd bench && cargo build --release --bin throughput && cd ..

# Run
./throughput-zig
bench/target/release/throughput
```

## Comparison with Rust reference (`diem/bcs`)

### Source complexity

| | Zig (`bcs-zig`) | Rust (`diem/bcs`) |
|---|---|---|
| **Library code** | ~4,400 lines, 1 file | ~1,200 lines, 4 files (`lib.rs`, `ser.rs`, `de.rs`, `error.rs`) |
| **Dependencies** | 0 (only `std`) | `serde` + `serde_derive` (proc macros, ~30k lines) |
| **Derive mechanism** | `@typeInfo` comptime (built-in) | `#[derive(Serialize, Deserialize)]` proc macros |
| **Test suite** | 102 tests + deterministic differential harnesses | ~40 tests + proptest |

### Binary size

Both programs perform identical work:
1. Create `TestStruct { a: u64, b: bool, c: [u8; 32] }` with the same values
2. Serialize to BCS bytes
3. Deserialize back
4. Assert the round-trip produces the original value

Both produce byte-identical BCS output (`2a0000000000000001abab...`, 41 bytes). Source code for both benchmarks is in [`bench/`](bench/).

**Native (aarch64-apple-darwin):**

| | Size | Build flags |
|---|---|---|
| **Rust** | 279 KB | `opt-level=z`, LTO, `codegen-units=1`, strip, `panic=abort` |
| **Zig** | 66 KB | `ReleaseSmall`, stripped |

Zig is **4.2x smaller**. Both use their respective "minimize binary size" optimization profiles.

**WASM (exported `bcs_roundtrip() → u64`):**

| | Size | Target | Build flags |
|---|---|---|---|
| **Rust** | 52.2 KB | `wasm32-wasip1` | `cdylib`, `opt-level=z`, LTO |
| **Zig** | 4.8 KB | `wasm32-freestanding` | `ReleaseSmall` |

Zig is **10.9x smaller**.

> **Why different WASM targets?** The Rust `bcs` crate depends on `thiserror`, which requires `std::error::Error`. This forces `wasm32-wasip1` (WASI with full std). The Zig library has zero std dependencies for its core logic, so it compiles to `wasm32-freestanding` (no OS). This isn't an unfair comparison — it's a genuine architectural advantage of having no framework dependency. The 52 KB Rust binary includes WASI runtime, serde trait machinery, and dlmalloc; the 4.8 KB Zig binary includes only the BCS logic and a trivial bump allocator.

### Reproducing the benchmark

Requires: Zig 0.15+, Rust stable with `wasm32-wasip1` target (`rustup target add wasm32-wasip1`).

```bash
cd bcs-zig

# ── Zig ──
# Native
zig build-exe -OReleaseSmall --dep bcs -Mroot=bench/main.zig -Mbcs=src/bcs.zig \
  -femit-bin=zig-out/bench_native
strip zig-out/bench_native
ls -la zig-out/bench_native

# WASM
zig build-lib -OReleaseSmall --dep bcs -Mroot=bench/lib.zig -Mbcs=src/bcs.zig \
  -target wasm32-freestanding -femit-bin=zig-out/bench.wasm
ls -la zig-out/bench.wasm

# ── Rust ──
cd /tmp && mkdir -p bcs-rust-bench/src
cp <path-to>/bcs-zig/bench/Cargo.toml bcs-rust-bench/
cp <path-to>/bcs-zig/bench/main.rs bcs-rust-bench/src/
cp <path-to>/bcs-zig/bench/lib.rs bcs-rust-bench/src/
cd bcs-rust-bench

# Native
cargo build --release
ls -la target/release/bcs_bench

# WASM
cargo build --release --target wasm32-wasip1 --lib
ls -la target/wasm32-wasip1/release/bcs_bench.wasm
```

> **Note**: If you have both Homebrew Rust and rustup installed, set `RUSTC=~/.rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc` to ensure cargo uses the rustup toolchain with the WASM target.

### Compile time

Zig's comptime reflection is part of the normal compilation pass. Rust's serde proc macros run as a separate expansion stage before compilation, and are the single largest contributor to compile times in Sui/Move projects.

### Pros: Zig

- **Zero dependencies** — no framework, no proc macros, no codegen
- **Debuggable** — serialization is visible comptime-unrolled code, not macro-generated black box
- **Tiny WASM** — 4.8 KB vs 52 KB for serde-based BCS (10.9x smaller)
- **Fast compilation** — no proc macro overhead
- **No orphan rule** — serialize any struct, even from other packages, without newtype wrappers
- **u256 native** — Zig has arbitrary-width integers; Rust needs external crates for u256
- **Single file** — entire library is one file, trivial to vendor

### Pros: Rust

- **Reference implementation** — the Rust `bcs` crate *defines* what BCS is; this is a port chasing conformance
- **serde ecosystem** — one `#[derive(Serialize)]` gives you BCS, JSON, CBOR, MessagePack, etc.
- **Battle-tested** — running in production on Sui and Aptos since 2020
- **Type safety** — Rust's borrow checker prevents more memory bugs at compile time
- **Property testing** — proptest provides randomized coverage beyond fixed test vectors
- **Richer error messages** — Rust BCS errors include type names (e.g., `ExceededContainerDepthLimit("List")`)

### Byte-level parity

This library produces byte-identical output to the Rust reference for all tested types, verified against the canonical `serde_known_vector` test from `diem/bcs`:

```
ff ff ff ff ff ff ff ff 06 64 63 58 4d 42 37 64
00 00 00 00 00 00 00 09 00 01 02 03 04 05 06 07
08 05 05 05 05 05 05 05 05 05 05 05 05 05 05 05
05 05 05 05 05 05 05 05 05 05 05 05 05 05 05 05
05 63 00 00 00 01 03 01 01 03 16 15 43 03 00 38
15 03 16 0a 05 04 14 15 59 69 03 c9 17 5a
```

102 tests cover: all primitive types, explicit UTF-8 string semantics, raw byte vectors, vectors, fixed arrays, optionals, structs, tagged unions, enums, tuples, canonical maps, duplicate-key map parity, invalid UTF-8 string-key map rejection, reader-based deserialize parity, seed-based deserialize parity, custom container-depth limits, error cases, bulk copy correctness verification, and the Rust `serde_known_vector` / recursion-limit parity cases.

The Rust/Zig compatibility suite now has ten parts:
- `bench/crossval.rs` and `bench/crossval.zig`: 72 byte-identical serialization vectors
- `bench/deser_crossval.rs` and `bench/deser_crossval.zig`: generic deserialize/error parity, including invalid UTF-8 string cases
- `bench/error_crossval.rs` and `bench/error_crossval.zig`: exhaustive prefix truncation plus malformed-input semantic error-category parity
- `bench/mutation_crossval.rs` and `bench/mutation_crossval.zig`: expanded deterministic mutation corpus across nested composite types, checking near-valid decode/error parity
- `bench/reader_crossval.rs` and `bench/reader_crossval.zig`: reader-based decode parity against Rust `from_reader` and `from_reader_with_limit`
- `bench/seed_crossval.rs` and `bench/seed_crossval.zig`: seed-based decode parity against Rust `from_bytes_seed` / `from_reader_seed` and `_with_limit`
- `bench/corpus_crossval.rs` and `bench/corpus_crossval.zig`: persistent malformed-input corpus cross-validation over canonical sharp-edge cases
- `bench/sui_crossval.rs` and `bench/sui_crossval.zig`: Sui-shaped fixture parity with Rust `String` fields mapped to `bcs.String`
- `bench/limit_crossval.rs` and `bench/limit_crossval.zig`: custom depth-limit parity
- `bench/random_crossval.rs` and `bench/random_crossval.zig`: expanded deterministic randomized serialization and deserialize-roundtrip parity across many generated composite values

## License

Apache-2.0 (matching the original `diem/bcs`)
