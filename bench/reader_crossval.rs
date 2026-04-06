use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::{Cursor, Read};

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
    match bcs::from_reader::<T>(Cursor::new(bytes)) {
        Ok(value) => {
            let encoded = bcs::to_bytes(&value).unwrap();
            println!("{name}=ok:{}", hex(&encoded));
        }
        Err(_) => println!("{name}=err"),
    }
}

fn emit_with_limit<T>(name: &str, bytes: &[u8], limit: usize)
where
    T: Serialize + DeserializeOwned,
{
    match bcs::from_reader_with_limit::<T>(Cursor::new(bytes), limit) {
        Ok(value) => {
            let encoded = bcs::to_bytes(&value).unwrap();
            println!("{name}=ok:{}", hex(&encoded));
        }
        Err(_) => println!("{name}=err"),
    }
}

struct Chunked<'a> {
    bytes: &'a [u8],
    pos: usize,
    chunk: usize,
}

impl<'a> Read for Chunked<'a> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.pos >= self.bytes.len() {
            return Ok(0);
        }
        let n = self.chunk.min(buf.len()).min(self.bytes.len() - self.pos);
        buf[..n].copy_from_slice(&self.bytes[self.pos..self.pos + n]);
        self.pos += n;
        Ok(n)
    }
}

fn emit_chunked<T>(name: &str, bytes: &[u8], chunk: usize)
where
    T: Serialize + DeserializeOwned,
{
    let reader = Chunked {
        bytes,
        pos: 0,
        chunk,
    };
    match bcs::from_reader::<T>(reader) {
        Ok(value) => {
            let encoded = bcs::to_bytes(&value).unwrap();
            println!("{name}=ok:{}", hex(&encoded));
        }
        Err(_) => println!("{name}=err"),
    }
}

fn main() {
    type KeySet = BTreeMap<u8, ()>;
    type StringMap = BTreeMap<String, u8>;

    emit::<bool>("reader_bool_true", &[0x01]);
    emit::<bool>("reader_bool_invalid", &[0x02]);
    emit::<u8>("reader_u8_trailing", &[0x01, 0x02]);

    emit::<Option<u8>>("reader_opt_some_u8", &[0x01, 0x2a]);
    emit::<Option<u8>>("reader_opt_invalid_tag", &[0x05]);

    emit::<String>("reader_string_utf8", &[0x05, b'h', b'e', b'l', b'l', b'o']);
    emit::<String>("reader_string_invalid_utf8", &[0x02, 0xc0, 0x80]);
    emit::<Vec<u8>>("reader_bytes_invalid_utf8", &[0x02, 0xc0, 0x80]);

    emit::<TinyEnum>("reader_enum_unit", &[0x00]);
    emit::<TinyEnum>("reader_enum_value", &[0x01, 0x34, 0x12, 0, 0, 0, 0, 0, 0]);
    emit::<TinyEnum>("reader_enum_invalid_tag", &[0x02]);

    emit::<Vec<u16>>("reader_vec_u16_ok", &[0x02, 0x01, 0x00, 0x02, 0x00]);
    emit::<Vec<u16>>("reader_vec_u16_short", &[0x02, 0x01, 0x00]);

    emit::<(u32, bool)>("reader_tuple_pair", &[0x2a, 0x00, 0x00, 0x00, 0x01]);
    emit::<Nested>(
        "reader_nested",
        &bcs::to_bytes(&Nested {
            id: 7,
            names: vec!["hi".into(), "there".into()],
            flag: true,
        })
        .unwrap(),
    );

    emit::<KeySet>("reader_map_empty", &[0x00]);
    emit::<KeySet>("reader_map_canonical", &[0x02, 0x04, 0x05]);
    emit::<KeySet>("reader_map_out_of_order", &[0x02, 0x05, 0x04]);
    emit::<StringMap>(
        "reader_map_string",
        &bcs::to_bytes(&BTreeMap::from([
            ("alpha".to_string(), 1u8),
            ("beta".to_string(), 2u8),
        ]))
        .unwrap(),
    );

    emit_chunked::<Nested>(
        "reader_chunked_nested",
        &bcs::to_bytes(&Nested {
            id: 9,
            names: vec!["a".into(), "bb".into(), "ccc".into()],
            flag: false,
        })
        .unwrap(),
        2,
    );
    emit_chunked::<StringMap>(
        "reader_chunked_map_string",
        &bcs::to_bytes(&BTreeMap::from([
            ("eta".to_string(), 7u8),
            ("theta".to_string(), 8u8),
        ]))
        .unwrap(),
        3,
    );

    emit_with_limit::<Nested>(
        "reader_limit_ok",
        &bcs::to_bytes(&Nested {
            id: 11,
            names: vec!["x".into()],
            flag: true,
        })
        .unwrap(),
        2,
    );
    emit_with_limit::<Nested>(
        "reader_limit_fail",
        &bcs::to_bytes(&Nested {
            id: 11,
            names: vec!["x".into()],
            flag: true,
        })
        .unwrap(),
        0,
    );
}
