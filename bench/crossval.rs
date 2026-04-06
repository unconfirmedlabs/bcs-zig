// Cross-language BCS validation — Rust reference output
// Serializes comprehensive test vectors and prints hex for comparison with Zig
use serde::{ser::SerializeMap, Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Serialize, Deserialize)]
struct SimpleStruct {
    a: u64,
    b: bool,
    c: [u8; 32],
}

#[derive(Serialize, Deserialize)]
struct NestedStruct {
    inner: InnerStruct,
    flag: bool,
}

#[derive(Serialize, Deserialize)]
struct InnerStruct {
    x: u32,
    y: u32,
}

#[derive(Serialize, Deserialize)]
enum TestEnum {
    Unit,
    WithU64(u64),
    WithBytes([u8; 4]),
    WithStruct { a: u16, b: u8 },
}

#[derive(Serialize, Deserialize)]
struct ComplexStruct {
    id: u64,
    name: String,
    scores: Vec<u32>,
    active: bool,
    metadata: [u8; 8],
}

#[derive(Serialize, Deserialize)]
struct MapStruct {
    data: BTreeMap<u8, u16>,
}

#[derive(Serialize, Deserialize)]
struct WithOption {
    a: u32,
    b: Option<u64>,
    c: u8,
}

#[derive(Serialize, Deserialize)]
struct TupleStruct(i8, String);

struct DuplicateU8Map;

impl Serialize for DuplicateU8Map {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let mut map = serializer.serialize_map(Some(3))?;
        map.serialize_entry(&2u8, &200u16)?;
        map.serialize_entry(&1u8, &100u16)?;
        map.serialize_entry(&1u8, &999u16)?;
        map.end()
    }
}

struct DuplicateStringMap;

impl Serialize for DuplicateStringMap {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let mut map = serializer.serialize_map(Some(3))?;
        map.serialize_entry("b", &2u32)?;
        map.serialize_entry("a", &1u32)?;
        map.serialize_entry("a", &9u32)?;
        map.end()
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect::<Vec<_>>()
        .join("")
}

fn emit(name: &str, bytes: &[u8]) {
    println!("{}={}", name, hex(bytes));
}

