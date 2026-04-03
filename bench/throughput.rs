// BCS Rust throughput benchmark
// Equivalent to bench/throughput.zig — same types, same iteration count
use serde::{Deserialize, Serialize};
use std::time::Instant;

const ITERATIONS: u64 = 1_000_000;

// ── Test types ────────────────────────────────────────────────────────

#[derive(Serialize, Deserialize, Clone)]
struct SimpleStruct {
    a: u64,
    b: bool,
    c: [u8; 32],
}

#[derive(Serialize, Deserialize, Clone)]
struct InnerMeta {
    version: u16,
    flags: u64,
    tag: [u8; 8],
}

#[derive(Serialize, Deserialize, Clone)]
struct NestedStruct {
    id: u64,
    name: String,
    scores: Vec<u32>,
    active: bool,
    metadata: InnerMeta,
}

#[derive(Serialize, Deserialize, Clone)]
struct MoveCall {
    sender: [u8; 32],
    package: [u8; 32],
    module_name: String,
    function_name: String,
    type_args: Vec<String>,
    args: Vec<Vec<u8>>,
    gas_budget: u64,
    gas_price: u64,
}

#[derive(Serialize, Deserialize, Clone)]
enum Enum {
    Unit,
    WithU64(u64),
    WithBytes([u8; 32]),
    WithString(String),
}

// ── Benchmark harness ─────────────────────────────────────────────────

fn bench_serialize<T: Serialize>(val: &T) -> (u64, u64) {
    let mut total_bytes: u64 = 0;
    // Warm up
    for _ in 0..1000 {
        let bytes = bcs::to_bytes(val).unwrap();
        std::hint::black_box(&bytes);
    }
    let start = Instant::now();
    for _ in 0..ITERATIONS {
        let bytes = bcs::to_bytes(val).unwrap();
        total_bytes += bytes.len() as u64;
        std::hint::black_box(&bytes);
    }
    (start.elapsed().as_nanos() as u64, total_bytes)
}

fn bench_deserialize<T: for<'de> Deserialize<'de>>(data: &[u8]) -> u64 {
    // Warm up
    for _ in 0..1000 {
        let decoded: T = bcs::from_bytes(data).unwrap();
        std::hint::black_box(decoded);
    }
    let start = Instant::now();
    for _ in 0..ITERATIONS {
        let decoded: T = bcs::from_bytes(data).unwrap();
        std::hint::black_box(decoded);
    }
    start.elapsed().as_nanos() as u64
}

fn report(name: &str, ser_ns: u64, de_ns: u64, total_bytes: u64) {
    let fiter = ITERATIONS as f64;
    let fser = ser_ns as f64;
    let fde = de_ns as f64;
    let fbytes = total_bytes as f64;
    let bytes_per_op = total_bytes / ITERATIONS;

    let ser_ns_per_op = fser / fiter;
    let de_ns_per_op = fde / fiter;
    let ser_mbs = if ser_ns > 0 { fbytes / fser * 1000.0 } else { 0.0 };
    let de_mbs = if de_ns > 0 { fbytes / fde * 1000.0 } else { 0.0 };

    println!(
        "  {:<24} ser: {:>8.1} ns/op ({:>6.0} MB/s)  de: {:>8.1} ns/op ({:>6.0} MB/s)  [{} bytes]",
        name, ser_ns_per_op, ser_mbs, de_ns_per_op, de_mbs, bytes_per_op
    );
}

// ── Main ──────────────────────────────────────────────────────────────

fn main() {
    println!("\n=== BCS-Rust Throughput Benchmark ({} iterations) ===\n", ITERATIONS);

    // 1. SimpleStruct
    {
        let val = SimpleStruct { a: 42, b: true, c: [0xab; 32] };
        let data = bcs::to_bytes(&val).unwrap();
        let (ser_ns, total_bytes) = bench_serialize(&val);
        let de_ns = bench_deserialize::<SimpleStruct>(&data);
        report("simple_struct", ser_ns, de_ns, total_bytes);
    }

    // 2. NestedStruct
    {
        let val = NestedStruct {
            id: 999999,
            name: "hello_world_test".into(),
            scores: vec![100, 200, 300, 400, 500],
            active: true,
            metadata: InnerMeta { version: 3, flags: 0xDEADBEEF, tag: *b"METATAG\x00" },
        };
        let data = bcs::to_bytes(&val).unwrap();
        let (ser_ns, total_bytes) = bench_serialize(&val);
        let de_ns = bench_deserialize::<NestedStruct>(&data);
        report("nested_struct", ser_ns, de_ns, total_bytes);
    }

    // 3. MoveCall
    {
        let val = MoveCall {
            sender: [0x01; 32],
            package: [0x02; 32],
            module_name: "coin".into(),
            function_name: "transfer".into(),
            type_args: vec!["0x2::sui::SUI".into(), "0x2::coin::Coin".into()],
            args: vec![vec![0xaa; 32], vec![0xbb; 16]],
            gas_budget: 50_000_000,
            gas_price: 1000,
        };
        let data = bcs::to_bytes(&val).unwrap();
        let (ser_ns, total_bytes) = bench_serialize(&val);
        let de_ns = bench_deserialize::<MoveCall>(&data);
        report("move_call", ser_ns, de_ns, total_bytes);
    }

    // 4. Enum variant
    {
        let val = Enum::WithBytes([0xff; 32]);
        let data = bcs::to_bytes(&val).unwrap();
        let (ser_ns, total_bytes) = bench_serialize(&val);
        let de_ns = bench_deserialize::<Enum>(&data);
        report("enum_variant", ser_ns, de_ns, total_bytes);
    }

    // 5. u64 primitive
    {
        let val: u64 = 0xDEADBEEFCAFEBABE;
        let data = bcs::to_bytes(&val).unwrap();
        let (ser_ns, total_bytes) = bench_serialize(&val);
        let de_ns = bench_deserialize::<u64>(&data);
        report("u64", ser_ns, de_ns, total_bytes);
    }

    // 6. Large vector
    {
        let val: Vec<u32> = (0..1000).collect();
        let data = bcs::to_bytes(&val).unwrap();
        let (ser_ns, total_bytes) = bench_serialize(&val);
        let de_ns = bench_deserialize::<Vec<u32>>(&data);
        report("vec_1000_u32", ser_ns, de_ns, total_bytes);
    }

    // 7. [32]u8 address
    {
        let val: [u8; 32] = [0x42; 32];
        let data = bcs::to_bytes(&val).unwrap();
        let (ser_ns, total_bytes) = bench_serialize(&val);
        let de_ns = bench_deserialize::<[u8; 32]>(&data);
        report("address_32b", ser_ns, de_ns, total_bytes);
    }

    println!();
}
