// SPDX-License-Identifier: MIT

use array::ArrayTrait;
use option::OptionTrait;
use starknet::ContractAddress;
use traits::{Into, TryInto};
use element::market::interface::{Order, FillParams, Fee};
use element::utils::{call, selectors, serde::SerializedAppend, unwrap_and_cast::UnwrapAndCast};

extern fn u32_to_felt252(a: u32) -> felt252 nopanic;
extern fn u64_to_felt252(a: u64) -> felt252 nopanic;
extern fn u128_to_felt252(a: u128) -> felt252 nopanic;
extern fn contract_address_to_felt252(address: ContractAddress) -> felt252 nopanic;

// H(StarkNetDomain{name='element_exchange',version='1.1',chainId='SN_MAIN'});
const STARK_NET_DOMAIN_HASH_MAIN: felt252 =
    0x298c80d073777754b584bcca1ec778e11dc3b8f7349c66066c60141c7aa0fe;
// H(StarkNetDomain{name='element_exchange',version='1.1',chainId='SN_GOERLI'});
const STARK_NET_DOMAIN_HASH_GOERLI: felt252 =
    0x39dfcf97c1e2f9dffe920030b3034b48b0b53403ecf71b4013ec03d185c72cb;

// Pedersen(Pedersen(0, 'StarkNet Message'), STARK_NET_DOMAIN_HASH_MAIN)
const INITIAL_STATE_MAIN: felt252 =
    0x35868df3902cc4db2206be6e5a96a77e3bda9570bff370d93eafe566f78065;
// Pedersen(Pedersen(0, 'StarkNet Message'), STARK_NET_DOMAIN_HASH_GOERLI)
const INITIAL_STATE_GOERLI: felt252 =
    0x6cf51a06db522d1399754595e32087537063ad4df9f9de89feee4d98b06da7a;

// INITIAL_STATE_MAIN
const INITIAL_STATE: felt252 = 0x35868df3902cc4db2206be6e5a96a77e3bda9570bff370d93eafe566f78065;

// H('Order(order_type:felt,maker:felt,taker:felt,listing_time:felt,expiry_time:felt,salt:felt,erc20_address:felt,erc20_amount:felt,fees:Fee*,nft_address:felt,nft_id:Uint256,nft_amount:felt,order_validator:felt,counter:felt)Fee(recipient:felt,amount:felt)Uint256(low:felt,high:felt)')
const ORDER_TYPE_HASH: felt252 = 0x203abb0fb72f791fd33a77fe3d0fa38f4ed90472ff64479c1578dd5fed766e3;
// Pedersen(0, ORDER_TYPE_HASH)
const ORDER_INITIAL_STATE: felt252 =
    0x332e1cb1837db0d4e53790895b5c0d6cc12dbf9e9ab1e739b79d3b4398e80af;
const ORDER_TYPE_LEN: felt252 = 15;

// H('Fee(recipient:felt,amount:felt)')
const FEE_TYPE_HASH: felt252 = 0x15ad6ba484fecfd920902ff8f7d29b4e6a71bf5ce555560079369b7e94b1abf;
// Pedersen(0, FEE_TYPE_HASH)
const FEE_INITIAL_STATE: felt252 =
    0x1dd148002132a4fc7547a9743345afc22e6f2b5305ff9de057e311b34466e25;

// H('Uint256(low:felt,high:felt)')
const UINT256_TYPE_HASH: felt252 =
    0x3ce8ecd329b79a545e13af4923b1d148151ab22076996e56e2d5f68a824d251;
// Pedersen(0, UINT256_TYPE_HASH)
const UINT256_INITIAL_STATE: felt252 =
    0x13e0077d478d4050166bb2af6f7aee9f1ba98da83ce5719f8552fb6f72df434;

// H('Message(order:Order)Fee(recipient:felt,amount:felt)Order(order_type:felt,maker:felt,taker:felt,listing_time:felt,expiry_time:felt,salt:felt,erc20_address:felt,erc20_amount:felt,fees:Fee*,nft_address:felt,nft_id:Uint256,nft_amount:felt,order_validator:felt,counter:felt)Uint256(low:felt,high:felt)')
const SINGLE_ORDER_TYPE_HASH: felt252 =
    0x1f9bbc45ab8987329b97a4061cf938ac040e07bb2d60987821503d073cf6023;
