use serde::{de::DeserializeSeed, Deserialize, Serialize};
use std::io::{Cursor, Read};

#[derive(Deserialize, Serialize)]
struct RawNested {
    id: u16,
    name: String,
    flag: bool,
}

#[derive(Deserialize, Serialize)]
struct RawDeep {
    inner: RawNested,
}

struct MultiplySeed {
    factor: u64,
}

impl<'de> DeserializeSeed<'de> for MultiplySeed {
    type Value = u64;

    fn deserialize<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        Ok(u64::deserialize(deserializer)? * self.factor)
    }
}

struct PrefixSeed {
    prefix: &'static str,
}

impl<'de> DeserializeSeed<'de> for PrefixSeed {
    type Value = String;

    fn deserialize<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;
        Ok(format!("{}{}", self.prefix, s))
    }
}

struct NestedSeed {
    scale: u32,
    prefix: &'static str,
}

impl<'de> DeserializeSeed<'de> for NestedSeed {
    type Value = (u32, String, bool);

    fn deserialize<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let raw = RawNested::deserialize(deserializer)?;
        Ok((
            raw.id as u32 * self.scale,
            format!("{}{}", self.prefix, raw.name),
            raw.flag,
        ))
    }
}

struct DeepSeed {
    prefix: &'static str,
}

impl<'de> DeserializeSeed<'de> for DeepSeed {
    type Value = String;

    fn deserialize<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let raw = RawDeep::deserialize(deserializer)?;
        Ok(format!("{}{}", self.prefix, raw.inner.name))
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

fn emit_ok(name: &str, value: impl std::fmt::Display) {
    println!("{name}=ok:{value}");
}

fn emit_result<T: std::fmt::Display>(name: &str, result: Result<T, bcs::Error>) {
    match result {
        Ok(value) => emit_ok(name, value),
        Err(_) => println!("{name}=err"),
    }
}

fn main() {
    let u64_bytes = bcs::to_bytes(&42u64).unwrap();
    emit_result(
        "seed_u64",
        bcs::from_bytes_seed(MultiplySeed { factor: 3 }, &u64_bytes),
    );

    let string_bytes = bcs::to_bytes(&"coin".to_string()).unwrap();
    emit_result(
        "seed_string",
        bcs::from_bytes_seed(PrefixSeed { prefix: "mod:" }, &string_bytes),
    );

    let nested_bytes = bcs::to_bytes(&RawNested {
        id: 7,
        name: "hello".into(),
        flag: false,
    })
    .unwrap();
    match bcs::from_bytes_seed(
        NestedSeed {
            scale: 10,
            prefix: "evt:",
        },
        &nested_bytes,
    ) {
        Ok((scaled, label, flag)) => println!("seed_nested=ok:{scaled}:{label}:{}", if flag { 1 } else { 0 }),
        Err(_) => println!("seed_nested=err"),
    }

    let trailing = [u64_bytes.as_slice(), &[0xff]].concat();
    emit_result(
        "seed_trailing",
        bcs::from_bytes_seed(MultiplySeed { factor: 2 }, &trailing),
    );

    let deep_bytes = bcs::to_bytes(&RawDeep {
        inner: RawNested {
            id: 11,
            name: "x".into(),
            flag: true,
        },
    })
    .unwrap();
    emit_result(
        "seed_limit_ok",
        bcs::from_bytes_seed_with_limit(DeepSeed { prefix: "ctx:" }, &deep_bytes, 2),
    );
    emit_result(
        "seed_limit_fail",
        bcs::from_bytes_seed_with_limit(DeepSeed { prefix: "ctx:" }, &deep_bytes, 1),
    );

    emit_result(
        "seed_reader_string",
        bcs::from_reader_seed(PrefixSeed { prefix: "mod:" }, Cursor::new(&string_bytes)),
    );
    match bcs::from_reader_seed(
        NestedSeed {
            scale: 10,
            prefix: "evt:",
        },
        Chunked {
            bytes: &nested_bytes,
            pos: 0,
            chunk: 2,
        },
    ) {
        Ok((scaled, label, flag)) => println!("seed_reader_nested=ok:{scaled}:{label}:{}", if flag { 1 } else { 0 }),
        Err(_) => println!("seed_reader_nested=err"),
    }
    emit_result(
        "seed_reader_limit_ok",
        bcs::from_reader_seed_with_limit(DeepSeed { prefix: "ctx:" }, Cursor::new(&deep_bytes), 2),
    );
    emit_result(
        "seed_reader_limit_fail",
        bcs::from_reader_seed_with_limit(DeepSeed { prefix: "ctx:" }, Cursor::new(&deep_bytes), 1),
    );
}
