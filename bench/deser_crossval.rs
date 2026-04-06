use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Serialize, Deserialize)]
enum TinyEnum {
    Unit,
    Value(u64),
}

fn hex(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect::<Vec<_>>()
        .join("")
}

fn emit<T>(name: &str, bytes: &[u8])
where
    T: Serialize + DeserializeOwned,
{
    match bcs::from_bytes::<T>(bytes) {
        Ok(value) => {
            let encoded = bcs::to_bytes(&value).unwrap();
            println!("{name}=ok:{}", hex(&encoded));
        }
        Err(_) => println!("{name}=err"),
    }
}

fn main() {
    type KeySet = BTreeMap<u8, ()>;

    emit::<bool>("bool_true", &[0x01]);
    emit::<bool>("bool_invalid", &[0x02]);
    emit::<u8>("u8_trailing", &[0x01, 0x02]);

    emit::<Option<u8>>("opt_some_u8", &[0x01, 0x2a]);
    emit::<Option<u8>>("opt_invalid_tag", &[0x05]);

    emit::<String>("string_utf8", &[0x05, b'h', b'e', b'l', b'l', b'o']);
    emit::<String>("string_invalid_utf8", &[0x02, 0xc0, 0x80]);
    emit::<Vec<u8>>("bytes_invalid_utf8", &[0x02, 0xc0, 0x80]);

    emit::<TinyEnum>("enum_unit", &[0x00]);
    emit::<TinyEnum>("enum_value", &[0x01, 0x34, 0x12, 0, 0, 0, 0, 0, 0]);
    emit::<TinyEnum>("enum_invalid_tag", &[0x02]);
    emit::<TinyEnum>("enum_noncanonical_tag", &[0x80, 0x80, 0x80, 0x80, 0x00]);

    emit::<Vec<u16>>("vec_u16_ok", &[0x02, 0x01, 0x00, 0x02, 0x00]);
    emit::<Vec<u16>>("vec_u16_short", &[0x02, 0x01, 0x00]);

    emit::<(u32, bool)>("tuple_pair", &[0x2a, 0x00, 0x00, 0x00, 0x01]);

    emit::<KeySet>("map_empty", &[0x00]);
    emit::<KeySet>("map_canonical", &[0x02, 0x04, 0x05]);
    emit::<KeySet>("map_out_of_order", &[0x02, 0x05, 0x04]);
    emit::<KeySet>("map_duplicate", &[0x02, 0x05, 0x05]);
}
