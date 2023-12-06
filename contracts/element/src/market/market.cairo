// SPDX-License-Identifier: MIT

#[starknet::contract]
mod Market {
    use starknet::{
        ContractAddress, ClassHash, get_caller_address, call_contract_syscall, replace_class_syscall
    };
    use zeroable::Zeroable;
    use array::ArrayTrait;
    use option::OptionTrait;
    use traits::{Into, TryInto};
    use element::market::interface::{
        Fee, Order, ERC721SellOrder, FillParams, OrderStatus, IOrderFeature, IOwnable, IUpgradeable
    };
    use element::market::event::{
        Event, CounterIncremented, OrderCancelled, OrderFilled, OwnershipTransferred, Upgraded
    };
    use element::market::order_checker::check_order;
    use element::market::signature_validator::{
        _get_order_hash, _get_order_leaf_hash, _validate_signature
    };
    use element::market::basic_order_filler::{
        _get_erc721_sell_order_info, _transfer_erc20_from_caller
    };
    use element::market::order_executor::{transfer_nft, transfer_erc20};
    use element::utils::{
        selectors, serde::SerializedAppend, unwrap_and_cast::UnwrapAndCast,
        call::try_selector_with_fallback
    };

    extern fn u128_to_felt252(a: u128) -> felt252 nopanic;
    extern fn contract_address_to_felt252(address: ContractAddress) -> felt252 nopanic;

    #[storage]
    struct Storage {
        _maker_counter: LegacyMap<ContractAddress, u128>,
        _order_status: LegacyMap<felt252, felt252>,
        _reentrancy_guard: bool,
        _owner: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self._transfer_ownership(owner);
    }

    #[external(v0)]
    impl OrderFeatureImpl of IOrderFeature<ContractState> {
        fn buy_erc721(ref self: ContractState, order: ERC721SellOrder, signature: Array<felt252>) {
            self._reentrancy_enter();

            // step1: read counter
            let maker = order.maker;
            let maker_address: ContractAddress = maker.try_into().unwrap();
            let counter = self._maker_counter.read(maker_address);

            // step2: check params and validate signature
            let (caller, leaf_hash) = _get_erc721_sell_order_info(order, counter);
            let order_hash = _validate_signature(maker_address, leaf_hash, @signature);

            // step3: check and update order status
            self._check_and_update_order_status(order_hash, 1, 1);

            // step4: transfer_erc721
            let nft_id: u256 = order.nft_id.into();
            let args = array![
                maker,
                contract_address_to_felt252(caller),
                u128_to_felt252(nft_id.low),
                u128_to_felt252(nft_id.high)
            ];
            try_selector_with_fallback(
                order.nft_address, selectors::transferFrom, selectors::transfer_from, args.span()
            )
                .unwrap_syscall();

            // step5: transfer_erc20
            let fees = _transfer_erc20_from_caller(@order, contract_address_to_felt252(caller));

            // step6: emit event
            self
                .emit(
                    OrderFilled {
                        order_hash,
                        order_type: 1_u128,
                        maker: maker_address,
                        taker: caller,
                        erc20_address: order.erc20_address,
                        erc20_amount: order.erc20_amount,
                        fees,
                        nft_address: order.nft_address,
                        nft_id,
                        nft_amount: 1,
                    }
                );

            self._reentrancy_exit();
        }

        fn fill_order(ref self: ContractState, order: Order, params: FillParams) {
            self._reentrancy_enter();
            self._fill_order(@order, @params);
            self._reentrancy_exit();
        }

        fn cancel_orders(ref self: ContractState, orders: Array<Order>) {
            self._assert_not_entered();

            let caller = get_caller_address();
            let mut i: usize = 0;
            let len: usize = orders.len();

            loop {
                if i == len {
                    break;
                }

                let order = orders.at(i);
                assert(caller == *order.maker, 'invalid caller');

                let order_hash = _get_order_hash(order);
                let status: felt252 = self._order_status.read(order_hash);
                let (is_cancelled, filled_amount) = _decode_order_status(status);
                let new_status = _encode_order_status(true, filled_amount);
                self._order_status.write(order_hash, new_status);
                self.emit(OrderCancelled { account: caller, order_hash });

                i += 1_usize;
            };
        }

        fn increment_counter(ref self: ContractState) -> u128 {
            self._assert_not_entered();

            let account = get_caller_address();
            let counter = self._maker_counter.read(account);
            let new_counter = counter + 1_u128;
            self._maker_counter.write(account, new_counter);
            self.emit(CounterIncremented { account, new_counter });

            new_counter
        }

        fn get_counter(self: @ContractState, account: ContractAddress) -> u128 {
            self._maker_counter.read(account)
        }

        fn get_order_status(self: @ContractState, order_hash: felt252) -> OrderStatus {
            let status: felt252 = self._order_status.read(order_hash);
            let (is_cancelled, filled_amount) = _decode_order_status(status);
            OrderStatus { is_cancelled, filled_amount }
        }

        fn get_order_hash(self: @ContractState, order: Order) -> felt252 {
            _get_order_hash(@order)
        }

        fn validate_signature(self: @ContractState, order: Order, signature: Array<felt252>) {
            let leaf_hash = _get_order_leaf_hash(@order);
            _validate_signature(order.maker, leaf_hash, @signature);
        }
    }

