// Rust BCS benchmark — WASM library
// Equivalent to bench/lib.zig
//
// Build: cargo build --release --target wasm32-wasip1 --lib
// Note: Rust BCS requires wasm32-wasip1 (not wasm32-freestanding) because
// the bcs crate depends on thiserror which requires std::error::Error.

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
pub struct TestStruct {
    pub a: u64,
    pub b: bool,
    pub c: [u8; 32],
}

#[no_mangle]
pub extern "C" fn bcs_roundtrip() -> u64 {
    let val = TestStruct {
        a: 42,
        b: true,
        c: [0xab; 32],
    };

    // Serialize
    let bytes = bcs::to_bytes(&val).unwrap();

    // Deserialize
    let decoded: TestStruct = bcs::from_bytes(&bytes).unwrap();
    decoded.a
}
