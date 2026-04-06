const bcs = @import("bcs");
const std = @import("std");

const Address = [32]u8;
const Digest = []const u8;
const VersionDigest = struct { u64, Digest };
const ObjectRef = struct { Address, u64, Digest };
const ChangedObjectEntry = struct { Address, EffectsObjectChange };
const UnchangedConsensusEntry = struct { Address, UnchangedConsensusKind };

const GasCostSummary = struct {
    computation_cost: u64,
    storage_cost: u64,
    storage_rebate: u64,
    non_refundable_storage_fee: u64,
};

const SharedOwner = struct {
    initial_shared_version: u64,
};

const ConsensusAddressOwner = struct {
    start_version: u64,
    owner: Address,
};

const Owner = union(enum) {
    AddressOwner: Address,
    ObjectOwner: Address,
    Shared: SharedOwner,
    Immutable,
    ConsensusAddressOwner: ConsensusAddressOwner,
};

const ObjectIn = union(enum) {
    NotExist,
    Exist: struct { VersionDigest, Owner },
};

const ObjectOut = union(enum) {
    NotExist,
    ObjectWrite: struct { Digest, Owner },
    PackageWrite: VersionDigest,
};

const IDOperation = enum {
    None,
    Created,
    Deleted,
};

const EffectsObjectChange = struct {
    input_state: ObjectIn,
    output_state: ObjectOut,
    id_operation: IDOperation,
};

const UnchangedConsensusKind = union(enum) {
    ReadOnlyRoot: VersionDigest,
    MutateConsensusStreamEnded: u64,
    ReadConsensusStreamEnded: u64,
    Cancelled: u64,
    PerEpochConfig,
};

const ModuleId = struct {
    address: Address,
    name: bcs.String,
};

const MoveLocation = struct {
    module: ModuleId,
    function: u16,
    instruction: u16,
    function_name: ?bcs.String,
};

const ExecutionFailureStatus = union(enum) {
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
    MoveAbort: struct { MoveLocation, u64 },
};

const Failure = struct {
    @"error": ExecutionFailureStatus,
    command: ?u64,
};

const ExecutionStatus = union(enum) {
    Success,
    Failure: Failure,
};

const TransactionEffectsV2 = struct {
    status: ExecutionStatus,
    executed_epoch: u64,
    gas_used: GasCostSummary,
    transaction_digest: Digest,
    gas_object_index: ?u32,
    events_digest: ?Digest,
    dependencies: []const Digest,
    lamport_version: u64,
    changed_objects: []const ChangedObjectEntry,
    unchanged_consensus_objects: []const UnchangedConsensusEntry,
    aux_data_digest: ?Digest,
};

const TransactionEffects = union(enum) {
    V1,
    V2: TransactionEffectsV2,
};

const TypeTag = union(enum) {
    Bool,
    U8,
    U64,
    U128,
    Address,
    Signer,
    Vector: *const TypeTag,
    Struct: *const StructTag,
    U16,
    U32,
    U256,
};

const StructTag = struct {
    address: Address,
    module: bcs.String,
    name: bcs.String,
    type_params: []const TypeTag,
};

const SharedObjectRef = struct {
    object_id: Address,
    initial_shared_version: u64,
    mutable: bool,
};

const ObjectArg = union(enum) {
    ImmOrOwnedObject: ObjectRef,
    SharedObject: SharedObjectRef,
    Receiving: ObjectRef,
};

const Reservation = union(enum) {
    MaxAmountU64: u64,
};

const WithdrawalType = union(enum) {
    Balance: TypeTag,
};

const WithdrawFrom = union(enum) {
    Sender,
    Sponsor,
};

const FundsWithdrawal = struct {
    reservation: Reservation,
    type_arg: WithdrawalType,
    withdraw_from: WithdrawFrom,
};

const CallArg = union(enum) {
    Pure: []const u8,
    Object: ObjectArg,
    FundsWithdrawal: FundsWithdrawal,
};

const Argument = union(enum) {
    GasCoin,
    Input: u16,
    Result: u16,
    NestedResult: struct { u16, u16 },
};

const ProgrammableMoveCall = struct {
    package: Address,
    module: bcs.String,
    function: bcs.String,
    type_arguments: []const TypeTag,
    arguments: []const Argument,
};

const Command = union(enum) {
    MoveCall: ProgrammableMoveCall,
    TransferObjects: struct { []const Argument, Argument },
    SplitCoins: struct { Argument, []const Argument },
    MergeCoins: struct { Argument, []const Argument },
    Publish: struct { []const []const u8, []const Address },
    MakeMoveVec: struct { ?TypeTag, []const Argument },
    Upgrade: struct { []const []const u8, []const Address, Address, Argument },
};

const ProgrammableTransaction = struct {
    inputs: []const CallArg,
    commands: []const Command,
};

const GasData = struct {
    payment: []const ObjectRef,
    owner: Address,
    price: u64,
    budget: u64,
};