    #[external(v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, impl_hash: ClassHash) {
            self._assert_only_owner();
            if impl_hash.is_zero() {
                panic_with_felt252('Class hash cannot be zero');
            }
            replace_class_syscall(impl_hash).unwrap_syscall();
            self.emit(Upgraded { class_hash: impl_hash });
        }
    }

    #[external(v0)]
    impl OwnableImpl of IOwnable<ContractState> {
        fn owner(self: @ContractState) -> ContractAddress {
            self._owner.read()
        }

        fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            assert(!new_owner.is_zero(), 'New owner is the zero address');
            self._assert_only_owner();
            self._transfer_ownership(new_owner);
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _fill_order(ref self: ContractState, order: @Order, params: @FillParams) {
            // step1: check order params.
            let maker = *order.maker;
            let counter = self._maker_counter.read(maker);
            let (caller, recipient, merkle_root) = check_order(order, params, counter);

            // step2: validate signature.
            let leaf_hash = _get_order_leaf_hash(order);
            let order_hash = _validate_signature(*order.maker, leaf_hash, params.signature);

            // step3: validate order if needed.
            _validate_order(order, params, merkle_root, order_hash);

            // step4: check and update order status
            let nft_amount = *order.nft_amount;
            let fill_amount = *params.fill_amount;
            self._check_and_update_order_status(order_hash, nft_amount, fill_amount);

            // step5: transfer nft
            let fill_id = *params.fill_id;
            transfer_nft(order, fill_id, fill_amount, caller, recipient);

            // step6: transfer erc20
            let (erc20_amount, fees) = transfer_erc20(order, fill_amount, caller, recipient);

            // step7: emit event
            self
                .emit(
                    OrderFilled {
                        order_hash,
                        order_type: *order.order_type,
                        maker: maker,
                        taker: recipient,
                        erc20_address: *order.erc20_address,
                        erc20_amount,
                        fees,
                        nft_address: *order.nft_address,
                        nft_id: fill_id,
                        nft_amount: fill_amount,
                    }
                );
        }

        #[inline(always)]
        fn _check_and_update_order_status(
            ref self: ContractState, order_hash: felt252, nft_amount: u128, fill_amount: u128
        ) {
            let status: felt252 = self._order_status.read(order_hash);
            let (is_cancelled, filled_amount) = _decode_order_status(status);
            if is_cancelled {
                panic_with_felt252('element: order cancelled');
            }

            if nft_amount == fill_amount && filled_amount == 0_u128 {
                let new_status = _encode_order_status(is_cancelled, fill_amount);
                self._order_status.write(order_hash, new_status);
            } else {
                let amount = fill_amount + filled_amount;
                if amount > nft_amount {
                    panic_with_felt252('element: exceeds nft amount');
                }
                let new_status = _encode_order_status(is_cancelled, amount);
                self._order_status.write(order_hash, new_status);
            }
        }

        #[inline(always)]
        fn _assert_not_entered(ref self: ContractState) {
            if self._reentrancy_guard.read() {
                panic_with_felt252('element: reentrant call');
            }
        }

        #[inline(always)]
        fn _reentrancy_enter(ref self: ContractState) {
            self._assert_not_entered();
            self._reentrancy_guard.write(true);
        }

        #[inline(always)]
        fn _reentrancy_exit(ref self: ContractState) {
            self._reentrancy_guard.write(false);
        }

        #[inline(always)]
        fn _assert_only_owner(ref self: ContractState) {
            let caller: ContractAddress = get_caller_address();
            if caller.is_zero() {
                panic_with_felt252('Caller is the zero address');
            }
            assert(caller == self._owner.read(), 'Caller is not the owner');
        }

        #[inline(always)]
        fn _transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            let previous_owner: ContractAddress = self._owner.read();
            self._owner.write(new_owner);
            self
                .emit(
                    OwnershipTransferred { previous_owner: previous_owner, new_owner: new_owner }
                );
        }
    }

    #[inline(always)]
    fn _decode_order_status(status: felt252) -> (bool, u128) {
        let status_u256: u256 = Felt252IntoU256::into(status);
        let is_cancelled: bool = status_u256.high != 0;
        (is_cancelled, status_u256.low)
    }

    #[inline(always)]
    fn _encode_order_status(is_cancelled: bool, filled_amount: u128) -> felt252 {
        if is_cancelled {
            0x100000000000000000000000000000000_felt252 + filled_amount.into()
        } else {
            filled_amount.into()
        }
    }

    fn _validate_order(
        order: @Order, params: @FillParams, merkle_root: felt252, order_hash: felt252
    ) {
        let validator = *order.order_validator;
        if !validator.is_zero() {
            let mut args: Array<felt252> = array![];
            args.append_serde(*order.nft_address);
            args.append_serde(*params.fill_id);
            args.append_serde(merkle_root);
            args.append_serde(order_hash);
            args.append_serde(Span { snapshot: params.extra_data });

            let magic: felt252 = call_contract_syscall(
                validator, selectors::validate_element_order, args.span()
            )
                .unwrap_and_cast();
            assert(magic == selectors::validate_element_order, 'element: validate order error');
        }
    }
}
