use serde::{Deserialize, Serialize};

type Address = [u8; 32];
type Digest = Vec<u8>;
type VersionDigest = (u64, Digest);
type ObjectRef = (Address, u64, Digest);

#[derive(Serialize, Deserialize)]
struct GasCostSummary {
    computation_cost: u64,
    storage_cost: u64,
    storage_rebate: u64,
    non_refundable_storage_fee: u64,
}

#[derive(Serialize, Deserialize)]
struct SharedOwner {
    initial_shared_version: u64,
}

#[derive(Serialize, Deserialize)]
struct ConsensusAddressOwner {
    start_version: u64,
    owner: Address,
}

#[derive(Serialize, Deserialize)]
enum Owner {
    AddressOwner(Address),
    ObjectOwner(Address),
    Shared(SharedOwner),
    Immutable,
    ConsensusAddressOwner(ConsensusAddressOwner),
}

#[derive(Serialize, Deserialize)]
enum ObjectIn {
    NotExist,
    Exist((VersionDigest, Owner)),
}

#[derive(Serialize, Deserialize)]
enum ObjectOut {
    NotExist,
    ObjectWrite((Digest, Owner)),
    PackageWrite(VersionDigest),
}

#[derive(Serialize, Deserialize)]
enum IDOperation {
    None,
    Created,
    Deleted,
}

#[derive(Serialize, Deserialize)]
struct EffectsObjectChange {
    input_state: ObjectIn,
    output_state: ObjectOut,
    id_operation: IDOperation,
}

#[derive(Serialize, Deserialize)]
enum UnchangedConsensusKind {
    ReadOnlyRoot(VersionDigest),
    MutateConsensusStreamEnded(u64),
    ReadConsensusStreamEnded(u64),
    Cancelled(u64),
    PerEpochConfig,
}

#[derive(Serialize, Deserialize)]
struct ModuleId {
    address: Address,
    name: String,
}

#[derive(Serialize, Deserialize)]
struct MoveLocation {
    module: ModuleId,
    function: u16,
    instruction: u16,
    function_name: Option<String>,
}

#[derive(Serialize, Deserialize)]
enum ExecutionFailureStatus {
    InsufficientGas,
    InvalidGasObject,
    InvariantViolation,
    FeatureNotYetSupported,
    MoveObjectTooBig,
    MovePackageTooBig,
    CircularObjectOwnership,
    InsufficientCoinBalance,
    CoinBalanceOverflow,
    PublishErrorNonZeroAddress,
    SuiMoveVerificationError,
    MovePrimitiveRuntimeError,
    MoveAbort((MoveLocation, u64)),
}

#[derive(Serialize, Deserialize)]
struct Failure {
    error: ExecutionFailureStatus,
    command: Option<u64>,
}

#[derive(Serialize, Deserialize)]
enum ExecutionStatus {
    Success,
    Failure(Failure),
}

#[derive(Serialize, Deserialize)]
struct TransactionEffectsV2 {
    status: ExecutionStatus,
    executed_epoch: u64,
    gas_used: GasCostSummary,
    transaction_digest: Digest,
    gas_object_index: Option<u32>,
    events_digest: Option<Digest>,
    dependencies: Vec<Digest>,
    lamport_version: u64,
    changed_objects: Vec<(Address, EffectsObjectChange)>,
    unchanged_consensus_objects: Vec<(Address, UnchangedConsensusKind)>,
    aux_data_digest: Option<Digest>,
}

#[derive(Serialize, Deserialize)]
enum TransactionEffects {
    V1(()),
    V2(TransactionEffectsV2),
}

#[derive(Serialize, Deserialize)]
enum TypeTag {
    Bool,
    U8,
    U64,
    U128,
    Address,
    Signer,
    Vector(Box<TypeTag>),
    Struct(Box<StructTag>),
    U16,
    U32,
    U256,
}

#[derive(Serialize, Deserialize)]
struct StructTag {
    address: Address,
    module: String,
    name: String,
    type_params: Vec<TypeTag>,
}

#[derive(Serialize, Deserialize)]
struct SharedObjectRef {
    object_id: Address,
    initial_shared_version: u64,
    mutable: bool,
}

#[derive(Serialize, Deserialize)]
enum ObjectArg {
    ImmOrOwnedObject(ObjectRef),
    SharedObject(SharedObjectRef),
    Receiving(ObjectRef),
}

#[derive(Serialize, Deserialize)]
enum Reservation {
    MaxAmountU64(u64),
}

#[derive(Serialize, Deserialize)]
enum WithdrawalType {
    Balance(TypeTag),
}

#[derive(Serialize, Deserialize)]
enum WithdrawFrom {
    Sender,
    Sponsor,
}

#[derive(Serialize, Deserialize)]
struct FundsWithdrawal {
    reservation: Reservation,
    type_arg: WithdrawalType,
    withdraw_from: WithdrawFrom,
}

