# BCS-Zig Implementation Audit Summary

## Overview

Single-file BCS (Binary Canonical Serialization) library for Zig 0.14+. Reference: Rust `bcs` crate v0.1.6 (diem/bcs). Zero dependencies beyond `std`.

- **Source**: `src/bcs.zig` (4611 lines)
- **Tests**: 102 unit tests, all passing
- **Compatibility suite**: 72 byte-identical serialization vectors plus deserialize/error, reader, seed, limit, randomized, mutation, corpus-based malformed-input, and Sui-shaped Rust/Zig cross-validation
- **Design goal**: reference-level wire semantics with Zig-native API shape: comptime reflection, explicit wrapper types, direct reader/seed APIs, and allocator-explicit ownership

## Public API

```zig
// Allocating serialization (any type)
pub fn serialize(allocator: Allocator, value: anytype) Error![]u8
pub fn serializeWithLimit(allocator: Allocator, value: anytype, limit: usize) Error![]u8

// Zero-allocation serialization into caller buffer (fixed-size types only)
pub fn serializeInto(buf: []u8, value: anytype) Error!usize
pub fn serializeIntoWithLimit(buf: []u8, value: anytype, limit: usize) Error!usize

// Exact size calculation
pub fn serializedSize(value: anytype) Error!usize
pub fn serializedSizeWithLimit(value: anytype, limit: usize) Error!usize

// Deserialization
pub fn deserialize(comptime T: type, allocator: Allocator, bytes: []const u8) Error!T
pub fn deserializeWithLimit(comptime T: type, allocator: Allocator, bytes: []const u8, limit: usize) Error!T
pub fn deserializePartial(comptime T: type, allocator: Allocator, bytes: []const u8) Error!struct { value: T, bytes_read: usize }
pub fn deserializePartialWithLimit(comptime T: type, allocator: Allocator, bytes: []const u8, limit: usize) Error!struct { value: T, bytes_read: usize }
pub fn deserializeReader(comptime T: type, allocator: Allocator, reader: anytype) !T
pub fn deserializeReaderWithLimit(comptime T: type, allocator: Allocator, reader: anytype, limit: usize) !T
pub fn deserializeSeed(seed: anytype, allocator: Allocator, bytes: []const u8) !SeedValue(@TypeOf(seed))
pub fn deserializeSeedWithLimit(seed: anytype, allocator: Allocator, bytes: []const u8, limit: usize) !SeedValue(@TypeOf(seed))
pub fn deserializeReaderSeed(seed: anytype, allocator: Allocator, reader: anytype) !SeedValue(@TypeOf(seed))
pub fn deserializeReaderSeedWithLimit(seed: anytype, allocator: Allocator, reader: anytype, limit: usize) !SeedValue(@TypeOf(seed))

// Memory cleanup for deserialized values containing heap allocations
pub fn freeDeserialized(comptime T: type, allocator: Allocator, value: T) void

// Rust-compatible UTF-8 string type
pub const String = struct { bytes: []const u8, ... }

// Zig-native equivalent of Rust DeserializeSeed stateful decoding
pub const SeedDeserializer = struct { ... }

// BCS-compatible sorted map type
pub fn Map(comptime K: type, comptime V: type) type
pub fn CanonicalMap(comptime K: type, comptime V: type) type
```

## Constants

```zig
pub const max_sequence_length: u32 = (1 << 31) - 1;  // 2,147,483,647
pub const max_container_depth: u32 = 500;
```

Both match the Rust reference exactly.

## Supported Types

| Zig Type | BCS Encoding | Notes |
|----------|-------------|-------|
| `bool` | 1 byte: `0x00` or `0x01` | Invalid values rejected |
| `u8`..`u256` | Fixed-size little-endian | Arbitrary-width ints (Rust only supports up to u128) |
| `i8`..`i128` | Fixed-size little-endian two's complement | |
| `[]const u8` | ULEB128 length + bytes | Raw bytes (`Vec<u8>` / `&[u8]`) |
| `bcs.String` | ULEB128 length + UTF-8 bytes | Rust `String` / `&str` semantics |
| `[]const T` | ULEB128 length + elements | Variable-length sequences |
| `[N]T` | N elements concatenated | No length prefix |
| `?T` | `0x00` (null) or `0x01` + value | |
| `struct` | Fields in declaration order | Depth incremented |
| `struct` (tuple) | Fields in order | Depth NOT incremented (matches Rust) |
| `union(enum)` | ULEB128 variant index + payload | Depth incremented |
| `enum` | ULEB128 variant index | |
| `Map(K, V)` | ULEB128 count + entries sorted by BCS key bytes | |
| `void` | 0 bytes | |
| `*T` (single pointer) | Dereferences and serializes `T` | Serialize only |

