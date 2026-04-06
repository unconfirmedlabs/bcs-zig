use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Serialize, Deserialize)]
enum TinyEnum {
    Unit,
    Value(u64),
}

#[derive(Serialize, Deserialize)]
struct Nested {
    id: u16,
    names: Vec<String>,
    flag: bool,
}

fn err_name(err: &bcs::Error) -> &'static str {
    match err {
        bcs::Error::Eof => "eof",
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
        bcs::Error::Io(_) => "io",
        bcs::Error::ExpectedMapKey => "expected_map_key",
        bcs::Error::ExpectedMapValue => "expected_map_value",
        bcs::Error::MissingLen => "missing_len",
        bcs::Error::Custom(_) => "custom",
    }
}

fn emit_status<T>(name: &str, bytes: &[u8])
where
    T: Serialize + DeserializeOwned,
{
    match bcs::from_bytes::<T>(bytes) {
        Ok(_) => println!("{name}=ok"),
        Err(err) => println!("{name}=err:{}", err_name(&err)),
    }
}

fn emit_prefix_cases<T>(name: &str, value: &T)
where
    T: Serialize + DeserializeOwned,
{
    let bytes = bcs::to_bytes(value).unwrap();
    emit_status::<T>(&format!("{name}_full"), &bytes);

    for i in 0..bytes.len() {
        emit_status::<T>(&format!("{name}_prefix_{i:03}"), &bytes[..i]);
    }

    let mut trailing = bytes.clone();
    trailing.push(0);
    emit_status::<T>(&format!("{name}_trailing"), &trailing);
}

fn main() {
    emit_prefix_cases("bool_true", &true);
    emit_prefix_cases("u32_42", &42u32);
    emit_prefix_cases("string_hello", &"hello".to_string());
    emit_prefix_cases("vec_u16", &vec![1u16, 2, 3]);
    emit_prefix_cases("opt_some_u8", &Some(42u8));
    emit_prefix_cases("enum_value", &TinyEnum::Value(0x1234));
    emit_prefix_cases("tuple_pair", &(42u32, true));

    let mut numeric_map = BTreeMap::<u8, ()>::new();
    numeric_map.insert(4, ());
    numeric_map.insert(5, ());
    emit_prefix_cases("map_u8_unit", &numeric_map);

    let mut string_map = BTreeMap::<String, u8>::new();
    string_map.insert("beta".into(), 2);
    string_map.insert("alpha".into(), 1);
    emit_prefix_cases("map_string_u8", &string_map);

    emit_prefix_cases(
        "nested_struct",
        &Nested {
            id: 7,
            names: vec!["hi".into(), "there".into()],
            flag: true,
        },
    );

    emit_status::<bool>("manual_invalid_bool", &[9]);
    emit_status::<Option<u8>>("manual_invalid_option", &[5, 0]);
    emit_status::<TinyEnum>("manual_invalid_enum_tag", &[5]);
    emit_status::<TinyEnum>(
        "manual_invalid_enum_tag_wide",
        &[0x80, 0x80, 0x80, 0x80, 0x0f],
    );
    emit_status::<TinyEnum>("manual_noncanonical_uleb", &[0x80, 0x80, 0x80, 0x00]);
    emit_status::<TinyEnum>("manual_uleb_overflow", &[0x80, 0x80, 0x80, 0x80, 0x80]);
    emit_status::<String>("manual_invalid_utf8", &[1, 0xff]);
    emit_status::<Vec<u8>>(
        "manual_sequence_too_long",
        &[0x80, 0x80, 0x80, 0x80, 0x08],
    );
    emit_status::<BTreeMap<u8, ()>>("manual_map_out_of_order", &[2, 5, 4]);
    emit_status::<BTreeMap<u8, ()>>("manual_map_duplicate", &[2, 5, 5]);
    emit_status::<BTreeMap<String, u8>>(
        "manual_map_string_invalid_utf8_key",
        &[1, 1, 0xff, 1],
    );
}
