use starknet::ContractAddress;

#[derive(Drop, Serde, starknet::Store)]
pub struct Policy {
    pub id: u256,
    pub user: ContractAddress,
    pub flight_id: u256,
    pub ticket_price: u256,
    pub premium_paid: u256,
    pub coverage_amount: u256,
    pub expiration: u64,
    pub active: bool,
    pub claimed: bool,
    pub airline: felt252,
    pub flight_number: felt252,
    pub flight_date: u64,
    pub departure_airport_iata: felt252,
}

#[starknet::interface]
pub trait IERC20<TContractState> {
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TContractState,
        sender: ContractAddress,
        recipient: ContractAddress,
        amount: u256,
    ) -> bool;
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
}

#[starknet::interface]
pub trait IPalomitoInsurance<TContractState> {
    fn buy_policy(
        ref self: TContractState,
        flight_id: u256,
        ticket_price: u256,
        expiration: u64,
        airline: felt252,
        flight_number: felt252,
        flight_date: u64,
        departure_airport_iata: felt252,
    );
    fn request_claim(ref self: TContractState, policy_id: u256);
    fn verify_and_pay_claim(
        ref self: TContractState, policy_id: u256, cancellation_triggered: bool,
    );
    fn expire_policy(ref self: TContractState, policy_id: u256);
    fn transfer_ownership(ref self: TContractState, new_owner: ContractAddress);

    fn get_policy(self: @TContractState, policy_id: u256) -> Policy;
    fn get_user_policies(self: @TContractState, user: ContractAddress) -> Array<u256>;
    fn quote_premium(self: @TContractState, ticket_price: u256) -> u256;
    fn get_owner(self: @TContractState) -> ContractAddress;
    fn get_usdc_token(self: @TContractState) -> ContractAddress;
    fn get_next_policy_id(self: @TContractState) -> u256;
    fn get_premium_bps(self: @TContractState) -> u256;
    fn contract_usdc_balance(self: @TContractState) -> u256;
}

