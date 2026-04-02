// Rust BCS benchmark — native binary
// Equivalent to bench/main.zig
//
// Build: cargo build --release
// Cargo.toml profile: opt-level = "z", lto = true, codegen-units = 1, strip = true, panic = "abort"

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct TestStruct {
    a: u64,
    b: bool,
    c: [u8; 32],
}

fn main() {
    let val = TestStruct {
        a: 42,
        b: true,
        c: [0xab; 32],
    };

    // Serialize
    let bytes = bcs::to_bytes(&val).unwrap();

    // Deserialize
    let decoded: TestStruct = bcs::from_bytes(&bytes).unwrap();
    assert_eq!(val, decoded);
}