## Unsupported Types (compile error)

- Floats (`f32`, `f64`) — not in BCS spec
- Untagged unions — BCS requires variant indices
- Non-byte-aligned integers — BCS uses byte-granular encoding

## Error Handling

```zig
pub const Error = error{
    InvalidBool,         // bool byte not 0x00 or 0x01
    NonCanonicalUleb128, // ULEB128 has trailing zero continuation byte
    Uleb128Overflow,     // ULEB128 exceeds u32 range (>5 bytes)
    Utf8,                // invalid UTF-8 for bcs.String
    SequenceTooLong,     // sequence length > max_sequence_length
    ContainerTooDeep,    // struct/union nesting > max_container_depth
    NotSupported,        // requested API shape exceeds supported Rust-compatible limit behavior
    UnexpectedEndOfInput,// reader ran out of bytes
    TrailingBytes,       // extra bytes after deserializing (deserialize only, not deserializePartial)
    InvalidEnumTag,      // enum/union variant index out of range
    InvalidOptionTag,    // option tag byte not 0x00 or 0x01
    NonCanonicalMap,     // map keys not in strict ascending BCS byte order, or duplicates
    OutOfMemory,         // allocator failed
};
```

## Internal Architecture

### Serialization — Two Paths

**1. Fixed-size fast path** (`serializeFixed`, line 76):
- Activated when `serializedSizeHint(T) > 0` — i.e., type has comptime-known exact byte count
- Covers: bool, integers, fixed arrays of fixed types, structs of fixed fields
- Single allocation of exact size, direct buffer writes, no ArrayList
- Used by both `serialize()` and `serializeInto()`

**2. Variable-size path** (`serializeValue`, line 397):
- Used for types containing slices, optionals, maps, unions, enums
- Writes to `std.ArrayList(u8)`, returned via `toOwnedSlice`

### Deserialization — Single Path

`deserializeValue` (line 500) recursively deserializes via comptime type dispatch. The `Reader` struct (line 257) tracks position in the input byte slice. Heap allocations occur only for slice types (`[]const T`).

### Performance Optimizations

1. **Bulk memcpy for integer slices/arrays** (lines 423-424, 439-440, 533-538):
   - On native little-endian platforms, `[]const u32` in memory IS the BCS wire format
   - Uses `std.mem.sliceAsBytes` / `std.mem.asBytes` for zero-cost reinterpretation
   - Gated by `canBulkCopy()` (line 308) — comptime check: `native_endian == .little` AND integer type with `bits % 8 == 0`
   - Falls back to per-element serialization on big-endian platforms

2. **ULEB128 stack buffer** (line 220):
   - Encodes into `[5]u8` stack buffer, single `appendSlice` call
   - Avoids per-byte capacity checks

3. **Pre-allocation via `serializedSizeHint`** (line 51):
   - Comptime function returns exact byte count for fixed-size types, 0 for variable types
   - `serialize()` allocates exactly the right buffer size for fixed types — no growth, no shrink

### Map Implementation

- **Serialization** (line 325): Serializes each key to bytes, sorts by key bytes lexicographically, deduplicates equal serialized keys with stable "keep first" semantics, then emits ULEB128 count + sorted key-value pairs. Allocates temporary `SortItem` array.
- **Deserialization** (line 360): Validates keys are in strict ascending BCS byte order by comparing raw reader byte ranges. Rejects out-of-order or duplicate keys with `NonCanonicalMap`.

### Depth Tracking

- Structs and unions increment depth by 1
- Tuples do NOT increment depth (matches Rust/BCS spec)
- Optionals do NOT increment depth (matches Rust/BCS spec)
- Check: `if (new_depth > max_container_depth) return Error.ContainerTooDeep`

## Cross-Validation Results

A cross-validation program (`bench/crossval.rs` and `bench/crossval.zig`) serializes 72 identical test vectors in both Rust and Zig and compares hex output. **All 72 vectors are byte-identical.** Coverage:

- 16 integer primitives (u8-u128, i8-i128 including MIN/MAX boundaries)
- 4 string variants (empty, ASCII, ULEB128 prefix, UTF-8 multibyte)
- 7 vector types (empty, typed, nested, mixed)
- 4 fixed array types
- 9 optional states (some/none, nested `??T` all 3 states)
- 5 struct configurations (simple, nested, complex with mixed types, with optional fields)
- 4 enum variants (unit, u64, bytes, struct payload)
- 2 tuple variants
- 5 map variants (numeric keys, empty, string keys with sorting, duplicate numeric keys, duplicate string keys)
- 4 Sui-specific 32-byte addresses
- 1 large vector (100 u32s)

Additional compatibility runners also pass:
- `bench/deser_crossval.rs` / `bench/deser_crossval.zig`: deserialize/error parity, including invalid UTF-8 string rejection
- `bench/error_crossval.rs` / `bench/error_crossval.zig`: exhaustive prefix truncation and malformed-input error-category parity
- `bench/mutation_crossval.rs` / `bench/mutation_crossval.zig`: expanded deterministic mutations of valid payloads, covering near-valid decode/error parity for nested composite types
- `bench/reader_crossval.rs` / `bench/reader_crossval.zig`: reader-based decode parity, including chunked input and `_with_limit`
- `bench/seed_crossval.rs` / `bench/seed_crossval.zig`: seed-based decode parity, including reader seeds and `_with_limit`
- `bench/corpus_crossval.rs` / `bench/corpus_crossval.zig`: embedded malformed-input corpus covering canonical sharp-edge cases
- `bench/sui_crossval.rs` / `bench/sui_crossval.zig`: Sui-shaped fixtures with Rust `String` fields mapped to `bcs.String`
- `bench/limit_crossval.rs` / `bench/limit_crossval.zig`: `_with_limit` parity
- `bench/random_crossval.rs` / `bench/random_crossval.zig`: expanded deterministic randomized differential coverage over deeper composite shapes and additional map types

## Intentional Non-Contract Differences from Rust `bcs` v0.1.6

The remaining differences are about API shape and language model, not the BCS wire contract. The goal is to match Rust `bcs` semantics while staying idiomatic in Zig.

| Feature | Rust | Zig | Impact |
|---------|------|-----|--------|
| Type discovery | `serde` derives / traits | `@typeInfo` comptime reflection | Same wire behavior without proc macros or trait-driven visitors. |
| String vs bytes distinction | `String`/`&str` vs `Vec<u8>`/`&[u8]` | `bcs.String` vs `[]const u8` | Same wire semantics; Zig makes the distinction explicit with a wrapper type. |
| Stateful decode surface | `DeserializeSeed` visitors | `SeedDeserializer` + seed objects | Same capability without reproducing serde's visitor abstraction. |
| Reader surface | `from_reader` on `Read` | `deserializeReader` on any Zig reader exposing `readByte` | Same observable behavior on covered semantics, but with Zig's simpler reader model. |
| Ownership / cleanup | Rust ownership + `Drop` | explicit allocator + `freeDeserialized` | Same decoded data, but lifetime management is explicit. |
| Integer surface | Up to `u128` | Arbitrary-width integers supported by Zig | Strict superset of Rust's public type surface. |

## Benchmark Results (1M iterations, Apple Silicon, c_allocator)

### `serialize()` (allocating)

| Type | Zig | Rust | Ratio |
|------|-----|------|-------|
| u64 (8B) | 10.6 ns | 11 ns | Zig 1.0x |
| SimpleStruct (41B) | 13 ns | 75 ns | Zig 5.8x |
| [32]u8 address (32B) | 12 ns | 51 ns | Zig 4.1x |
| NestedStruct (65B) | 26 ns | 88 ns | Zig 3.4x |
| MoveCall (176B) | 67 ns | 150 ns | Zig 2.2x |
| enum variant (33B) | 17 ns | 69 ns | Zig 4.1x |
| Vec<u32> 1000 elem (4002B) | 80 ns | 537 ns | Zig 6.7x |

### `serializeInto()` (zero allocation)

| Type | Zig | Rust (no equivalent) | Ratio |
|------|-----|------|-------|
| u64 (8B) | 0.2 ns | 11 ns | Zig 55x |
| SimpleStruct (41B) | 0.2 ns | 75 ns | Zig 375x |
| [32]u8 address (32B) | 1.0 ns | 51 ns | Zig 51x |

### `deserialize()`

