// BCS Rust throughput benchmark
// Mirrors bench/throughput.zig closely for cross-language comparison.
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::collections::BTreeMap;
use std::time::Instant;

const ITERATIONS: u64 = 250_000;
const WARMUP_ITERATIONS: u64 = 5_000;
const SAMPLE_COUNT: usize = 7;

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

#[derive(Clone, Copy)]
struct SampleResult {
    ns_samples: [u64; SAMPLE_COUNT],
    bytes: u64,
}

#[derive(Clone, Copy)]
struct Stats {
    min: u64,
    median: u64,
    max: u64,
}

// ── Optimization barrier ──────────────────────────────────────────────

fn consume_bytes(bytes: &[u8]) {
    let mut sink = bytes.len() as u64;
    if let Some(&first) = bytes.first() {
        sink = sink.wrapping_add(first as u64);
        sink = sink.wrapping_add((bytes[bytes.len() - 1] as u64) << 8);
    }
    std::hint::black_box(bytes);
    std::hint::black_box(sink);
}

fn consume_value<T>(value: T) {
    std::hint::black_box(value);
}

fn summarize(mut samples: [u64; SAMPLE_COUNT]) -> Stats {
    samples.sort_unstable();
    Stats {
        min: samples[0],
        median: samples[samples.len() / 2],
        max: samples[samples.len() - 1],
    }
}

// ── Benchmark harness ─────────────────────────────────────────────────

fn bench_serialize<T: Serialize>(value: &T) -> SampleResult {
    for _ in 0..WARMUP_ITERATIONS {
        let bytes = bcs::to_bytes(value).unwrap();
        consume_bytes(&bytes);
    }

    let mut ns_samples = [0; SAMPLE_COUNT];
    let mut total_bytes = 0;

    for (sample_idx, sample_ns) in ns_samples.iter_mut().enumerate() {
        let mut sample_bytes = 0_u64;
        let start = Instant::now();
        for _ in 0..ITERATIONS {
            let bytes = bcs::to_bytes(value).unwrap();
            sample_bytes += bytes.len() as u64;
            consume_bytes(&bytes);
        }
        *sample_ns = start.elapsed().as_nanos() as u64;
        if sample_idx == 0 {
            total_bytes = sample_bytes;
        }
    }

    SampleResult {
        ns_samples,
        bytes: total_bytes,
    }
}

fn bench_deserialize<T: DeserializeOwned>(data: &[u8]) -> [u64; SAMPLE_COUNT] {
    for _ in 0..WARMUP_ITERATIONS {
        let decoded: T = bcs::from_bytes(data).unwrap();
        consume_value(decoded);
    }

    let mut ns_samples = [0; SAMPLE_COUNT];
    for sample_ns in &mut ns_samples {
        let start = Instant::now();
        for _ in 0..ITERATIONS {
            let decoded: T = bcs::from_bytes(data).unwrap();
            consume_value(decoded);
        }
        *sample_ns = start.elapsed().as_nanos() as u64;
    }

    ns_samples
}

fn report(
    name: &str,
    ser_samples: [u64; SAMPLE_COUNT],
    de_samples: [u64; SAMPLE_COUNT],
    total_bytes: u64,
) {
    let fiter = ITERATIONS as f64;
    let fbytes = total_bytes as f64;
    let bytes_per_op = total_bytes / ITERATIONS;

    let ser = summarize(ser_samples);
    let de = summarize(de_samples);

    let ser_ns_per_op = ser.median as f64 / fiter;
    let de_ns_per_op = de.median as f64 / fiter;
    let ser_mbs = if ser.median > 0 {
        fbytes / ser.median as f64 * 1000.0
    } else {
        0.0
    };
    let de_mbs = if de.median > 0 {
        fbytes / de.median as f64 * 1000.0
    } else {
        0.0
    };
    let ser_min = ser.min as f64 / fiter;
    let ser_max = ser.max as f64 / fiter;
    let de_min = de.min as f64 / fiter;
    let de_max = de.max as f64 / fiter;

    println!(
        "  {:<24} ser: {:>8.1} ns/op [{:>6.1}-{:>6.1}] ({:>6.0} MB/s)  de: {:>8.1} ns/op [{:>6.1}-{:>6.1}] ({:>6.0} MB/s)  [{} bytes]",
        name, ser_ns_per_op, ser_min, ser_max, ser_mbs, de_ns_per_op, de_min, de_max, de_mbs, bytes_per_op
    );
}

// ── Main ──────────────────────────────────────────────────────────────