const TransactionExpiration = union(enum) {
    None,
    Epoch: u64,
};

const TransactionKind = union(enum) {
    ProgrammableTransaction: ProgrammableTransaction,
    ChangeEpoch,
    Genesis,
    ConsensusCommitPrologue,
    AuthenticatorStateUpdate,
    EndOfEpochTransaction,
    RandomnessStateUpdate,
    ConsensusCommitPrologueV2,
    ConsensusCommitPrologueV3,
    ConsensusCommitPrologueV4,
    ProgrammableSystemTransaction: ProgrammableTransaction,
};

const TransactionDataV1 = struct {
    kind: TransactionKind,
    sender: Address,
    gas_data: GasData,
    expiration: TransactionExpiration,
};

const TransactionData = union(enum) {
    V1: TransactionDataV1,
};

const Event = struct {
    package_id: Address,
    transaction_module: bcs.String,
    sender: Address,
    type_: StructTag,
    contents: []const u8,
};

const TransactionEvents = struct {
    data: []const Event,
};

fn seq32(seed: u8) [32]u8 {
    var out: [32]u8 = undefined;
    for (&out, 0..) |*b, i| b.* = seed +% @as(u8, @intCast(i));
    return out;
}

fn s(bytes: []const u8) bcs.String {
    return bcs.String.init(bytes);
}

