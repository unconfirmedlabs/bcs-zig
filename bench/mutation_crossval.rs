use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::collections::BTreeMap;

const CASES: usize = 48;
const SEED: u64 = 0x1234_5678_9abc_def0;
const ASCII: &[u8] = b"abcxyz012_";

#[derive(Clone, Debug, Serialize, Deserialize)]
enum MutationEnum {
    Unit,
    U64(u64),
    Bytes([u8; 4]),
    Pair { a: u16, b: u8 },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Nested {
    id: u16,
    names: Vec<String>,
    flag: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct DeepStruct {
    label: String,
    nested: Nested,
    variant: MutationEnum,
    payload: Vec<u16>,
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

    fn next_u8(&mut self) -> u8 {
        self.next_u64() as u8
    }

    fn next_u16(&mut self) -> u16 {
        self.next_u64() as u16
    }

    fn next_u32(&mut self) -> u32 {
        self.next_u64() as u32
    }

    fn next_bool(&mut self) -> bool {
        self.next_u64() & 1 == 1
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

fn err_name(err: &bcs::Error) -> &'static str {
    match err {
        bcs::Error::Eof
        | bcs::Error::Io(_)
        | bcs::Error::ExpectedMapKey
        | bcs::Error::ExpectedMapValue
        | bcs::Error::MissingLen => "eof",
        bcs::Error::ExceededMaxLen(_) => "sequence_too_long",
        bcs::Error::ExceededContainerDepthLimit(_) => "container_too_deep",
        bcs::Error::ExpectedBoolean => "invalid_bool",
        bcs::Error::NonCanonicalMap => "non_canonical_map",
        bcs::Error::ExpectedOption => "invalid_option_tag",
        bcs::Error::RemainingInput => "trailing_bytes",
        bcs::Error::Utf8 => "utf8",
        bcs::Error::NonCanonicalUleb128Encoding => "non_canonical_uleb128",
        bcs::Error::IntegerOverflowDuringUleb128Decoding => "uleb128_overflow",
        bcs::Error::NotSupported(_) => "not_supported",
        bcs::Error::Custom(msg) if msg.contains("expected variant index") => "invalid_enum_tag",
        bcs::Error::Custom(_) => "custom",
    }
}

fn emit_status<T>(name: &str, bytes: &[u8])
where
    T: Serialize + DeserializeOwned,
{
    match bcs::from_bytes::<T>(bytes) {
        Ok(value) => {
            let encoded = bcs::to_bytes(&value).unwrap();
            println!("{name}=ok:{}", hex(&encoded));
        }
        Err(err) => println!("{name}=err:{}", err_name(&err)),
    }
}

fn mutate_and_emit<T>(base_name: &str, value: &T, rng: &mut Rng)
where
    T: Serialize + DeserializeOwned,
{
    let bytes = bcs::to_bytes(value).unwrap();
    emit_status::<T>(&format!("{base_name}_base"), &bytes);

    if !bytes.is_empty() {
        emit_status::<T>(&format!("{base_name}_cut1"), &bytes[..bytes.len() - 1]);
        emit_status::<T>(&format!("{base_name}_cutm"), &bytes[..bytes.len() / 2]);
    }

    let mut appended = bytes.clone();
    appended.push(rng.next_u8());
    emit_status::<T>(&format!("{base_name}_app"), &appended);

    let mut inserted = bytes.clone();
    let insert_pos = rng.range(inserted.len() + 1);
    inserted.insert(insert_pos, rng.next_u8());
    emit_status::<T>(&format!("{base_name}_ins"), &inserted);

    if !bytes.is_empty() {
        let xor_pos = rng.range(bytes.len());
        let mut xored = bytes.clone();
        let mut mask = 1u8 << rng.range(8);
        if mask == 0 {
            mask = 1;
        }
        xored[xor_pos] ^= mask;
        emit_status::<T>(&format!("{base_name}_xor"), &xored);

        let zero_pos = rng.range(bytes.len());
        let mut zeroed = bytes.clone();
        zeroed[zero_pos] = 0;
        emit_status::<T>(&format!("{base_name}_zero"), &zeroed);

        let dup_pos = rng.range(bytes.len());
        let mut duplicated = bytes.clone();
        duplicated.insert(dup_pos, duplicated[dup_pos]);
        emit_status::<T>(&format!("{base_name}_dup"), &duplicated);

        let del_pos = rng.range(bytes.len());
        let mut deleted = bytes.clone();
        deleted.remove(del_pos);
        emit_status::<T>(&format!("{base_name}_del"), &deleted);
    }
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

fn gen_string_vec(rng: &mut Rng, max_len: usize, max_str_len: usize) -> Vec<String> {
    let len = rng.range(max_len + 1);
    (0..len)
        .map(|_| gen_ascii_string(rng, max_str_len))
        .collect()
}

fn gen_deep_struct(rng: &mut Rng) -> DeepStruct {
    DeepStruct {
        label: gen_ascii_string(rng, 10),
        nested: Nested {
            id: rng.next_u16(),
            names: gen_string_vec(rng, 4, 5),
            flag: rng.next_bool(),
        },
        variant: gen_enum(rng),
        payload: gen_u16_vec(rng, 10),
    }
}

fn gen_map_u8_u16(rng: &mut Rng, max_len: usize) -> BTreeMap<u8, u16> {
    let len = rng.range(max_len + 1);
    let base = rng.next_u8();
    let mut map = BTreeMap::new();
    for i in 0..len {
        let key = base.wrapping_add((i as u8).wrapping_mul(17).wrapping_add(1));
        map.insert(key, rng.next_u16());
    }
    map
}

fn gen_map_string_u32(rng: &mut Rng, max_len: usize) -> BTreeMap<String, u32> {
    let len = rng.range(max_len + 1);
    let mut map = BTreeMap::new();
    for i in 0..len {
        let key = format!("{}{}", char::from(b'a' + i as u8), gen_ascii_string(rng, 5));
        map.insert(key, rng.next_u32());
    }
    map
}

fn gen_enum(rng: &mut Rng) -> MutationEnum {
    match rng.range(4) {
        0 => MutationEnum::Unit,
        1 => MutationEnum::U64(rng.next_u64()),
        2 => MutationEnum::Bytes([rng.next_u8(), rng.next_u8(), rng.next_u8(), rng.next_u8()]),
        _ => MutationEnum::Pair {
            a: rng.next_u16(),
            b: rng.next_u8(),
        },
    }
}

fn main() {
    let mut rng = Rng::new(SEED);

    for i in 0..CASES {
        mutate_and_emit::<bool>(&format!("mut_bool_{i:03}"), &rng.next_bool(), &mut rng);
        mutate_and_emit::<Option<u64>>(
            &format!("mut_opt_u64_{i:03}"),
            &(if rng.next_bool() { Some(rng.next_u64()) } else { None }),
            &mut rng,
        );
        mutate_and_emit::<String>(
            &format!("mut_string_{i:03}"),
            &gen_ascii_string(&mut rng, 12),
            &mut rng,
        );
        mutate_and_emit::<Vec<u16>>(
            &format!("mut_vec_u16_{i:03}"),
            &gen_u16_vec(&mut rng, 8),
            &mut rng,
        );
        mutate_and_emit::<MutationEnum>(&format!("mut_enum_{i:03}"), &gen_enum(&mut rng), &mut rng);
        mutate_and_emit::<(u32, bool)>(
            &format!("mut_tuple_pair_{i:03}"),
            &(rng.next_u32(), rng.next_bool()),
            &mut rng,
        );
        mutate_and_emit::<Nested>(
            &format!("mut_nested_{i:03}"),
            &Nested {
                id: rng.next_u16(),
                names: gen_string_vec(&mut rng, 4, 5),
                flag: rng.next_bool(),
            },
            &mut rng,
        );
        mutate_and_emit::<BTreeMap<u8, u16>>(
            &format!("mut_map_u8_u16_{i:03}"),
            &gen_map_u8_u16(&mut rng, 6),
            &mut rng,
        );
        mutate_and_emit::<BTreeMap<String, u32>>(
            &format!("mut_map_string_u32_{i:03}"),
            &gen_map_string_u32(&mut rng, 6),
            &mut rng,
        );
        mutate_and_emit::<DeepStruct>(
            &format!("mut_deep_struct_{i:03}"),
            &gen_deep_struct(&mut rng),
            &mut rng,
        );
    }
}
