use serde::{ser::SerializeMap, Deserialize, Serialize};
use std::collections::BTreeMap;

const SER_CASES: usize = 128;
const DE_CASES: usize = 256;
const SEED: u64 = 0x5eed_cafe_d00d_f00d;
const ASCII: &[u8] = b"abcxyz012_";

#[derive(Clone, Debug, Serialize, Deserialize)]
struct FuzzStruct {
    a: u64,
    b: bool,
    c: Vec<u16>,
    d: Option<[u8; 4]>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
enum FuzzEnum {
    Unit,
    U64(u64),
    Bytes([u8; 4]),
    Pair { a: u16, b: u8 },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct DeepStruct {
    label: String,
    nested: FuzzStruct,
    variant: FuzzEnum,
    tags: Vec<String>,
}

#[derive(Clone, Debug)]
struct EntryMapU8U16 {
    entries: Vec<(u8, u16)>,
}

impl Serialize for EntryMapU8U16 {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let mut map = serializer.serialize_map(Some(self.entries.len()))?;
        for (k, v) in &self.entries {
            map.serialize_entry(k, v)?;
        }
        map.end()
    }
}

#[derive(Clone, Debug)]
struct EntryMapStringU32 {
    entries: Vec<(String, u32)>,
}

impl Serialize for EntryMapStringU32 {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let mut map = serializer.serialize_map(Some(self.entries.len()))?;
        for (k, v) in &self.entries {
            map.serialize_entry(k, v)?;
        }
        map.end()
    }
}

#[derive(Clone, Debug)]
struct Rng {
    state: u64,
}

