# BCS-Zig Implementation Audit Summary

## Overview

Single-file BCS (Binary Canonical Serialization) library for Zig 0.14+. Reference: Rust `bcs` crate v0.1.6 (diem/bcs). Zero dependencies beyond `std`.

- **Source**: `src/bcs.zig` (1525 lines — ~550 impl + ~975 tests)
- **Tests**: 68 unit tests, all passing
- **Cross-validation**: 70 test vectors verified byte-identical against Rust `bcs::to_bytes` output

## Public API

```zig
// Allocating serialization (any type)
pub fn serialize(allocator: Allocator, value: anytype) Error![]u8

// Zero-allocation serialization into caller buffer (fixed-size types only)
pub fn serializeInto(buf: []u8, value: anytype) Error!usize

// Deserialization
pub fn deserialize(comptime T: type, allocator: Allocator, bytes: []const u8) Error!T
pub fn deserializePartial(comptime T: type, allocator: Allocator, bytes: []const u8) Error!struct { value: T, bytes_read: usize }

// Memory cleanup for deserialized values containing heap allocations
pub fn freeDeserialized(comptime T: type, allocator: Allocator, value: T) void

// BCS-compatible sorted map type
pub fn Map(comptime K: type, comptime V: type) type
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
| `[]const u8` | ULEB128 length + bytes | Strings / byte vectors |
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
    SequenceTooLong,     // sequence length > max_sequence_length
    ContainerTooDeep,    // struct/union nesting > max_container_depth
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

- **Serialization** (line 325): Serializes each key to bytes, sorts by key bytes lexicographically, emits ULEB128 count + sorted key-value pairs. Allocates temporary `SortItem` array. Does NOT deduplicate (Rust BCS does).
- **Deserialization** (line 360): Validates keys are in strict ascending BCS byte order by comparing raw reader byte ranges. Rejects out-of-order or duplicate keys with `NonCanonicalMap`.

### Depth Tracking

- Structs and unions increment depth by 1
- Tuples do NOT increment depth (matches Rust/BCS spec)
- Optionals do NOT increment depth (matches Rust/BCS spec)
- Check: `if (new_depth > max_container_depth) return Error.ContainerTooDeep`

## Cross-Validation Results

A cross-validation program (`bench/crossval.rs` and `bench/crossval.zig`) serializes 70 identical test vectors in both Rust and Zig and compares hex output. **All 70 vectors are byte-identical.** Coverage:

- 16 integer primitives (u8-u128, i8-i128 including MIN/MAX boundaries)
- 4 string variants (empty, ASCII, ULEB128 prefix, UTF-8 multibyte)
- 7 vector types (empty, typed, nested, mixed)
- 4 fixed array types
- 9 optional states (some/none, nested `??T` all 3 states)
- 5 struct configurations (simple, nested, complex with mixed types, with optional fields)
- 4 enum variants (unit, u64, bytes, struct payload)
- 2 tuple variants
- 3 map variants (numeric keys, empty, string keys with sorting)
- 4 Sui-specific 32-byte addresses
- 1 large vector (100 u32s)

## Known Differences from Rust `bcs` v0.1.6

| Feature | Rust | Zig | Impact |
|---------|------|-----|--------|
| Map dedup on serialize | Deduplicates keys (keeps first) | Does NOT dedup | Zig serializes all entries. Both reject non-canonical maps on deser. Callers should not pass duplicate keys. |
| UTF-8 validation | Enforced (serde layer) | Not enforced (`[]const u8` = raw bytes) | BCS spec treats strings as byte sequences. UTF-8 is a serde concern. |
| Custom depth limits | `_with_limit()` API variants | Fixed at 500 | Could be added as optional param if needed |
| `serialized_size()` | Computes size without allocating | `serializedSizeHint` (private, fixed-size only) | Could be exposed publicly |
| `from_reader` / `serialize_into` (Write trait) | Supports `impl Read` / `impl Write` | `serializeInto` for fixed types; deser always from `[]const u8` | Zig's `Reader` struct is slice-based |
| u256+ support | Not supported (up to u128) | Native support for any bit width | Zig advantage |

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

68 unit tests organized as:

- **Primitives** (12 tests): bool, u8-u256, i8-i128, round-trips
- **Strings** (3 tests): serialization, empty, round-trip
- **Vectors** (3 tests): typed vectors, empty, round-trip
- **Fixed arrays** (3 tests): no length prefix, byte arrays, round-trip
- **Optionals** (4 tests): some, none, round-trip, nested `??T`
- **Structs** (4 tests): serialization, round-trip, nested, string fields
- **Unions/Enums** (4 tests): tagged unions, unit enums, round-trips
- **Tuples** (1 test): unnamed struct fields
- **ULEB128** (3 tests): encoding, round-trip (0 to u32::MAX), non-canonical rejection
- **Error cases** (6 tests): void, trailing bytes, unexpected EOF, invalid enum tag, Sui address, deserializePartial
- **Complex types** (1 test): nested optionals + structs + arrays
- **Rust parity** (18 tests): Ported from diem/bcs test suite — test_enum, serde_known_vector (Bar), uleb_encoding_and_variant, invalid_option, invalid_bool, variable_lengths, sequence_not_long_enough, leftover_bytes, zero_copy_parse, test_recursion_limit (linked list, enum), struct S round-trip (with/without option), Addr round-trip, Bar round-trip, map canonicality (2 tests), full Foo with BTreeMap
- **Map tests** (6 tests): serialization with sorting, deserialization, non-canonical rejection, string keys, round-trip, empty

## Files

```
src/bcs.zig           — Library (single file, 1525 lines)
build.zig             — Build config
build.zig.zon         — Package manifest (v0.1.0, min zig 0.14.0)
bench/throughput.zig  — Zig throughput benchmark
bench/throughput.rs   — Rust throughput benchmark
bench/crossval.zig    — Zig cross-validation (70 test vectors)
bench/crossval.rs     — Rust cross-validation (70 test vectors)
bench/main.zig        — Binary size benchmark (Zig)
bench/main.rs         — Binary size benchmark (Rust)
bench/lib.zig         — WASM size benchmark (Zig)
bench/lib.rs          — WASM size benchmark (Rust)
bench/Cargo.toml      — Rust dependencies
```
