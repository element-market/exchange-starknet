use starknet::{ContractAddress, ClassHash};
use element::market::interface::Fee;

#[event]
#[derive(Drop, starknet::Event)]
enum Event {
    CounterIncremented: CounterIncremented,
    OrderCancelled: OrderCancelled,
    OrderFilled: OrderFilled,
    OwnershipTransferred: OwnershipTransferred,
    Upgraded: Upgraded,
}

#[derive(Drop, starknet::Event)]
struct CounterIncremented {
    #[key]
    account: ContractAddress,
    new_counter: u128,
}

#[derive(Drop, starknet::Event)]
struct OrderCancelled {
    #[key]
    account: ContractAddress,
    #[key]
    order_hash: felt252,
}

#[derive(Drop, starknet::Event)]
struct OrderFilled {
    #[key]
    order_hash: felt252,
    #[key]
    order_type: u128,
    #[key]
    maker: ContractAddress,
    taker: ContractAddress,
    erc20_address: ContractAddress,
    erc20_amount: u128,
    fees: Span<Fee>,
    nft_address: ContractAddress,
    nft_id: u256,
    nft_amount: u128,
}

#[derive(Drop, starknet::Event)]
struct OwnershipTransferred {
    previous_owner: ContractAddress,
    new_owner: ContractAddress,
}

#[derive(Drop, starknet::Event)]
struct Upgraded {
    class_hash: ClassHash
}