#[derive(Serialize, Deserialize)]
enum CallArg {
    Pure(Vec<u8>),
    Object(ObjectArg),
    FundsWithdrawal(FundsWithdrawal),
}

#[derive(Serialize, Deserialize)]
enum Argument {
    GasCoin,
    Input(u16),
    Result(u16),
    NestedResult((u16, u16)),
}

#[derive(Serialize, Deserialize)]
struct ProgrammableMoveCall {
    package: Address,
    module: String,
    function: String,
    type_arguments: Vec<TypeTag>,
    arguments: Vec<Argument>,
}

#[derive(Serialize, Deserialize)]
enum Command {
    MoveCall(ProgrammableMoveCall),
    TransferObjects((Vec<Argument>, Argument)),
    SplitCoins((Argument, Vec<Argument>)),
    MergeCoins((Argument, Vec<Argument>)),
    Publish((Vec<Vec<u8>>, Vec<Address>)),
    MakeMoveVec((Option<TypeTag>, Vec<Argument>)),
    Upgrade((Vec<Vec<u8>>, Vec<Address>, Address, Argument)),
}

#[derive(Serialize, Deserialize)]
struct ProgrammableTransaction {
    inputs: Vec<CallArg>,
    commands: Vec<Command>,
}

#[derive(Serialize, Deserialize)]
struct GasData {
    payment: Vec<ObjectRef>,
    owner: Address,
    price: u64,
    budget: u64,
}

#[derive(Serialize, Deserialize)]
enum TransactionExpiration {
    None,
    Epoch(u64),
}

#[derive(Serialize, Deserialize)]
enum TransactionKind {
    ProgrammableTransaction(ProgrammableTransaction),
    ChangeEpoch(()),
    Genesis(()),
    ConsensusCommitPrologue(()),
    AuthenticatorStateUpdate(()),
    EndOfEpochTransaction(()),
    RandomnessStateUpdate(()),
    ConsensusCommitPrologueV2(()),
    ConsensusCommitPrologueV3(()),
    ConsensusCommitPrologueV4(()),
    ProgrammableSystemTransaction(ProgrammableTransaction),
}

#[derive(Serialize, Deserialize)]
struct TransactionDataV1 {
    kind: TransactionKind,
    sender: Address,
    gas_data: GasData,
    expiration: TransactionExpiration,
}

#[derive(Serialize, Deserialize)]
enum TransactionData {
    V1(TransactionDataV1),
}

#[derive(Serialize, Deserialize)]
struct Event {
    package_id: Address,
    transaction_module: String,
    sender: Address,
    type_: StructTag,
    contents: Vec<u8>,
}

#[derive(Serialize, Deserialize)]
struct TransactionEvents {
    data: Vec<Event>,
}

fn hex(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect::<Vec<_>>()
        .join("")
}

fn emit<T: Serialize>(name: &str, value: &T) {
    println!("{name}={}", hex(&bcs::to_bytes(value).unwrap()));
}

fn address(seed: u8) -> Address {
    let mut out = [0u8; 32];
    for (i, b) in out.iter_mut().enumerate() {
        *b = seed.wrapping_add(i as u8);
    }
    out
}

fn digest(seed: u8) -> Digest {
    address(seed).to_vec()
}

fn sui_type_tag() -> TypeTag {
    TypeTag::Struct(Box::new(StructTag {
        address: address(0x02),
        module: "sui".into(),
        name: "SUI".into(),
        type_params: vec![],
    }))
}

fn balance_type_tag() -> TypeTag {
    TypeTag::Struct(Box::new(StructTag {
        address: address(0x02),
        module: "balance".into(),
        name: "Balance".into(),
        type_params: vec![sui_type_tag()],
    }))
}

