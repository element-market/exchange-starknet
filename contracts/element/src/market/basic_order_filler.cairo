// SPDX-License-Identifier: MIT

use array::ArrayTrait;
use box::BoxTrait;
use zeroable::Zeroable;
use option::OptionTrait;
use traits::{Into, TryInto};
use starknet::{ContractAddress, ExecutionInfo, BlockInfo, get_execution_info};
use element::market::interface::{ERC721SellOrder, Fee};
use element::market::signature_validator::{ORDER_TYPE_LEN, FEE_INITIAL_STATE, _hash_uint256};
use element::market::order_executor::_erc20_transfer_from;

extern fn u64_to_felt252(a: u64) -> felt252 nopanic;
extern fn u128_to_felt252(a: u128) -> felt252 nopanic;
extern fn contract_address_to_felt252(address: ContractAddress) -> felt252 nopanic;

// Pedersen(ORDER_INITIAL_STATE, 1)
const ERC721_SELL_ORDER_INITIAL_STATE: felt252 =
    0x281b46ae8dc1d2961f37c692825c26ac1adf68db9631424f924638d8555405d;

#[inline(always)]
fn _get_erc721_sell_order_info(
    order: ERC721SellOrder, counter: u128
) -> (ContractAddress, felt252) {
    if order.maker == 0 {
        panic_with_felt252('element: invalid maker');
    }
    if order.erc20_address.is_zero() {
        panic_with_felt252('element: invalid erc20 address');
    }
    if order.nft_address.is_zero() {
        panic_with_felt252('element: invalid nft address');
    }

    let execution_info = get_execution_info().unbox();
    let now = execution_info.block_info.unbox().block_timestamp;
    if now < order.listing_time {
        panic_with_felt252('element: not started');
    }
    if now >= order.expiry_time {
        panic_with_felt252('element: is expired');
    }

    let hash_state = pedersen(ERC721_SELL_ORDER_INITIAL_STATE, order.maker);
    let hash_state = pedersen(hash_state, 0); // taker
    let hash_state = pedersen(hash_state, u64_to_felt252(order.listing_time));
    let hash_state = pedersen(hash_state, u64_to_felt252(order.expiry_time));
    let hash_state = pedersen(hash_state, order.salt);
    let hash_state = pedersen(hash_state, contract_address_to_felt252(order.erc20_address));
    let hash_state = pedersen(hash_state, u128_to_felt252(order.erc20_amount));

    // hash fees
    let mut fee_state: felt252 = 0;
    let mut i: felt252 = 0;
    if order.fee0_recipient != 0 {
        let hash_state = pedersen(FEE_INITIAL_STATE, order.fee0_recipient);
        let hash_state = pedersen(hash_state, u128_to_felt252(order.fee0_amount));
        fee_state = pedersen(fee_state, pedersen(hash_state, 3));
        i = 1;
    }
    if order.fee1_recipient != 0 {
        let hash_state = pedersen(FEE_INITIAL_STATE, order.fee1_recipient);
        let hash_state = pedersen(hash_state, u128_to_felt252(order.fee1_amount));
        fee_state = pedersen(fee_state, pedersen(hash_state, 3));
        i += 1;
    }
    let hash_state = pedersen(hash_state, pedersen(fee_state, i));
    let hash_state = pedersen(hash_state, contract_address_to_felt252(order.nft_address));
    let hash_state = pedersen(hash_state, _hash_uint256(order.nft_id.into()));
    let hash_state = pedersen(hash_state, 1); // nft_amount
    let hash_state = pedersen(hash_state, 0); // order_validator
    let hash_state = pedersen(hash_state, u128_to_felt252(counter));

    (execution_info.caller_address, pedersen(hash_state, ORDER_TYPE_LEN))
}

#[inline(always)]
fn _transfer_erc20_from_caller(order: @ERC721SellOrder, caller: felt252) -> Span<Fee> {
    let erc20_address = *order.erc20_address;
    let mut amount_to_seller = *order.erc20_amount;
    let fee0_recipient = *order.fee0_recipient;
    let fee0_amount = *order.fee0_amount;
    let fee1_recipient = *order.fee1_recipient;
    let fee1_amount = *order.fee1_amount;

    let mut fees: Array<Fee> = array![];
    if fee0_recipient != 0 {
        if fee0_amount != 0_u128 {
            amount_to_seller -= fee0_amount;
            _erc20_transfer_from(erc20_address, caller, fee0_recipient, fee0_amount);
        }
        fees.append(Fee { recipient: fee0_recipient.try_into().unwrap(), amount: fee0_amount });
    }

    if fee1_recipient != 0 {
        if fee1_amount != 0_u128 {
            amount_to_seller -= fee1_amount;
            _erc20_transfer_from(erc20_address, caller, fee1_recipient, fee1_amount);
        }
        fees.append(Fee { recipient: fee1_recipient.try_into().unwrap(), amount: fee1_amount });
    }

    if amount_to_seller != 0_u128 {
        _erc20_transfer_from(erc20_address, caller, *order.maker, amount_to_seller);
    }

    fees.span()
}
