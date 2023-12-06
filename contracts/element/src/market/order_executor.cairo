// SPDX-License-Identifier: MIT

use array::ArrayTrait;
use option::OptionTrait;
use traits::Into;
use starknet::ContractAddress;
use starknet::SyscallResultTrait;
use integer::{U256TryIntoU128, U128IntoU256, u128_overflowing_mul};
use element::market::interface::{Order, Fee};
use element::utils::{call, selectors, serde::SerializedAppend, unwrap_and_cast::UnwrapAndCast};

#[inline(always)]
fn transfer_nft(
    order: @Order,
    fill_id: u256,
    fill_amount: u128,
    caller: ContractAddress,
    recipient: ContractAddress
) {
    let maker = *order.maker;
    let order_type = *order.order_type;
    let sell_order = (order_type & 0x1) != 0;
    let is_erc721 = (order_type & 0x2) == 0;

    let mut args: Array<felt252> = array![];
    if sell_order {
        args.append_serde(maker);
        args.append_serde(recipient);
    } else {
        args.append_serde(caller);
        args.append_serde(maker);
    }
    args.append_serde(fill_id);

    if is_erc721 {
        call::try_selector_with_fallback(
            *order.nft_address, selectors::transferFrom, selectors::transfer_from, args.span()
        )
            .unwrap_syscall();
    } else {
        args.append_serde(U128IntoU256::into(fill_amount));
        args.append_serde(ArrayTrait::<felt252>::new());
        call::try_selector_with_fallback(
            *order.nft_address,
            selectors::safeTransferFrom,
            selectors::safe_transfer_from,
            args.span()
        )
            .unwrap_syscall();
    }
}

fn transfer_erc20(
    order: @Order, fill_amount: u128, caller: ContractAddress, recipient: ContractAddress
) -> (u128, Span<Fee>) {
    let nft_amount = *order.nft_amount;
    let erc20_amount = _calculate_payable_amount(*order.erc20_amount, fill_amount, nft_amount);
    let erc20_address = *order.erc20_address;
    let (payer, payee) = _get_payer_and_payee(order, caller, recipient);

    // pay fees;
    let fees = order.fees;
    let mut payable_fees: Array<Fee> = array![];
    let mut amount_to_payee = erc20_amount;
    let mut i: usize = 0;
    let len = fees.len();

    loop {
        if i == len {
            break;
        }

        let amount = _calculate_payable_amount(*fees.at(i).amount, fill_amount, nft_amount);
        let recipient = *fees.at(i).recipient;
        if amount != 0_u128 {
            _erc20_transfer_from(erc20_address, payer.into(), recipient.into(), amount);
            amount_to_payee -= amount;
        }
        payable_fees.append(Fee { recipient, amount });
        i += 1_usize;
    };

    // pay to payee
    if amount_to_payee != 0_u128 {
        _erc20_transfer_from(erc20_address, payer.into(), payee.into(), amount_to_payee);
    }

    (erc20_amount, payable_fees.span())
}

#[inline(always)]
fn _get_payer_and_payee(
    order: @Order, caller: ContractAddress, recipient: ContractAddress
) -> (ContractAddress, ContractAddress) {
    if (*order.order_type & 0x1) == 0 { // buy order
        (*order.maker, recipient)
    } else { // sell order
        (caller, *order.maker)
    }
}

#[inline(always)]
fn _calculate_payable_amount(erc20_amount: u128, fill_amount: u128, nft_amount: u128) -> u128 {
    if fill_amount == nft_amount {
        erc20_amount
    } else {
        let (result, overflowing) = u128_overflowing_mul(erc20_amount, fill_amount);
        if overflowing {
            let amount = U128IntoU256::into(erc20_amount)
                * U128IntoU256::into(fill_amount)
                / U128IntoU256::into(nft_amount);
            U256TryIntoU128::try_into(amount).unwrap()
        } else {
            result / nft_amount
        }
    }
}

#[inline(always)]
fn _erc20_transfer_from(erc20_address: ContractAddress, from: felt252, to: felt252, amount: u128) {
    let args: Array<felt252> = array![from, to, amount.into(), 0];
    let ret: bool = call::try_selector_with_fallback(
        erc20_address, selectors::transferFrom, selectors::transfer_from, args.span()
    )
        .unwrap_and_cast();
    assert(ret, 'element: transfer erc20 failed');
}