// Pedersen(0, SINGLE_ORDER_TYPE_HASH)
const SINGLE_ORDER_INITIAL_STATE: felt252 =
    0x6306bafa01d03eb8d411ff8d71b15fd1d7eaa33f519163f2da6df02a552a6f8;

// H('Message(orders:merkletree)')
const BULK_ORDER_TYPE_HASH: felt252 =
    0x24065c74e0ccfb96efc039512f78bc82d71c7da0a52e0f91b45a52237bc40ea;
// Pedersen(0, BULK_ORDER_TYPE_HASH)
const BULK_ORDER_INITIAL_STATE: felt252 =
    0x5913c14017e14caf79ac2f1812ce8ed5241ba690c3ba9ccfca1576cf8d16d31;

// H('Message(orders_root:felt)')
const ORDERS_ROOT_TYPE_HASH: felt252 =
    0x4418bf9f4d88cbdaf18e8acb3e6f83236bb0ddbc27da50bee0db3c5ec7ddd2;
// Pedersen(0, ORDERS_ROOT_TYPE_HASH)
const ORDERS_ROOT_INITIAL_STATE: felt252 =
    0x7c57a0e49c7add0bc58413416de33b47604663698bae7785d6774c7737d813c;

fn _get_order_hash(order: @Order) -> felt252 {
    let leaf = _get_order_leaf_hash(order);
    _hash_eip712(
        contract_address_to_felt252(*order.maker),
        pedersen(pedersen(SINGLE_ORDER_INITIAL_STATE, leaf), 2)
    )
}

fn _validate_signature(
    maker: ContractAddress, leaf: felt252, signature: @Array<felt252>
) -> felt252 {
    let signature_len = signature.len();
    if signature_len == 0_usize {
        panic_with_felt252('element: signature.len error');
    }

    let order_hash = _hash_eip712(
        contract_address_to_felt252(maker), pedersen(pedersen(SINGLE_ORDER_INITIAL_STATE, leaf), 2)
    );
    let mut args: Array<felt252> = array![];

    let signature_type = *signature.at(0);
    if signature_type == 0xfefefee0 { // Bulk order type and signature.len() == 2
        if signature_len < 3 {
            panic_with_felt252('element: signature.len error');
        }
        let message_hash = pedersen(
            pedersen(BULK_ORDER_INITIAL_STATE, _compute_merkle_root(leaf, 3_usize, signature)), 2
        );
        args.append(_hash_eip712(contract_address_to_felt252(maker), message_hash));
        args.append(2);
        args.append(*signature.at(1));
        args.append(*signature.at(2));
    } else if signature_type == 0xfefefee1 { // Order merkle root type and signature.len() == 2
        if signature_len < 3 {
            panic_with_felt252('element: signature.len error');
        }
        let message_hash = pedersen(
            pedersen(ORDERS_ROOT_INITIAL_STATE, _compute_merkle_root(leaf, 3_usize, signature)), 2
        );
        args.append(_hash_eip712(contract_address_to_felt252(maker), message_hash));
        args.append(2);
        args.append(*signature.at(1));
        args.append(*signature.at(2));
    } else if signature_type == 0xfefefef0 { // Bulk order type and signature.len() != 2
        let len: usize = (*signature.at(1)).try_into().unwrap();
        let proofs_start_index = 2_usize + len;
        if signature_len < proofs_start_index {
            panic_with_felt252('element: signature.len error');
        }
        let message_hash = pedersen(
            pedersen(
                BULK_ORDER_INITIAL_STATE, _compute_merkle_root(leaf, proofs_start_index, signature)
            ),
            2
        );
        args.append(_hash_eip712(contract_address_to_felt252(maker), message_hash));
        args.append(len.into());
        let mut i: usize = 2;
        loop {
            if i == proofs_start_index {
                break;
            }
            args.append(*signature.at(i));
            i += 1_usize;
        };
    } else if signature_type == 0xfefefef1 { // Order merkle root type and signature.len() != 2
        let len: usize = (*signature.at(1)).try_into().unwrap();
        let proofs_start_index = 2_usize + len;
        if signature_len < proofs_start_index {
            panic_with_felt252('element: signature.len error');
        }
        let message_hash = pedersen(
            pedersen(
                ORDERS_ROOT_INITIAL_STATE, _compute_merkle_root(leaf, proofs_start_index, signature)
            ),
            2
        );
        args.append(_hash_eip712(contract_address_to_felt252(maker), message_hash));
        args.append(len.into());
        let mut i: usize = 2;
        loop {
            if i == proofs_start_index {
                break;
            }
            args.append(*signature.at(i));
            i += 1_usize;
        };
    } else if (signature_type == 0xfefefef2) { // Single order type and signature.len() != 2
        args.append(order_hash);
        args.append((signature_len - 1).into());
        let mut i: usize = 1;
        loop {
            if i == signature_len {
                break;
            }
            args.append(*signature.at(i));
            i += 1_usize;
        };
    } else { // Single order type and signature.len() == 2
        assert(signature_len == 2_usize, 'element: signature.len error');
        args.append(order_hash);
        args.append(2);
        args.append(signature_type);
        args.append(*signature.at(1));
    }

    let is_valid: felt252 = call::try_selector_with_fallback(
        maker, selectors::isValidSignature, selectors::is_valid_signature, args.span()
    )
        .unwrap_and_cast();
    if is_valid == 0 {
        panic_with_felt252('element: invalid signature');
    }

    order_hash
}

