use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::collections::BTreeMap;

const CORPUS: &str = include_str!("malformed_corpus.txt");

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

fn decode_hex(hex: &str) -> Vec<u8> {
    assert!(hex.len() % 2 == 0, "invalid hex length for {hex}");
    let mut bytes = Vec::with_capacity(hex.len() / 2);
    let chars = hex.as_bytes();
    let mut i = 0;
    while i < chars.len() {
        let byte = u8::from_str_radix(&hex[i..i + 2], 16).unwrap();
        bytes.push(byte);
        i += 2;
    }
    bytes
}

fn dispatch(name: &str, ty: &str, bytes: &[u8]) {
    match ty {
        "bool" => emit_status::<bool>(name, bytes),
        "opt_u8" => emit_status::<Option<u8>>(name, bytes),
        "string" => emit_status::<String>(name, bytes),
        "bytes" => emit_status::<Vec<u8>>(name, bytes),
        "vec_u16" => emit_status::<Vec<u16>>(name, bytes),
        "tuple_u32_bool" => emit_status::<(u32, bool)>(name, bytes),
        "mut_enum" => emit_status::<MutationEnum>(name, bytes),
        "nested" => emit_status::<Nested>(name, bytes),
        "map_u8_unit" => emit_status::<BTreeMap<u8, ()>>(name, bytes),
        "map_string_u32" => emit_status::<BTreeMap<String, u32>>(name, bytes),
        _ => panic!("unknown corpus type: {ty}"),
    }
}

fn main() {
    for line in CORPUS.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        let mut parts = line.split('|');
        let name = parts.next().unwrap();
        let ty = parts.next().unwrap();
        let hex = parts.next().unwrap_or("");
        assert!(parts.next().is_none(), "too many fields in corpus line: {line}");

        let bytes = decode_hex(hex);
        dispatch(name, ty, &bytes);
    }
}