fn main() {
    println!(
        "\n=== BCS-Rust Throughput Benchmark ({} iterations/sample, {} samples, median shown) ===\n",
        ITERATIONS, SAMPLE_COUNT
    );

    {
        let value = SimpleStruct {
            a: 42,
            b: true,
            c: [0xab; 32],
        };
        let data = bcs::to_bytes(&value).unwrap();
        let de = bench_deserialize::<SimpleStruct>(&data);
        let ser = bench_serialize(&value);
        report("simple_struct", ser.ns_samples, de, ser.bytes);
    }

    {
        let value = NestedStruct {
            id: 999999,
            name: "hello_world_test".into(),
            scores: vec![100, 200, 300, 400, 500],
            active: true,
            metadata: InnerMeta {
                version: 3,
                flags: 0xDEADBEEF,
                tag: *b"METATAG\x00",
            },
        };
        let data = bcs::to_bytes(&value).unwrap();
        let de = bench_deserialize::<NestedStruct>(&data);
        let ser = bench_serialize(&value);
        report("nested_struct", ser.ns_samples, de, ser.bytes);
    }

    {
        let value = MoveCall {
            sender: [0x01; 32],
            package: [0x02; 32],
            module_name: "coin".into(),
            function_name: "transfer".into(),
            type_args: vec!["0x2::sui::SUI".into(), "0x2::coin::Coin".into()],
            args: vec![vec![0xaa; 32], vec![0xbb; 16]],
            gas_budget: 50_000_000,
            gas_price: 1000,
        };
        let data = bcs::to_bytes(&value).unwrap();
        let de = bench_deserialize::<MoveCall>(&data);
        let ser = bench_serialize(&value);
        report("move_call", ser.ns_samples, de, ser.bytes);
    }

    {
        let value = Enum::WithBytes([0xff; 32]);
        let data = bcs::to_bytes(&value).unwrap();
        let de = bench_deserialize::<Enum>(&data);
        let ser = bench_serialize(&value);
        report("enum_variant", ser.ns_samples, de, ser.bytes);
    }

    {
        let value: u64 = 0xDEADBEEFCAFEBABE;
        let data = bcs::to_bytes(&value).unwrap();
        let de = bench_deserialize::<u64>(&data);
        let ser = bench_serialize(&value);
        report("u64", ser.ns_samples, de, ser.bytes);
    }

    {
        let value: Vec<u32> = (0..1000).collect();
        let data = bcs::to_bytes(&value).unwrap();
        let de = bench_deserialize::<Vec<u32>>(&data);
        let ser = bench_serialize(&value);
        report("vec_1000_u32", ser.ns_samples, de, ser.bytes);
    }

    {
        let value: [u8; 32] = [0x42; 32];
        let data = bcs::to_bytes(&value).unwrap();
        let de = bench_deserialize::<[u8; 32]>(&data);
        let ser = bench_serialize(&value);
        report("address_32b", ser.ns_samples, de, ser.bytes);
    }

    {
        let mut value = BTreeMap::<u64, u64>::new();
        for i in 0..64_u64 {
            let permuted = (i * 17) % 64;
            value.insert(permuted * 3 + 1, i * 101);
        }
        let data = bcs::to_bytes(&value).unwrap();
        let de = bench_deserialize::<BTreeMap<u64, u64>>(&data);
        let ser = bench_serialize(&value);
        report("map_u64_u64_x64", ser.ns_samples, de, ser.bytes);
    }

    {
        let mut value = BTreeMap::<String, u64>::new();
        for (i, key) in [
            "kappa", "alpha", "theta", "beta", "gamma", "delta", "omega", "eta",
        ]
        .iter()
        .enumerate()
        {
            value.insert((*key).to_owned(), ((i + 1) * 111) as u64);
        }
        let data = bcs::to_bytes(&value).unwrap();
        let de = bench_deserialize::<BTreeMap<String, u64>>(&data);
        let ser = bench_serialize(&value);
        report("map_str_u64_x8", ser.ns_samples, de, ser.bytes);
    }

    {
        let mut value = BTreeMap::<[u8; 32], u64>::new();
        for i in 0..64_u64 {
            let permuted = (i * 17) % 64;
            let mut key = [0_u8; 32];
            key[0] = permuted as u8;
            key[31] = (permuted as u8) ^ 0x5a;
            value.insert(key, i * 131);
        }
        let data = bcs::to_bytes(&value).unwrap();
        let de = bench_deserialize::<BTreeMap<[u8; 32], u64>>(&data);
        let ser = bench_serialize(&value);
        report("map_addr_u64_x64", ser.ns_samples, de, ser.bytes);
    }

    println!();
}