impl Rng {
    fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    fn next_u64(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn next_bool(&mut self) -> bool {
        self.next_u64() & 1 == 1
    }

    fn next_u8(&mut self) -> u8 {
        self.next_u64() as u8
    }

    fn next_u16(&mut self) -> u16 {
        self.next_u64() as u16
    }

    fn next_u32(&mut self) -> u32 {
        self.next_u64() as u32
    }

    fn range(&mut self, limit: usize) -> usize {
        if limit == 0 {
            0
        } else {
            (self.next_u64() % limit as u64) as usize
        }
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect::<Vec<_>>()
        .join("")
}

fn emit_bytes(name: &str, bytes: &[u8]) {
    println!("{name}={}", hex(bytes));
}

fn emit_status<T>(name: &str, bytes: &[u8])
where
    T: Serialize + for<'de> Deserialize<'de>,
{
    match bcs::from_bytes::<T>(bytes) {
        Ok(value) => {
            let encoded = bcs::to_bytes(&value).unwrap();
            println!("{name}=ok:{}", hex(&encoded));
        }
        Err(_) => println!("{name}=err"),
    }
}

fn gen_bytes(rng: &mut Rng, max_len: usize) -> Vec<u8> {
    let len = rng.range(max_len + 1);
    (0..len).map(|_| rng.next_u8()).collect()
}

fn gen_ascii_string(rng: &mut Rng, max_len: usize) -> String {
    let len = rng.range(max_len + 1);
    let bytes = (0..len)
        .map(|_| ASCII[rng.range(ASCII.len())])
        .collect::<Vec<_>>();
    String::from_utf8(bytes).unwrap()
}

fn gen_u16_vec(rng: &mut Rng, max_len: usize) -> Vec<u16> {
    let len = rng.range(max_len + 1);
    (0..len).map(|_| rng.next_u16()).collect()
}

fn gen_vec_vec_u8(rng: &mut Rng, max_outer: usize, max_inner: usize) -> Vec<Vec<u8>> {
    let len = rng.range(max_outer + 1);
    (0..len).map(|_| gen_bytes(rng, max_inner)).collect()
}

fn gen_string_vec(rng: &mut Rng, max_len: usize, max_str_len: usize) -> Vec<String> {
    let len = rng.range(max_len + 1);
    (0..len)
        .map(|_| gen_ascii_string(rng, max_str_len))
        .collect()
}

fn gen_opt_u64(rng: &mut Rng) -> Option<u64> {
    if rng.next_bool() {
        Some(rng.next_u64())
    } else {
        None
    }
}

fn gen_arr4(rng: &mut Rng) -> [u8; 4] {
    [rng.next_u8(), rng.next_u8(), rng.next_u8(), rng.next_u8()]
}

fn gen_fuzz_struct(rng: &mut Rng) -> FuzzStruct {
    FuzzStruct {
        a: rng.next_u64(),
        b: rng.next_bool(),
        c: gen_u16_vec(rng, 6),
        d: if rng.next_bool() {
            Some(gen_arr4(rng))
        } else {
            None
        },
    }
}

fn gen_deep_struct(rng: &mut Rng) -> DeepStruct {
    DeepStruct {
        label: gen_ascii_string(rng, 10),
        nested: gen_fuzz_struct(rng),
        variant: gen_fuzz_enum(rng),
        tags: gen_string_vec(rng, 5, 6),
    }
}

fn gen_fuzz_enum(rng: &mut Rng) -> FuzzEnum {
    match rng.range(4) {
        0 => FuzzEnum::Unit,
        1 => FuzzEnum::U64(rng.next_u64()),
        2 => FuzzEnum::Bytes(gen_arr4(rng)),
        _ => FuzzEnum::Pair {
            a: rng.next_u16(),
            b: rng.next_u8(),
        },
    }
}

fn gen_entry_map_u8_u16(rng: &mut Rng, max_len: usize) -> EntryMapU8U16 {
    let len = rng.range(max_len + 1);
    EntryMapU8U16 {
        entries: (0..len)
            .map(|_| ((rng.next_u8() % 5), rng.next_u16()))
            .collect(),
    }
}

fn gen_entry_map_string_u32(rng: &mut Rng, max_len: usize) -> EntryMapStringU32 {
    let len = rng.range(max_len + 1);
    EntryMapStringU32 {
        entries: (0..len)
            .map(|_| (gen_ascii_string(rng, 4), rng.next_u32()))
            .collect(),
    }
}

fn main() {
    let mut ser_rng = Rng::new(SEED);

    for i in 0..SER_CASES {
        emit_bytes(
            &format!("ser_bool_{i:03}"),
            &bcs::to_bytes(&ser_rng.next_bool()).unwrap(),
        );
        emit_bytes(
            &format!("ser_u64_{i:03}"),
            &bcs::to_bytes(&ser_rng.next_u64()).unwrap(),
        );
        emit_bytes(
            &format!("ser_i64_{i:03}"),
            &bcs::to_bytes(&(ser_rng.next_u64() as i64)).unwrap(),
        );
        emit_bytes(
            &format!("ser_string_{i:03}"),
            &bcs::to_bytes(&gen_ascii_string(&mut ser_rng, 12)).unwrap(),
        );
        emit_bytes(
            &format!("ser_bytes_{i:03}"),
            &bcs::to_bytes(&gen_bytes(&mut ser_rng, 16)).unwrap(),
        );
        emit_bytes(
            &format!("ser_vec_u16_{i:03}"),
            &bcs::to_bytes(&gen_u16_vec(&mut ser_rng, 8)).unwrap(),
        );
        emit_bytes(
            &format!("ser_vec_vec_u8_{i:03}"),
            &bcs::to_bytes(&gen_vec_vec_u8(&mut ser_rng, 4, 8)).unwrap(),
        );
        emit_bytes(
            &format!("ser_opt_u64_{i:03}"),
            &bcs::to_bytes(&gen_opt_u64(&mut ser_rng)).unwrap(),
        );
        emit_bytes(
            &format!("ser_struct_{i:03}"),
            &bcs::to_bytes(&gen_fuzz_struct(&mut ser_rng)).unwrap(),
        );
        emit_bytes(
            &format!("ser_enum_{i:03}"),
            &bcs::to_bytes(&gen_fuzz_enum(&mut ser_rng)).unwrap(),
        );
        emit_bytes(
            &format!("ser_map_u8_u16_{i:03}"),
            &bcs::to_bytes(&gen_entry_map_u8_u16(&mut ser_rng, 6)).unwrap(),
        );
        emit_bytes(
            &format!("ser_map_string_u32_{i:03}"),
            &bcs::to_bytes(&gen_entry_map_string_u32(&mut ser_rng, 6)).unwrap(),
        );
        emit_bytes(
            &format!("ser_deep_struct_{i:03}"),
            &bcs::to_bytes(&gen_deep_struct(&mut ser_rng)).unwrap(),
        );
    }

    let mut de_rng = Rng::new(SEED ^ 0x9e37_79b9_7f4a_7c15);

    for i in 0..DE_CASES {
        let bytes = gen_bytes(&mut de_rng, 24);
        emit_status::<bool>(&format!("de_bool_{i:03}"), &bytes);
        emit_status::<Option<u8>>(&format!("de_opt_u8_{i:03}"), &bytes);
        emit_status::<String>(&format!("de_string_{i:03}"), &bytes);
        emit_status::<Vec<u8>>(&format!("de_vec_u8_{i:03}"), &bytes);
        emit_status::<Vec<u16>>(&format!("de_vec_u16_{i:03}"), &bytes);
        emit_status::<FuzzEnum>(&format!("de_enum_{i:03}"), &bytes);
        emit_status::<(u32, bool)>(&format!("de_tuple_pair_{i:03}"), &bytes);
        emit_status::<BTreeMap<u8, ()>>(&format!("de_map_u8_unit_{i:03}"), &bytes);
        emit_status::<FuzzStruct>(&format!("de_struct_{i:03}"), &bytes);
        emit_status::<DeepStruct>(&format!("de_deep_struct_{i:03}"), &bytes);
        emit_status::<BTreeMap<u8, u16>>(&format!("de_map_u8_u16_{i:03}"), &bytes);
        emit_status::<BTreeMap<String, u32>>(&format!("de_map_string_u32_{i:03}"), &bytes);
    }
}