fn main() {
    let effects_success = TransactionEffects::V2(TransactionEffectsV2 {
        status: ExecutionStatus::Success,
        executed_epoch: 7,
        gas_used: GasCostSummary {
            computation_cost: 1,
            storage_cost: 2,
            storage_rebate: 3,
            non_refundable_storage_fee: 4,
        },
        transaction_digest: digest(0x10),
        gas_object_index: Some(3),
        events_digest: Some(digest(0x20)),
        dependencies: vec![digest(0x30), digest(0x40)],
        lamport_version: 99,
        changed_objects: vec![
            (
                address(0x01),
                EffectsObjectChange {
                    input_state: ObjectIn::NotExist,
                    output_state: ObjectOut::ObjectWrite((
                        digest(0x50),
                        Owner::AddressOwner(address(0x02)),
                    )),
                    id_operation: IDOperation::Created,
                },
            ),
            (
                address(0x03),
                EffectsObjectChange {
                    input_state: ObjectIn::Exist((
                        (12, digest(0x60)),
                        Owner::Shared(SharedOwner {
                            initial_shared_version: 8,
                        }),
                    )),
                    output_state: ObjectOut::PackageWrite((13, digest(0x61))),
                    id_operation: IDOperation::None,
                },
            ),
        ],
        unchanged_consensus_objects: vec![
            (
                address(0x04),
                UnchangedConsensusKind::ReadOnlyRoot((77, digest(0x70))),
            ),
            (address(0x05), UnchangedConsensusKind::PerEpochConfig),
        ],
        aux_data_digest: None,
    });
    emit("effects_v2_success", &effects_success);

    let effects_failure = TransactionEffects::V2(TransactionEffectsV2 {
        status: ExecutionStatus::Failure(Failure {
            error: ExecutionFailureStatus::MoveAbort((
                MoveLocation {
                    module: ModuleId {
                        address: address(0x06),
                        name: "coin".into(),
                    },
                    function: 2,
                    instruction: 9,
                    function_name: Some("burn".into()),
                },
                1337,
            )),
            command: Some(4),
        }),
        executed_epoch: 8,
        gas_used: GasCostSummary {
            computation_cost: 9,
            storage_cost: 10,
            storage_rebate: 11,
            non_refundable_storage_fee: 12,
        },
        transaction_digest: digest(0x11),
        gas_object_index: None,
        events_digest: None,
        dependencies: vec![digest(0x41)],
        lamport_version: 144,
        changed_objects: vec![(
            address(0x07),
            EffectsObjectChange {
                input_state: ObjectIn::Exist((
                    (99, digest(0x62)),
                    Owner::ConsensusAddressOwner(ConsensusAddressOwner {
                        start_version: 55,
                        owner: address(0x08),
                    }),
                )),
                output_state: ObjectOut::NotExist,
                id_operation: IDOperation::Deleted,
            },
        )],
        unchanged_consensus_objects: vec![(address(0x09), UnchangedConsensusKind::Cancelled(123))],
        aux_data_digest: Some(digest(0x71)),
    });
    emit("effects_v2_failure_move_abort", &effects_failure);

    let transaction_data = TransactionData::V1(TransactionDataV1 {
        kind: TransactionKind::ProgrammableTransaction(ProgrammableTransaction {
            inputs: vec![
                CallArg::Pure(vec![1, 2, 3]),
                CallArg::Object(ObjectArg::ImmOrOwnedObject((
                    address(0xaa),
                    55,
                    digest(0x80),
                ))),
                CallArg::FundsWithdrawal(FundsWithdrawal {
                    reservation: Reservation::MaxAmountU64(5000),
                    type_arg: WithdrawalType::Balance(balance_type_tag()),
                    withdraw_from: WithdrawFrom::Sponsor,
                }),
            ],
            commands: vec![
                Command::MoveCall(ProgrammableMoveCall {
                    package: address(0x09),
                    module: "coin".into(),
                    function: "split".into(),
                    type_arguments: vec![
                        TypeTag::U64,
                        TypeTag::Vector(Box::new(balance_type_tag())),
                    ],
                    arguments: vec![
                        Argument::GasCoin,
                        Argument::Input(0),
                        Argument::NestedResult((1, 2)),
                    ],
                }),
                Command::MakeMoveVec((
                    Some(TypeTag::Address),
                    vec![Argument::Input(1), Argument::Result(0)],
                )),
                Command::Publish((
                    vec![vec![0xaa, 0xbb], vec![0xcc]],
                    vec![address(0x0a), address(0x0b)],
                )),
            ],
        }),
        sender: address(0x12),
        gas_data: GasData {
            payment: vec![(address(0x13), 1, digest(0x90))],
            owner: address(0x14),
            price: 1000,
            budget: 5_000_000,
        },
        expiration: TransactionExpiration::Epoch(88),
    });
    emit("transaction_data_v1_ptb", &transaction_data);

    let events = TransactionEvents {
        data: vec![
            Event {
                package_id: address(0x21),
                transaction_module: "coins".into(),
                sender: address(0x22),
                type_: StructTag {
                    address: address(0x23),
                    module: "balance".into(),
                    name: "DepositEvent".into(),
                    type_params: vec![sui_type_tag(), TypeTag::Vector(Box::new(TypeTag::U64))],
                },
                contents: vec![0xde, 0xad, 0xbe, 0xef],
            },
            Event {
                package_id: address(0x24),
                transaction_module: "governance".into(),
                sender: address(0x25),
                type_: StructTag {
                    address: address(0x26),
                    module: "staking".into(),
                    name: "RewardEvent".into(),
                    type_params: vec![balance_type_tag()],
                },
                contents: vec![0xca, 0xfe, 0xba, 0xbe, 0x01],
            },
        ],
    };
    emit("transaction_events", &events);
}