fn emit(allocator: std.mem.Allocator, name: []const u8, value: anytype) !void {
    const bytes = try bcs.serialize(allocator, value);
    defer allocator.free(bytes);
    std.debug.print("{s}=", .{name});
    for (bytes) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const a01 = seq32(0x01);
    const a02 = seq32(0x02);
    const a03 = seq32(0x03);
    const a04 = seq32(0x04);
    const a05 = seq32(0x05);
    const a06 = seq32(0x06);
    const a07 = seq32(0x07);
    const a08 = seq32(0x08);
    const a09 = seq32(0x09);
    const a0a = seq32(0x0a);
    const a0b = seq32(0x0b);
    const a12 = seq32(0x12);
    const a13 = seq32(0x13);
    const a14 = seq32(0x14);
    const a21 = seq32(0x21);
    const a22 = seq32(0x22);
    const a23 = seq32(0x23);
    const a24 = seq32(0x24);
    const a25 = seq32(0x25);
    const a26 = seq32(0x26);
    const aaa = seq32(0xaa);

    const d10 = seq32(0x10);
    const d11 = seq32(0x11);
    const d20 = seq32(0x20);
    const d30 = seq32(0x30);
    const d40 = seq32(0x40);
    const d41 = seq32(0x41);
    const d50 = seq32(0x50);
    const d60 = seq32(0x60);
    const d61 = seq32(0x61);
    const d62 = seq32(0x62);
    const d70 = seq32(0x70);
    const d71 = seq32(0x71);
    const d80 = seq32(0x80);
    const d90 = seq32(0x90);

    const sui_struct_tag = StructTag{
        .address = a02,
        .module = s("sui"),
        .name = s("SUI"),
        .type_params = &.{},
    };
    const sui_type = TypeTag{ .Struct = &sui_struct_tag };
    const balance_params = [_]TypeTag{sui_type};
    const balance_struct_tag = StructTag{
        .address = a02,
        .module = s("balance"),
        .name = s("Balance"),
        .type_params = &balance_params,
    };
    const balance_type = TypeTag{ .Struct = &balance_struct_tag };
    const vector_balance_type = TypeTag{ .Vector = &balance_type };
    const tt_u64 = TypeTag{ .U64 = {} };
    const tt_address = TypeTag{ .Address = {} };

    const effects_success_changed = [_]ChangedObjectEntry{
        .{
            a01,
            .{
                .input_state = .NotExist,
                .output_state = .{ .ObjectWrite = .{ d50[0..], .{ .AddressOwner = a02 } } },
                .id_operation = .Created,
            },
        },
        .{
            a03,
            .{
                .input_state = .{ .Exist = .{
                    .{ 12, d60[0..] },
                    .{ .Shared = .{ .initial_shared_version = 8 } },
                } },
                .output_state = .{ .PackageWrite = .{ 13, d61[0..] } },
                .id_operation = .None,
            },
        },
    };
    const effects_success_unchanged = [_]UnchangedConsensusEntry{
        .{ a04, .{ .ReadOnlyRoot = .{ 77, d70[0..] } } },
        .{ a05, .PerEpochConfig },
    };
    const effects_success_dependencies = [_]Digest{ d30[0..], d40[0..] };
    const effects_success = TransactionEffects{
        .V2 = .{
            .status = .Success,
            .executed_epoch = 7,
            .gas_used = .{
                .computation_cost = 1,
                .storage_cost = 2,
                .storage_rebate = 3,
                .non_refundable_storage_fee = 4,
            },
            .transaction_digest = d10[0..],
            .gas_object_index = 3,
            .events_digest = d20[0..],
            .dependencies = &effects_success_dependencies,
            .lamport_version = 99,
            .changed_objects = &effects_success_changed,
            .unchanged_consensus_objects = &effects_success_unchanged,
            .aux_data_digest = null,
        },
    };
    try emit(allocator, "effects_v2_success", effects_success);

    const failure_changed = [_]ChangedObjectEntry{
        .{
            a07,
            .{
                .input_state = .{ .Exist = .{
                    .{ 99, d62[0..] },
                    .{ .ConsensusAddressOwner = .{ .start_version = 55, .owner = a08 } },
                } },
                .output_state = .NotExist,
                .id_operation = .Deleted,
            },
        },
    };
    const failure_unchanged = [_]UnchangedConsensusEntry{
        .{ a09, .{ .Cancelled = 123 } },
    };
    const failure_dependencies = [_]Digest{d41[0..]};
    const effects_failure = TransactionEffects{
        .V2 = .{
            .status = .{ .Failure = .{
                .@"error" = .{ .MoveAbort = .{
                    .{
                        .module = .{ .address = a06, .name = s("coin") },
                        .function = 2,
                        .instruction = 9,
                        .function_name = s("burn"),
                    },
                    1337,
                } },
                .command = 4,
            } },
            .executed_epoch = 8,
            .gas_used = .{
                .computation_cost = 9,
                .storage_cost = 10,
                .storage_rebate = 11,
                .non_refundable_storage_fee = 12,
            },
            .transaction_digest = d11[0..],
            .gas_object_index = null,
            .events_digest = null,
            .dependencies = &failure_dependencies,
            .lamport_version = 144,
            .changed_objects = &failure_changed,
            .unchanged_consensus_objects = &failure_unchanged,
            .aux_data_digest = d71[0..],
        },
    };
    try emit(allocator, "effects_v2_failure_move_abort", effects_failure);

    const move_call_type_arguments = [_]TypeTag{
        .U64,
        vector_balance_type,
    };
    const move_call_arguments = [_]Argument{
        .GasCoin,
        .{ .Input = 0 },
        .{ .NestedResult = .{ 1, 2 } },
    };
    const make_move_vec_arguments = [_]Argument{
        .{ .Input = 1 },
        .{ .Result = 0 },
    };
    const publish_modules = [_][]const u8{
        &.{ 0xaa, 0xbb },
        &.{0xcc},
    };
    const publish_deps = [_]Address{ a0a, a0b };
    const tx_inputs = [_]CallArg{
        .{ .Pure = &.{ 1, 2, 3 } },
        .{ .Object = .{ .ImmOrOwnedObject = .{ aaa, 55, d80[0..] } } },
        .{ .FundsWithdrawal = .{
            .reservation = .{ .MaxAmountU64 = 5000 },
            .type_arg = .{ .Balance = balance_type },
            .withdraw_from = .Sponsor,
        } },
    };
    const tx_commands = [_]Command{
        .{ .MoveCall = .{
            .package = a09,
            .module = s("coin"),
            .function = s("split"),
            .type_arguments = &move_call_type_arguments,
            .arguments = &move_call_arguments,
        } },
        .{ .MakeMoveVec = .{ tt_address, &make_move_vec_arguments } },
        .{ .Publish = .{ &publish_modules, &publish_deps } },
    };
    const gas_payment = [_]ObjectRef{
        .{ a13, 1, d90[0..] },
    };
    const transaction_data = TransactionData{
        .V1 = .{
            .kind = .{ .ProgrammableTransaction = .{
                .inputs = &tx_inputs,
                .commands = &tx_commands,
            } },
            .sender = a12,
            .gas_data = .{
                .payment = &gas_payment,
                .owner = a14,
                .price = 1000,
                .budget = 5_000_000,
            },
            .expiration = .{ .Epoch = 88 },
        },
    };
    try emit(allocator, "transaction_data_v1_ptb", transaction_data);

    const deposit_type_params = [_]TypeTag{
        sui_type,
        .{ .Vector = &tt_u64 },
    };
    const deposit_tag = StructTag{
        .address = a23,
        .module = s("balance"),
        .name = s("DepositEvent"),
        .type_params = &deposit_type_params,
    };
    const reward_type_params = [_]TypeTag{balance_type};
    const reward_tag = StructTag{
        .address = a26,
        .module = s("staking"),
        .name = s("RewardEvent"),
        .type_params = &reward_type_params,
    };
    const events_data = [_]Event{
        .{
            .package_id = a21,
            .transaction_module = s("coins"),
            .sender = a22,
            .type_ = deposit_tag,
            .contents = &.{ 0xde, 0xad, 0xbe, 0xef },
        },
        .{
            .package_id = a24,
            .transaction_module = s("governance"),
            .sender = a25,
            .type_ = reward_tag,
            .contents = &.{ 0xca, 0xfe, 0xba, 0xbe, 0x01 },
        },
    };
    const transaction_events = TransactionEvents{ .data = &events_data };
    try emit(allocator, "transaction_events", transaction_events);
}
