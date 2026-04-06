use bcs::{
    from_bytes_with_limit, serialized_size_with_limit, to_bytes_with_limit, Error,
    MAX_CONTAINER_DEPTH,
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct D0 {
    leaf: u8,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct D1 {
    child: D0,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct D2 {
    child: D1,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct D3 {
    child: D2,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct D4 {
    child: D3,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct D5 {
    child: D4,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct D6 {
    child: D5,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct D7 {
    child: D6,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct D8 {
    child: D7,
}

fn deep_value() -> D8 {
    D8 {
        child: D7 {
            child: D6 {
                child: D5 {
                    child: D4 {
                        child: D3 {
                            child: D2 {
                                child: D1 {
                                    child: D0 { leaf: 7 },
                                },
                            },
                        },
                    },
                },
            },
        },
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect::<Vec<_>>()
        .join("")
}

fn err_name(err: &Error) -> &'static str {
    match err {
        Error::ExceededContainerDepthLimit(_) => "container_too_deep",
        Error::NotSupported(_) => "not_supported",
        _ => "other",
    }
}

fn emit_bytes_result(name: &str, result: Result<Vec<u8>, Error>) {
    match result {
        Ok(bytes) => println!("{name}=ok:{}", hex(&bytes)),
        Err(err) => println!("{name}=err:{}", err_name(&err)),
    }
}

fn emit_size_result(name: &str, result: Result<usize, Error>) {
    match result {
        Ok(size) => println!("{name}=ok:{size}"),
        Err(err) => println!("{name}=err:{}", err_name(&err)),
    }
}

fn emit_unit_result<T>(name: &str, result: Result<T, Error>) {
    match result {
        Ok(_) => println!("{name}=ok"),
        Err(err) => println!("{name}=err:{}", err_name(&err)),
    }
}

fn main() {
    const LIMIT_FAIL: usize = 8;
    const LIMIT_OK: usize = 9;

    let value = deep_value();
    let bytes = to_bytes_with_limit(&value, LIMIT_OK).unwrap();

    emit_bytes_result(
        "to_bytes_with_limit_fail",
        to_bytes_with_limit(&value, LIMIT_FAIL),
    );
    emit_bytes_result("to_bytes_with_limit_ok", Ok(bytes.clone()));
    emit_bytes_result(
        "to_bytes_with_limit_above_max",
        to_bytes_with_limit(&value, MAX_CONTAINER_DEPTH + 1),
    );

    emit_size_result(
        "serialized_size_with_limit_fail",
        serialized_size_with_limit(&value, LIMIT_FAIL),
    );
    emit_size_result(
        "serialized_size_with_limit_ok",
        serialized_size_with_limit(&value, LIMIT_OK),
    );
    emit_size_result(
        "serialized_size_with_limit_above_max",
        serialized_size_with_limit(&value, MAX_CONTAINER_DEPTH + 1),
    );

    emit_unit_result(
        "from_bytes_with_limit_fail",
        from_bytes_with_limit::<D8>(&bytes, LIMIT_FAIL),
    );
    emit_unit_result(
        "from_bytes_with_limit_ok",
        from_bytes_with_limit::<D8>(&bytes, LIMIT_OK),
    );
    emit_unit_result(
        "from_bytes_with_limit_above_max",
        from_bytes_with_limit::<D8>(&bytes, MAX_CONTAINER_DEPTH + 1),
    );
}
