// SPDX-License-Identifier: MIT

use array::ArrayTrait;
use box::BoxTrait;
use zeroable::Zeroable;
use integer::{U256TryIntoFelt252, BoundedU128};
use option::OptionTrait;
use traits::{Into, TryInto};
use starknet::{ContractAddress, ExecutionInfo, BlockInfo, get_execution_info};
use element::market::interface::{Order, FillParams, Fee};

#[inline(always)]
fn check_order(
    order: @Order, params: @FillParams, counter: u128
) -> (ContractAddress, ContractAddress, felt252) {
    assert(*order.counter == counter, 'element: unmatched counter');
    if (*order.maker).is_zero() {
        panic_with_felt252('element: invalid maker');
    }
    if (*order.erc20_address).is_zero() {
        panic_with_felt252('element: erc20 address');
    }
    if (*order.nft_address).is_zero() {
        panic_with_felt252('element: invalid nft address');
    }

    let execution_info = get_execution_info().unbox();
    let now = execution_info.block_info.unbox().block_timestamp;
    if now < *order.listing_time {
        panic_with_felt252('element: not started');
    }
    if now >= *order.expiry_time {
        panic_with_felt252('element: is expired');
    }

    let mut recipient = *params.recipient;
    if recipient.is_zero() {
        recipient = execution_info.caller_address;
    }
    if !(*order.taker).is_zero() {
        assert(*order.taker == recipient, 'element: invalid recipient');
    }

    _check_fees(order.fees, *order.erc20_amount);

    let order_type = *order.order_type;
    if order_type == 5 || order_type > 6 {
        panic_with_felt252('element: invalid order type');
    }

    let nft_amount = *order.nft_amount;
    if nft_amount == 0 {
        panic_with_felt252('element: invalid nft amount');
    }

    let fill_amount = *params.fill_amount;
    let is_erc721 = (order_type & 0x2) == 0;
    if is_erc721 {
        assert(fill_amount == 1, 'element: invalid fill amount');
    } else {
        if fill_amount == 0 || fill_amount > nft_amount {
            panic_with_felt252('element: invalid fill amount');
        }
    }

    let mut merkle_root: felt252 = 0;
    let nft_id = *order.nft_id;

    // is_contract_offer
    if order_type == 4 || order_type == 6 {
        if (*order.order_validator).is_zero() {
            assert(nft_id == 0, 'element: invalid nft id');
        } else {
            merkle_root = U256TryIntoFelt252::try_into(nft_id).unwrap();
        }
    } else {
        assert(*params.fill_id == nft_id, 'element: invalid fill id');

        if is_erc721 {
            assert(nft_amount == 1, 'element: invalid nft amount');
        }
    }

    (execution_info.caller_address, recipient, merkle_root)
}

fn _check_fees(fees: @Array<Fee>, erc20_amount: u128) {
    let mut total_fee: u128 = 0;
    let mut i: usize = 0;
    let len: usize = fees.len();
    loop {
        if i == len {
            break;
        }

        total_fee += *fees.at(i).amount;
        if (*fees.at(i).recipient).is_zero() {
            panic_with_felt252('element: invalid fee.recipient');
        }
        i += 1_usize;
    };
    if total_fee > erc20_amount {
        panic_with_felt252('element: invalid fees');
    }
}