fn main() {
    // ── Primitives ────────────────────────────────────────────────
    emit("bool_true", &bcs::to_bytes(&true).unwrap());
    emit("bool_false", &bcs::to_bytes(&false).unwrap());
    emit("u8_0", &bcs::to_bytes(&0u8).unwrap());
    emit("u8_255", &bcs::to_bytes(&255u8).unwrap());
    emit("u16_0", &bcs::to_bytes(&0u16).unwrap());
    emit("u16_max", &bcs::to_bytes(&u16::MAX).unwrap());
    emit("u16_0x0102", &bcs::to_bytes(&0x0102u16).unwrap());
    emit("u32_0", &bcs::to_bytes(&0u32).unwrap());
    emit("u32_max", &bcs::to_bytes(&u32::MAX).unwrap());
    emit("u32_305419896", &bcs::to_bytes(&305419896u32).unwrap());
    emit("u64_0", &bcs::to_bytes(&0u64).unwrap());
    emit("u64_max", &bcs::to_bytes(&u64::MAX).unwrap());
    emit("u64_42", &bcs::to_bytes(&42u64).unwrap());
    emit("u128_0", &bcs::to_bytes(&0u128).unwrap());
    emit("u128_max", &bcs::to_bytes(&u128::MAX).unwrap());
    emit("u128_1", &bcs::to_bytes(&1u128).unwrap());

    // Signed integers
    emit("i8_neg1", &bcs::to_bytes(&(-1i8)).unwrap());
    emit("i8_min", &bcs::to_bytes(&i8::MIN).unwrap());
    emit("i8_max", &bcs::to_bytes(&i8::MAX).unwrap());
    emit("i16_neg4660", &bcs::to_bytes(&(-4660i16)).unwrap());
    emit("i16_min", &bcs::to_bytes(&i16::MIN).unwrap());
    emit("i32_neg1", &bcs::to_bytes(&(-1i32)).unwrap());
    emit("i32_min", &bcs::to_bytes(&i32::MIN).unwrap());
    emit("i64_neg1", &bcs::to_bytes(&(-1i64)).unwrap());
    emit("i64_min", &bcs::to_bytes(&i64::MIN).unwrap());
    emit("i128_neg1", &bcs::to_bytes(&(-1i128)).unwrap());
    emit("i128_min", &bcs::to_bytes(&i128::MIN).unwrap());

    // ── Strings ───────────────────────────────────────────────────
    emit("string_empty", &bcs::to_bytes(&"").unwrap());
    emit("string_hello", &bcs::to_bytes(&"hello").unwrap());
    emit("string_diem", &bcs::to_bytes(&"diem").unwrap());
    emit("string_utf8", &bcs::to_bytes(&"café").unwrap());

    // ── Vectors ───────────────────────────────────────────────────
    emit("vec_empty_u8", &bcs::to_bytes(&Vec::<u8>::new()).unwrap());
    emit("vec_u8_3", &bcs::to_bytes(&vec![1u8, 2, 3]).unwrap());
    emit("vec_u16_2", &bcs::to_bytes(&vec![1u16, 2]).unwrap());
    emit(
        "vec_u32_5",
        &bcs::to_bytes(&vec![100u32, 200, 300, 400, 500]).unwrap(),
    );
    emit("vec_u64_1", &bcs::to_bytes(&vec![0xDEADBEEFu64]).unwrap());
    emit(
        "vec_string_2",
        &bcs::to_bytes(&vec!["abc".to_string(), "def".to_string()]).unwrap(),
    );
    emit(
        "vec_vec_u8",
        &bcs::to_bytes(&vec![vec![1u8, 2], vec![3u8, 4, 5]]).unwrap(),
    );

    // ── Fixed arrays ──────────────────────────────────────────────
    emit(
        "arr_u8_4",
        &bcs::to_bytes(&[0xAAu8, 0xBB, 0xCC, 0xDD]).unwrap(),
    );
    emit("arr_u16_3", &bcs::to_bytes(&[1u16, 2, 3]).unwrap());
    emit(
        "arr_u32_2",
        &bcs::to_bytes(&[0x12345678u32, 0xABCDEF01]).unwrap(),
    );
    emit("arr_32b", &bcs::to_bytes(&[0x42u8; 32]).unwrap());

    // ── Optionals ─────────────────────────────────────────────────
    emit("opt_some_u8", &bcs::to_bytes(&Some(42u8)).unwrap());
    emit("opt_none_u8", &bcs::to_bytes(&Option::<u8>::None).unwrap());
    emit(
        "opt_some_u64",
        &bcs::to_bytes(&Some(0xCAFEBABEu64)).unwrap(),
    );
    emit(
        "opt_none_u64",
        &bcs::to_bytes(&Option::<u64>::None).unwrap(),
    );
    emit(
        "opt_some_string",
        &bcs::to_bytes(&Some("hi".to_string())).unwrap(),
    );
    emit(
        "opt_none_string",
        &bcs::to_bytes(&Option::<String>::None).unwrap(),
    );
    emit("opt_opt_some", &bcs::to_bytes(&Some(Some(99u8))).unwrap());
    emit(
        "opt_opt_none_inner",
        &bcs::to_bytes(&Some(Option::<u8>::None)).unwrap(),
    );
    emit(
        "opt_opt_none_outer",
        &bcs::to_bytes(&Option::<Option<u8>>::None).unwrap(),
    );

    // ── Structs ───────────────────────────────────────────────────
    emit(
        "simple_struct",
        &bcs::to_bytes(&SimpleStruct {
            a: 42,
            b: true,
            c: [0xab; 32],
        })
        .unwrap(),
    );

    emit(
        "nested_struct",
        &bcs::to_bytes(&NestedStruct {
            inner: InnerStruct { x: 100, y: 200 },
            flag: false,
        })
        .unwrap(),
    );

    emit(
        "complex_struct",
        &bcs::to_bytes(&ComplexStruct {
            id: 999999,
            name: "hello_world_test".to_string(),
            scores: vec![100, 200, 300, 400, 500],
            active: true,
            metadata: *b"METATAG\x00",
        })
        .unwrap(),
    );

    emit(
        "with_option_some",
        &bcs::to_bytes(&WithOption {
            a: 10,
            b: Some(20),
            c: 30,
        })
        .unwrap(),
    );

    emit(
        "with_option_none",
        &bcs::to_bytes(&WithOption {
            a: 10,
            b: None,
            c: 30,
        })
        .unwrap(),
    );

    // ── Enums ─────────────────────────────────────────────────────
    emit("enum_unit", &bcs::to_bytes(&TestEnum::Unit).unwrap());
    emit(
        "enum_with_u64",
        &bcs::to_bytes(&TestEnum::WithU64(0x1234)).unwrap(),
    );
    emit(
        "enum_with_bytes",
        &bcs::to_bytes(&TestEnum::WithBytes([0xAA, 0xBB, 0xCC, 0xDD])).unwrap(),
    );
    emit(
        "enum_with_struct",
        &bcs::to_bytes(&TestEnum::WithStruct { a: 1000, b: 42 }).unwrap(),
    );

    // ── Tuples ────────────────────────────────────────────────────
    emit(
        "tuple_i8_string",
        &bcs::to_bytes(&TupleStruct(-1, "diem".to_string())).unwrap(),
    );
    emit("tuple_pair", &bcs::to_bytes(&(42u32, true)).unwrap());

    // ── Maps ──────────────────────────────────────────────────────
    let mut map1 = BTreeMap::new();
    map1.insert(1u8, 100u16);
    map1.insert(3u8, 300u16);
    map1.insert(2u8, 200u16);
    emit("map_u8_u16", &bcs::to_bytes(&map1).unwrap());

    let mut map_empty: BTreeMap<u8, u8> = BTreeMap::new();
    emit("map_empty", &bcs::to_bytes(&map_empty).unwrap());

    let mut map_str = BTreeMap::new();
    map_str.insert("b".to_string(), 2u32);
    map_str.insert("a".to_string(), 1u32);
    map_str.insert("c".to_string(), 3u32);
    emit("map_string_u32", &bcs::to_bytes(&map_str).unwrap());
    emit(
        "map_u8_u16_dupe_keep_first",
        &bcs::to_bytes(&DuplicateU8Map).unwrap(),
    );
    emit(
        "map_string_u32_dupe_keep_first",
        &bcs::to_bytes(&DuplicateStringMap).unwrap(),
    );

    // ── Boundary values ───────────────────────────────────────────
    emit(
        "u64_deadbeef",
        &bcs::to_bytes(&0xDEADBEEFCAFEBABEu64).unwrap(),
    );

    // Sui-relevant: 32-byte addresses
    emit("sui_addr_zeros", &bcs::to_bytes(&[0u8; 32]).unwrap());
    emit("sui_addr_ones", &bcs::to_bytes(&[0xFFu8; 32]).unwrap());
    emit(
        "sui_addr_sequential",
        &bcs::to_bytes(&{
            let mut a = [0u8; 32];
            for i in 0..32 {
                a[i] = i as u8;
            }
            a
        })
        .unwrap(),
    );

    // Large vector
    let large_vec: Vec<u32> = (0..100).collect();
    emit("vec_u32_100", &bcs::to_bytes(&large_vec).unwrap());
}
