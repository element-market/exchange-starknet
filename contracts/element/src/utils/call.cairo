// SPDX-License-Identifier: MIT

use array::ArrayTrait;
use array::SpanTrait;
use box::BoxTrait;
use option::OptionTrait;
use starknet::ContractAddress;
use starknet::SyscallResult;
use starknet::SyscallResultTrait;
use starknet::call_contract_syscall;
use element::utils::unwrap_and_cast::UnwrapAndCast;

fn try_selector_with_fallback(
    target: ContractAddress, snake_selector: felt252, camel_selector: felt252, args: Span<felt252>
) -> SyscallResult<Span<felt252>> {
    match call_contract_syscall(target, snake_selector, args) {
        Result::Ok(ret) => Result::Ok(ret),
        Result::Err(errors) => {
            if *errors.at(0) == 'ENTRYPOINT_NOT_FOUND' {
                call_contract_syscall(target, camel_selector, args)
            } else {
                Result::Err(errors)
            }
        }
    }
}