#[starknet::contract]
mod PalomitoInsurance {
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp, get_contract_address};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use core::num::traits::Zero;
    use super::{Policy, IERC20Dispatcher, IERC20DispatcherTrait};

    const PREMIUM_BPS: u256 = 500; // 5%
    const BPS_DENOMINATOR: u256 = 10000;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        usdc_token: ContractAddress,
        next_policy_id: u256,
        // policy_id => Policy
        policies: Map<u256, Policy>,
        // user => count of policies
        user_policy_count: Map<ContractAddress, u32>,
        // (user, index) => policy_id
        user_policy_at: Map<(ContractAddress, u32), u256>,
        // reentrancy guard
        locked: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        PolicyPurchased: PolicyPurchased,
        ClaimRequested: ClaimRequested,
        ClaimVerified: ClaimVerified,
        ClaimPaid: ClaimPaid,
        PolicyExpired: PolicyExpired,
        PolicyStatusChanged: PolicyStatusChanged,
        OwnershipTransferred: OwnershipTransferred,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PolicyPurchased {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub policy_id: u256,
        pub flight_id: u256,
        pub coverage_amount: u256,
        pub premium_paid: u256,
        pub expiration: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ClaimRequested {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub policy_id: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ClaimVerified {
        #[key]
        pub policy_id: u256,
        pub triggered: bool,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ClaimPaid {
        #[key]
        pub user: ContractAddress,
        #[key]
        pub policy_id: u256,
        pub payout: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PolicyExpired {
        #[key]
        pub policy_id: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PolicyStatusChanged {
        #[key]
        pub policy_id: u256,
        pub active: bool,
        pub claimed: bool,
    }

    #[derive(Drop, starknet::Event)]
    pub struct OwnershipTransferred {
        #[key]
        pub previous_owner: ContractAddress,
        #[key]
        pub new_owner: ContractAddress,
    }

    pub mod Errors {
        pub const NOT_OWNER: felt252 = 'Not owner';
        pub const POLICY_NOT_ACTIVE: felt252 = 'Policy not active';
        pub const POLICY_ALREADY_CLAIMED: felt252 = 'Policy already claimed';
        pub const POLICY_NOT_FOUND: felt252 = 'Policy not found';
        pub const INSUFFICIENT_USDC: felt252 = 'Insufficient contract USDC';
        pub const REENTRANCY: felt252 = 'Reentrancy';
        pub const EXPIRATION_IN_PAST: felt252 = 'Expiration in past';
        pub const INVALID_TICKET_PRICE: felt252 = 'Invalid ticket price';
        pub const USDC_TRANSFER_FAILED: felt252 = 'USDC transfer failed';
        pub const POLICY_NOT_EXPIRED: felt252 = 'Policy not expired';
        pub const NOT_POLICY_OWNER: felt252 = 'Not policy owner';
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, usdc_token: ContractAddress) {
        self.owner.write(owner);
        self.usdc_token.write(usdc_token);
        self.next_policy_id.write(0);
        self.locked.write(false);
    }

    #[abi(embed_v0)]
    impl PalomitoInsuranceImpl of super::IPalomitoInsurance<ContractState> {
        fn buy_policy(
            ref self: ContractState,
            flight_id: u256,
            ticket_price: u256,
            expiration: u64,
            airline: felt252,
            flight_number: felt252,
            flight_date: u64,
            departure_airport_iata: felt252,
        ) {
            // Reentrancy guard
            assert(!self.locked.read(), Errors::REENTRANCY);
            self.locked.write(true);

            // Validation
            let current_time = get_block_timestamp();
            assert(expiration > current_time, Errors::EXPIRATION_IN_PAST);
            assert(ticket_price > 0, Errors::INVALID_TICKET_PRICE);

            // Calculate premium (5% of ticket price)
            let premium = (ticket_price * PREMIUM_BPS) / BPS_DENOMINATOR;

            // Transfer USDC from user to contract
            let caller = get_caller_address();
            let contract_address = get_contract_address();
            let usdc = IERC20Dispatcher { contract_address: self.usdc_token.read() };
            let success = usdc.transfer_from(caller, contract_address, premium);
            assert(success, Errors::USDC_TRANSFER_FAILED);

            // Create policy
            let policy_id = self.next_policy_id.read() + 1;
            self.next_policy_id.write(policy_id);

            let policy = Policy {
                id: policy_id,
                user: caller,
                flight_id,
                ticket_price,
                premium_paid: premium,
                coverage_amount: ticket_price,
                expiration,
                active: true,
                claimed: false,
                airline,
                flight_number,
                flight_date,
                departure_airport_iata,
            };

            self.policies.write(policy_id, policy);

            // Track user policies
            let count = self.user_policy_count.read(caller);
            self.user_policy_at.write((caller, count), policy_id);
            self.user_policy_count.write(caller, count + 1);

            // Emit events
            self
                .emit(
                    PolicyPurchased {
                        user: caller,
                        policy_id,
                        flight_id,
                        coverage_amount: ticket_price,
                        premium_paid: premium,
                        expiration,
                    },
                );
            self.emit(PolicyStatusChanged { policy_id, active: true, claimed: false });

            // Release lock
            self.locked.write(false);
        }

        fn request_claim(ref self: ContractState, policy_id: u256) {
            let policy = self.policies.read(policy_id);
            assert(policy.id != 0, Errors::POLICY_NOT_FOUND);
            assert(policy.active, Errors::POLICY_NOT_ACTIVE);
            assert(!policy.claimed, Errors::POLICY_ALREADY_CLAIMED);

            let caller = get_caller_address();
            assert(caller == policy.user, Errors::NOT_POLICY_OWNER);

            self.emit(ClaimRequested { user: caller, policy_id });
        }

        fn verify_and_pay_claim(
            ref self: ContractState, policy_id: u256, cancellation_triggered: bool,
        ) {
            // Only owner
            let caller = get_caller_address();
            assert(caller == self.owner.read(), Errors::NOT_OWNER);

            // Reentrancy guard
            assert(!self.locked.read(), Errors::REENTRANCY);
            self.locked.write(true);

            // Validate policy
            let policy = self.policies.read(policy_id);
            assert(policy.id != 0, Errors::POLICY_NOT_FOUND);
            assert(policy.active, Errors::POLICY_NOT_ACTIVE);
            assert(!policy.claimed, Errors::POLICY_ALREADY_CLAIMED);

            // Emit verification
            self.emit(ClaimVerified { policy_id, triggered: cancellation_triggered });

            if cancellation_triggered {
                let coverage = policy.coverage_amount;
                let user = policy.user;

                // Check contract balance
                let usdc = IERC20Dispatcher { contract_address: self.usdc_token.read() };
                let balance = usdc.balance_of(get_contract_address());
                assert(balance >= coverage, Errors::INSUFFICIENT_USDC);

                // Update policy state
                let updated_policy = Policy {
                    id: policy.id,
                    user: policy.user,
                    flight_id: policy.flight_id,
                    ticket_price: policy.ticket_price,
                    premium_paid: policy.premium_paid,
                    coverage_amount: policy.coverage_amount,
                    expiration: policy.expiration,
                    active: false,
                    claimed: true,
                    airline: policy.airline,
                    flight_number: policy.flight_number,
                    flight_date: policy.flight_date,
                    departure_airport_iata: policy.departure_airport_iata,
                };
                self.policies.write(policy_id, updated_policy);

                // Transfer USDC to user
                let success = usdc.transfer(user, coverage);
                assert(success, Errors::USDC_TRANSFER_FAILED);

                // Emit events
                self.emit(PolicyStatusChanged { policy_id, active: false, claimed: true });
                self.emit(ClaimPaid { user, policy_id, payout: coverage });
            }

            // Release lock
            self.locked.write(false);
        }

        fn expire_policy(ref self: ContractState, policy_id: u256) {
            let policy = self.policies.read(policy_id);
            assert(policy.id != 0, Errors::POLICY_NOT_FOUND);

            let current_time = get_block_timestamp();
            assert(current_time > policy.expiration, Errors::POLICY_NOT_EXPIRED);

            if !policy.active {
                return; // Already expired/claimed
            }

            // Update policy
            let updated_policy = Policy {
                id: policy.id,
                user: policy.user,
                flight_id: policy.flight_id,
                ticket_price: policy.ticket_price,
                premium_paid: policy.premium_paid,
                coverage_amount: policy.coverage_amount,
                expiration: policy.expiration,
                active: false,
                claimed: policy.claimed,
                airline: policy.airline,
                flight_number: policy.flight_number,
                flight_date: policy.flight_date,
                departure_airport_iata: policy.departure_airport_iata,
            };
            self.policies.write(policy_id, updated_policy);

            self.emit(PolicyExpired { policy_id });
            self.emit(PolicyStatusChanged { policy_id, active: false, claimed: policy.claimed });
        }

        fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            let caller = get_caller_address();
            assert(caller == self.owner.read(), Errors::NOT_OWNER);
            let previous_owner = self.owner.read();
            self.owner.write(new_owner);
            self.emit(OwnershipTransferred { previous_owner, new_owner });
        }

        // View functions

        fn get_policy(self: @ContractState, policy_id: u256) -> Policy {
            let policy = self.policies.read(policy_id);
            assert(policy.id != 0, Errors::POLICY_NOT_FOUND);
            policy
        }

        fn get_user_policies(self: @ContractState, user: ContractAddress) -> Array<u256> {
            let count = self.user_policy_count.read(user);
            let mut policy_ids: Array<u256> = ArrayTrait::new();
            let mut i: u32 = 0;
            while i < count {
                let policy_id = self.user_policy_at.read((user, i));
                policy_ids.append(policy_id);
                i += 1;
            };
            policy_ids
        }

        fn quote_premium(self: @ContractState, ticket_price: u256) -> u256 {
            (ticket_price * PREMIUM_BPS) / BPS_DENOMINATOR
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        fn get_usdc_token(self: @ContractState) -> ContractAddress {
            self.usdc_token.read()
        }

        fn get_next_policy_id(self: @ContractState) -> u256 {
            self.next_policy_id.read()
        }

        fn get_premium_bps(self: @ContractState) -> u256 {
            PREMIUM_BPS
        }

        fn contract_usdc_balance(self: @ContractState) -> u256 {
            let usdc = IERC20Dispatcher { contract_address: self.usdc_token.read() };
            usdc.balance_of(get_contract_address())
        }
    }
}