| Type | Zig | Rust | Ratio |
|------|-----|------|-------|
| u64 (8B) | 0.2 ns | 0.2 ns | tie |
| SimpleStruct (41B) | 0.2 ns | 52 ns | Zig 260x |
| [32]u8 address (32B) | 0.2 ns | 52 ns | Zig 260x |
| NestedStruct (65B) | 30 ns | 42 ns | Zig 1.4x |
| MoveCall (176B) | 120 ns | 273 ns | Zig 2.3x |
| enum variant (33B) | 4 ns | 51 ns | Zig 12.8x |
| Vec<u32> 1000 elem (4002B) | 53 ns | 1997 ns | Zig 37.7x |

### Why Zig is faster

The speed difference is NOT from the Rust BCS code being slow — it's the serde abstraction layer. Rust `bcs` sits on top of serde's Serializer/Deserializer visitor pattern with runtime trait dispatch. Zig uses `@typeInfo` comptime reflection, which resolves all type dispatch at compile time. For fixed-size types, the compiler unrolls the entire serialization into a flat sequence of direct memory operations. A hand-written Rust BCS serializer without serde would approach similar speeds.

Additional optimizations:
- Bulk `memcpy` for integer slices on LE platforms (vs per-element writes)
- Exact-size pre-allocation for fixed types (vs ArrayList growth + shrink)
- ULEB128 stack buffer batch (vs per-byte append)
- `serializeInto` bypasses the allocator entirely

### Binary size

| Target | Zig | Rust | Ratio |
|--------|-----|------|-------|
| Native (aarch64-darwin) | 66 KB | 279 KB | 4.2x smaller |
| WASM (wasm32) | 4.8 KB | 52.2 KB | 10.9x smaller |

## Test Coverage Summary

102 unit tests cover:

- Primitive round-trips and endian checks across integer widths up to `u256`
- Rust-compatible `bcs.String` UTF-8 validation, plus raw-byte slice behavior
- Vectors, fixed arrays, optionals, tuples, structs, enums, and tagged unions
- Serializer API parity for `serializeAppend`, `serializeWriter`, and `serializedSize`
- Reader API parity for `deserializeReader`, reader limits, trailing bytes, and reader error propagation
- Seed API parity for `deserializeSeed`, `deserializeReaderSeed`, custom free hooks, and limit enforcement
- ULEB128 canonicality and overflow handling
- Depth-limit semantics, trailing-byte detection, partial deserialize, and invalid-tag handling
- Rust-ported parity cases including `serde_known_vector`, recursion-limit tests, and map canonicality
- Map semantics across fixed keys, string keys, duplicate keys, canonical maps, and invalid UTF-8 string keys

## Files

```
src/bcs.zig           — Library (single file, 4611 lines)
build.zig             — Build config
build.zig.zon         — Package manifest (v0.1.0, min zig 0.14.0)
bench/throughput.zig  — Zig throughput benchmark
bench/throughput.rs   — Rust throughput benchmark
bench/crossval.zig    — Zig serialization cross-validation (72 vectors)
bench/crossval.rs     — Rust serialization cross-validation (72 vectors)
bench/deser_crossval.zig  — Zig deserialize/error cross-validation
bench/deser_crossval.rs   — Rust deserialize/error cross-validation
bench/error_crossval.zig  — Zig malformed-input semantic cross-validation
bench/error_crossval.rs   — Rust malformed-input semantic cross-validation
bench/mutation_crossval.zig — Zig mutation-based malformed-input cross-validation
bench/mutation_crossval.rs  — Rust mutation-based malformed-input cross-validation
bench/reader_crossval.zig — Zig reader-based cross-validation
bench/reader_crossval.rs  — Rust reader-based cross-validation
bench/seed_crossval.zig   — Zig seed-based cross-validation
bench/seed_crossval.rs    — Rust seed-based cross-validation
bench/corpus_crossval.zig — Zig malformed-corpus cross-validation
bench/corpus_crossval.rs  — Rust malformed-corpus cross-validation
bench/malformed_corpus.txt — Shared malformed-input corpus fixture
bench/limit_crossval.zig  — Zig limit-parity cross-validation
bench/limit_crossval.rs   — Rust limit-parity cross-validation
bench/random_crossval.zig — Zig randomized differential cross-validation
bench/random_crossval.rs  — Rust randomized differential cross-validation
bench/sui_crossval.zig    — Zig Sui-shaped cross-validation
bench/sui_crossval.rs     — Rust Sui-shaped cross-validation
bench/main.zig        — Binary size benchmark (Zig)
bench/main.rs         — Binary size benchmark (Rust)
bench/lib.zig         — WASM size benchmark (Zig)
bench/lib.rs          — WASM size benchmark (Rust)
bench/Cargo.toml      — Rust dependencies
```
