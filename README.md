# bcs-zig

BCS (Binary Canonical Serialization) for Zig. Comptime-driven serialization with zero framework overhead.

BCS is the binary encoding used by Sui, Aptos, and other Move-based blockchains. This library provides serialize/deserialize for all BCS types using Zig's comptime reflection — no proc macros, no derive, no serde.

## Usage

```zig
const bcs = @import("bcs");

const MoveCall = struct {
    package: [32]u8,
    module: []const u8,
    function: []const u8,
    amount: u64,
};

// Serialize
const bytes = try bcs.serialize(allocator, MoveCall{
    .package = address,
    .module = "coin",
    .function = "transfer",
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
| `[]const u8` | ULEB128 length + bytes (strings too) |
| `[]const T` | ULEB128 length + elements |
| `[N]T` | N elements, no length prefix |
| `?T` | 0x00 (null) or 0x01 + value |
| `struct` | Fields serialized in declaration order |
| `union(enum)` | ULEB128 variant index + data |
| `enum` | ULEB128 variant index |
| `bcs.Map(K, V)` | ULEB128 count + entries sorted by BCS key bytes |
| `void` | Zero bytes |
| Tuples | Fields in order, no depth increment |

### Maps

BCS maps require canonical key ordering. Use `bcs.Map(K, V)`:

```zig
const M = bcs.Map([]const u8, u64);
const map = M{ .entries = &.{
    .{ .key = "alice", .value = 100 },
    .{ .key = "bob", .value = 200 },
} };
const bytes = try bcs.serialize(allocator, map);
```

Entries are automatically sorted by their BCS-encoded key bytes during serialization. Deserialization rejects out-of-order or duplicate keys.

### Zero-allocation serialization

For fixed-size types (no slices, optionals, maps, or unions), `serializeInto` writes directly to a caller-provided buffer with zero heap allocations:

```zig
var buf: [41]u8 = undefined;
const n = try bcs.serializeInto(&buf, MyStruct{ .a = 42, .b = true, .c = address });
// buf[0..n] contains the BCS bytes — no allocator needed
```

### Partial deserialization

```zig
const result = try bcs.deserializePartial(u32, allocator, buffer);
// result.value: u32
// result.bytes_read: usize — how far into the buffer we consumed
```

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

| Type | Zig `serialize` | Zig `serializeInto` | Rust `to_bytes` | Zig vs Rust |
|------|----------------|---------------------|-----------------|-------------|
| u64 (8B) | 10.6 ns | **0.2 ns** | 11 ns | 1x / 55x |
| SimpleStruct (41B) | 13 ns | **0.2 ns** | 75 ns | 5.8x / 375x |
| [32]u8 address (32B) | 12 ns | **1.0 ns** | 51 ns | 4.1x / 51x |
| NestedStruct (65B) | 26 ns | — | 88 ns | 3.4x |
| MoveCall (176B) | 67 ns | — | 150 ns | 2.2x |
| enum variant (33B) | 17 ns | — | 69 ns | 4.1x |
| Vec\<u32\> ×1000 (4002B) | 80 ns | — | 537 ns | 6.7x |

`serialize` returns an allocated `[]u8`. `serializeInto` writes to a caller-provided buffer with zero allocations (fixed-size types only).

### Deserialization

| Type | Zig | Rust | Zig vs Rust |
|------|-----|------|-------------|
| u64 (8B) | 0.2 ns | 0.2 ns | tie |
| SimpleStruct (41B) | 0.2 ns | 52 ns | **260x** |
| [32]u8 address (32B) | 0.2 ns | 52 ns | **260x** |
| NestedStruct (65B) | 30 ns | 42 ns | 1.4x |
| MoveCall (176B) | 120 ns | 273 ns | 2.3x |
| enum variant (33B) | 4 ns | 51 ns | 12.8x |
| Vec\<u32\> ×1000 (4002B) | 53 ns | 1997 ns | **37.7x** |

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
| **Library code** | ~490 lines, 1 file | ~1,200 lines, 4 files (`lib.rs`, `ser.rs`, `de.rs`, `error.rs`) |
| **Dependencies** | 0 (only `std`) | `serde` + `serde_derive` (proc macros, ~30k lines) |
| **Derive mechanism** | `@typeInfo` comptime (built-in) | `#[derive(Serialize, Deserialize)]` proc macros |
| **Test suite** | 69 tests (inline) | ~40 tests + proptest |

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

69 tests cover: all primitive types, strings, vectors, fixed arrays, optionals, structs, tagged unions, enums, tuples, sorted maps, ULEB128 edge cases, depth limits, error cases, bulk copy correctness verification, and the full Rust `serde_known_vector` golden test.

Additionally, 70 cross-language test vectors (`bench/crossval.rs` and `bench/crossval.zig`) are verified byte-identical between Zig and Rust — covering signed/unsigned integers at boundary values, UTF-8 strings, nested types, all option states, maps with sorting, and Sui-specific address patterns.

## License

Apache-2.0 (matching the original `diem/bcs`)
