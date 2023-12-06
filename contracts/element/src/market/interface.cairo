// SPDX-License-Identifier: MIT

use starknet::{ContractAddress, ClassHash};

const ORDER_TYPE_ERC721_BUY_ORDER: u128 = 0_u128; // 0b000
const ORDER_TYPE_ERC721_SELL_ORDER: u128 = 1_u128; // 0b001
const ORDER_TYPE_ERC1155_BUY_ORDER: u128 = 2_u128; // 0b010
const ORDER_TYPE_ERC1155_SELL_ORDER: u128 = 3_u128; // 0b011
const ORDER_TYPE_ERC721_CONTRACT_OFFER: u128 = 4_u128; // 0b100
const ORDER_TYPE_ERC1155_CONTRACT_OFFER: u128 = 6_u128; // 0b110

#[derive(Drop, Serde)]
struct OrderStatus {
    is_cancelled: bool,
    filled_amount: u128,
}

#[derive(Drop, Serde, starknet::Event)]
struct Fee {
    recipient: ContractAddress,
    amount: u128,
}

#[derive(Drop, Serde)]
struct Order {
    order_type: u128,
    maker: ContractAddress,
    taker: ContractAddress,
    listing_time: u64,
    expiry_time: u64,
    salt: u128,
    erc20_address: ContractAddress,
    erc20_amount: u128,
    fees: Array<Fee>,
    nft_address: ContractAddress,
    nft_id: u256,
    nft_amount: u128,
    order_validator: ContractAddress,
    counter: u128,
}

#[derive(Drop, Serde)]
struct FillParams {
    fill_id: u256,
    fill_amount: u128,
    recipient: ContractAddress,
    signature: Array<felt252>,
    extra_data: Array<felt252>,
}

#[derive(Copy, Drop, Serde)]
struct ERC721SellOrder {
    maker: felt252,
    listing_time: u64,
    expiry_time: u64,
    salt: felt252,
    erc20_address: ContractAddress,
    erc20_amount: u128,
    fee0_recipient: felt252,
    fee0_amount: u128,
    fee1_recipient: felt252,
    fee1_amount: u128,
    nft_address: ContractAddress,
    nft_id: felt252,
}

#[starknet::interface]
trait IOrderFeature<TState> {
    fn buy_erc721(ref self: TState, order: ERC721SellOrder, signature: Array<felt252>);
    fn fill_order(ref self: TState, order: Order, params: FillParams);
    fn cancel_orders(ref self: TState, orders: Array<Order>);
    fn increment_counter(ref self: TState) -> u128;
    fn get_counter(self: @TState, account: ContractAddress) -> u128;
    fn get_order_status(self: @TState, order_hash: felt252) -> OrderStatus;
    fn get_order_hash(self: @TState, order: Order) -> felt252;
    fn validate_signature(self: @TState, order: Order, signature: Array<felt252>);
}

#[starknet::interface]
trait IUpgradeable<TState> {
    fn upgrade(ref self: TState, impl_hash: ClassHash);
}

#[starknet::interface]
trait IOwnable<TState> {
    fn owner(self: @TState) -> ContractAddress;
    fn transfer_ownership(ref self: TState, new_owner: ContractAddress);
}