fn _compute_merkle_root(leaf: felt252, start_index: usize, signature: @Array<felt252>) -> felt252 {
    let mut computed_root: felt252 = leaf;
    let mut i: usize = start_index;
    let len: usize = signature.len();
    loop {
        if i == len {
            break;
        }

        let proof: felt252 = *signature.at(i);
        if (Felt252IntoU256::into(computed_root) < Felt252IntoU256::into(proof)) {
            computed_root = pedersen(computed_root, proof);
        } else {
            computed_root = pedersen(proof, computed_root);
        }
        i += 1_usize;
    };
    computed_root
}

#[inline(always)]
fn _hash_eip712(account: felt252, message_hash: felt252) -> felt252 {
    pedersen(pedersen(pedersen(INITIAL_STATE, account), message_hash), 4)
}

#[inline(always)]
fn _get_order_leaf_hash(order: @Order) -> felt252 {
    let hash_state = pedersen(ORDER_INITIAL_STATE, u128_to_felt252(*order.order_type));
    let hash_state = pedersen(hash_state, contract_address_to_felt252(*order.maker));
    let hash_state = pedersen(hash_state, contract_address_to_felt252(*order.taker));
    let hash_state = pedersen(hash_state, u64_to_felt252(*order.listing_time));
    let hash_state = pedersen(hash_state, u64_to_felt252(*order.expiry_time));
    let hash_state = pedersen(hash_state, u128_to_felt252(*order.salt));
    let hash_state = pedersen(hash_state, contract_address_to_felt252(*order.erc20_address));
    let hash_state = pedersen(hash_state, u128_to_felt252(*order.erc20_amount));
    let hash_state = pedersen(hash_state, _hash_fees(order.fees));
    let hash_state = pedersen(hash_state, contract_address_to_felt252(*order.nft_address));
    let hash_state = pedersen(hash_state, _hash_uint256(*order.nft_id));
    let hash_state = pedersen(hash_state, u128_to_felt252(*order.nft_amount));
    let hash_state = pedersen(hash_state, contract_address_to_felt252(*order.order_validator));
    let hash_state = pedersen(hash_state, u128_to_felt252(*order.counter));
    pedersen(hash_state, ORDER_TYPE_LEN)
}

fn _hash_fees(fees: @Array<Fee>) -> felt252 {
    let mut hash_state: felt252 = 0;
    let mut i: usize = 0;
    let len: usize = fees.len();
    loop {
        if i == len {
            break;
        }
        hash_state = pedersen(hash_state, _hash_fee(fees.at(i)));
        i += 1_usize;
    };
    pedersen(hash_state, u32_to_felt252(len))
}

#[inline(always)]
fn _hash_fee(fee: @Fee) -> felt252 {
    let hash_state = pedersen(FEE_INITIAL_STATE, contract_address_to_felt252(*fee.recipient));
    let hash_state = pedersen(hash_state, u128_to_felt252(*fee.amount));
    pedersen(hash_state, 3)
}

#[inline(always)]
fn _hash_uint256(value: u256) -> felt252 {
    let hash_state = pedersen(UINT256_INITIAL_STATE, u128_to_felt252(value.low));
    let hash_state = pedersen(hash_state, u128_to_felt252(value.high));
    pedersen(hash_state, 3)
}
