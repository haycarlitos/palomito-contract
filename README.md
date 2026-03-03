# Palomito Insurance — StarkNet Smart Contract

Parametric flight cancellation insurance on StarkNet. Users pay a 5% premium on their ticket price; if their flight is cancelled, they receive 100% of the ticket price as a USDC payout — automatically, no paperwork.

**Deployed on StarkNet Mainnet:**
`0x031730cbcfa99c5d79758cab5b457a8f10f1ce2e15d2767c7a4ba9c48b55308f`

**USDC Token (StarkNet):**
`0x033068f6539f8e6e6b131e6b2b814e6c34a5224bc66947c47dab9dfee93b35fb`

---

## How It Works

### Policy Lifecycle

```
  User Journey                    On-Chain State              Off-Chain State
  ============                    ==============              ===============

  1. User enters flight
     details + ticket price

  2. Frontend calculates
     5% premium

  3. User confirms purchase
     |
     +---> USDC.approve()
     +---> buy_policy()
           |
           +---> Policy created   +---> DB record created
                 active: true           status: "active"
                 claimed: false

                 ... time passes, flight date arrives ...

  4a. Flight CANCELLED
      |
      +---> User clicks "Claim"
           |
           +---> request_claim()  +---> Claim record created
                 (emits event)          status: "in_verification"

  5a. Cron job verifies via
      AeroDataBox API
      |
      +---> Flight confirmed      +---> status: "approved"
            cancelled

  6a. Admin calls
      verify_and_pay_claim()
      |
      +---> USDC transferred      +---> status: "paid"
            to user wallet              paymentTxHash stored
            active: false
            claimed: true               Email sent to user

  4b. Flight ON TIME
      |
      +---> Policy expires        +---> status: "expired"
            after flight date
            active: false
            (premium stays in pool)
```

### Premium & Payout Math

```
  PREMIUM CALCULATION
  ===================

  ticket_price = $200 USDC
  PREMIUM_BPS  = 500 (5%)

  premium = (200 * 500) / 10000 = $10 USDC

  PAYOUT RATIO
  =============

  premium:payout = 1:20

  For every $1 collected as premium,
  the pool owes $20 if the flight is cancelled.

  BREAK-EVEN
  ===========

  If exactly 5% of policies trigger a payout,
  the pool breaks even:

  100 policies x $200 ticket = $1,000 in premiums
  5 claims x $200 payout     = $1,000 in payouts
                              = $0 net

  Current claim rate (cancellations only): ~1-2%
  Expected profit margin: ~3-4% of premiums
```

---

## Contract Interface

### Write Functions

| Function | Caller | Description |
|---|---|---|
| `buy_policy(flight_id, ticket_price, expiration, airline, flight_number, flight_date, departure_airport_iata)` | Any user | Purchase a policy. Transfers 5% premium in USDC from caller to contract. |
| `request_claim(policy_id)` | Policy owner | Signal intent to claim. Emits `ClaimRequested` event. |
| `verify_and_pay_claim(policy_id, cancellation_triggered)` | Contract owner | Verify cancellation and pay out coverage amount in USDC to user. |
| `expire_policy(policy_id)` | Anyone | Mark an expired policy as inactive. Premium stays in pool. |
| `transfer_ownership(new_owner)` | Contract owner | Transfer admin rights. |

### View Functions

| Function | Returns | Description |
|---|---|---|
| `get_policy(policy_id)` | `Policy` | Full policy struct |
| `get_user_policies(user)` | `Array<u256>` | All policy IDs for a wallet |
| `quote_premium(ticket_price)` | `u256` | Calculate premium for a given ticket price |
| `get_owner()` | `ContractAddress` | Current admin address |
| `get_usdc_token()` | `ContractAddress` | USDC token address |
| `get_next_policy_id()` | `u256` | Next policy ID counter |
| `get_premium_bps()` | `u256` | Premium rate in basis points (500 = 5%) |
| `contract_usdc_balance()` | `u256` | Current USDC balance (= pool size) |

### Events

| Event | Indexed Fields | Data |
|---|---|---|
| `PolicyPurchased` | `user`, `policy_id` | `flight_id`, `coverage_amount`, `premium_paid`, `expiration` |
| `ClaimRequested` | `user`, `policy_id` | — |
| `ClaimVerified` | `policy_id` | `triggered` (bool) |
| `ClaimPaid` | `user`, `policy_id` | `payout` |
| `PolicyExpired` | `policy_id` | — |
| `PolicyStatusChanged` | `policy_id` | `active`, `claimed` |
| `OwnershipTransferred` | `previous_owner`, `new_owner` | — |

### Policy Struct

```cairo
struct Policy {
    id: u256,
    user: ContractAddress,
    flight_id: u256,
    ticket_price: u256,       // USDC amount (6 decimals)
    premium_paid: u256,       // 5% of ticket_price
    coverage_amount: u256,    // = ticket_price (100% payout)
    expiration: u64,          // Unix timestamp
    active: bool,
    claimed: bool,
    airline: felt252,         // Short string, e.g. "AM"
    flight_number: felt252,   // Short string, e.g. "456"
    flight_date: u64,         // Unix timestamp
    departure_airport_iata: felt252,  // e.g. "MEX"
}
```

---

## Security

| Mechanism | Implementation |
|---|---|
| Reentrancy guard | `locked` storage bool, checked on `buy_policy` and `verify_and_pay_claim` |
| Owner-only payout | `verify_and_pay_claim` asserts `caller == owner` |
| Policy ownership | `request_claim` asserts `caller == policy.user` |
| Balance check | Payout verifies `contract USDC balance >= coverage_amount` before transfer |
| Expiration validation | `buy_policy` requires `expiration > block_timestamp` |
| USDC transfer validation | Both `transfer_from` and `transfer` results are asserted |

---

## Build & Deploy

### Prerequisites

- [Scarb](https://docs.swmansion.com/scarb/) (Cairo package manager) — v2.11.2+
- [Starkli](https://github.com/xJonathanLEI/starkli) (CLI for StarkNet)

### Build

```bash
scarb build
```

Outputs Sierra JSON to `target/dev/palomito_insurance_PalomitoInsurance.contract_class.json`.

### Declare & Deploy

```bash
# Declare the contract class
starkli declare target/dev/palomito_insurance_PalomitoInsurance.contract_class.json \
  --account <account-file> --keystore <keystore-file>

# Deploy with constructor args: (owner_address, usdc_token_address)
starkli deploy <class-hash> \
  <owner-address> \
  <usdc-token-address> \
  --account <account-file> --keystore <keystore-file>
```

---

## Roadmap: StarkNet DeFi Integration

### Phase 1 — Yield on Idle Pool Capital (Q2 2026)

The contract's USDC balance sits idle between premium collection and claim payouts. This is capital that could be earning yield.

```
  CURRENT STATE                       PHASE 1: YIELD INTEGRATION
  =============                       ==========================

  +------------------+                +------------------+
  |  Palomito        |                |  Palomito        |
  |  Contract        |                |  Contract v2     |
  |                  |                |                  |
  |  USDC balance:   |                |  Reserve: 30%    |----> Instant claims
  |  $10,000         |                |  ($3,000 USDC)   |
  |  (100% idle)     |                |                  |
  |                  |                |  Deployed: 70%   |
  +------------------+                |  ($7,000 USDC)   |
                                      |       |          |
                                      +-------+----------+
                                              |
                                              v
                                      +------------------+
                                      |  Nostra / zkLend |
                                      |  Lending Pool    |
                                      |                  |
                                      |  Earns 3-8% APY  |
                                      |  on USDC         |
                                      +------------------+
```

**Integration targets:**
- [Nostra Finance](https://nostra.finance/) — USDC lending market on StarkNet
- [Ekubo](https://ekubo.org/) — concentrated liquidity DEX (for USDC/STRK LP)

**Implementation:**
1. Add a `deposit_to_lending(amount)` admin function that moves USDC to a lending protocol
2. Add a `withdraw_from_lending(amount)` function to pull USDC back for claim payouts
3. Keep a configurable reserve ratio (e.g. 30%) in the contract for instant payouts
4. Yield accrues to the pool, compounding its solvency

**Estimated impact:** At $50K pool with 70% deployed to Nostra at 5% APY = ~$1,750/year additional revenue.

### Phase 2 — Pool Tokenization with LP Shares (Q3 2026)

Allow external capital providers to deposit USDC into the insurance pool and earn premiums proportionally.

```
  LP POOL ARCHITECTURE
  ====================

  +----------------+     +----------------+     +----------------+
  |  LP Provider A |     |  LP Provider B |     |  LP Provider C |
  |  Deposits      |     |  Deposits      |     |  Deposits      |
  |  $5,000 USDC   |     |  $10,000 USDC  |     |  $5,000 USDC   |
  +-------+--------+     +-------+--------+     +-------+--------+
          |                       |                       |
          v                       v                       v
  +-------------------------------------------------------+
  |                                                       |
  |  Palomito Pool Token (ERC-20)                         |
  |  pUSDC — represents share of the insurance pool       |
  |                                                       |
  |  Total deposits: $20,000 USDC                         |
  |  Total pUSDC supply: 20,000                           |
  |                                                       |
  |  Premium income flows in --> pUSDC value increases     |
  |  Claim payouts flow out  --> pUSDC value decreases     |
  |                                                       |
  |  Net effect (at 1% claim rate, 5% premium):           |
  |  +4% net APY to LPs from underwriting profit          |
  |                                                       |
  +-------------------------------------------------------+
          |
          v
  +---------------------------+
  |  Insurance Operations     |
  |                           |
  |  buy_policy() --> pool    |
  |  verify_and_pay() <-- pool|
  +---------------------------+
```

**Key design:**
- `pUSDC` ERC-20 token minted on deposit, burned on withdrawal
- Share price = `pool_total_assets / pUSDC_supply` (increases with premiums)
- Time-locked withdrawals (e.g. 7-day cooldown) to prevent bank runs
- Cap total pool size to limit exposure

**Composability with StarkNet DeFi:**
- pUSDC could be tradeable on Ekubo or other StarkNet DEXes
- pUSDC could be used as collateral on lending protocols
- Creates a new "insurance underwriting" yield primitive on StarkNet

### Phase 3 — Oracle-Triggered Automatic Payouts (Q4 2026)

Replace the admin-signed `verify_and_pay_claim()` with oracle-verified automatic payouts.

```
  CURRENT: ADMIN-VERIFIED                PHASE 3: ORACLE-VERIFIED
  ========================                ========================

  Flight cancelled                        Flight cancelled
       |                                       |
       v                                       v
  Off-chain cron                          Pragma Oracle
  checks AeroDataBox                      (on-chain data feed)
       |                                       |
       v                                       v
  Admin wallet signs                      Contract reads oracle
  verify_and_pay_claim()                  auto-triggers payout
       |                                       |
       v                                       v
  USDC sent to user                       USDC sent to user
                                          (no admin needed)
  Trust: centralized admin                Trust: oracle + smart contract
```

**Integration target:**
- [Pragma](https://pragma.build/) — StarkNet-native oracle network. Pragma already provides price feeds; a custom flight status feed would need a data partnership.

**Alternative: Herodotus storage proofs**
- [Herodotus](https://herodotus.dev/) enables cross-chain storage proofs on StarkNet
- Could verify flight status data from an L1 oracle or another chain without trusting a single admin

**Implementation:**
1. Define a `FlightStatusOracle` interface the contract calls
2. `verify_and_pay_claim` reads oracle instead of trusting admin
3. Anyone can call `trigger_payout(policy_id)` — the contract verifies via oracle
4. Fully trustless, fully on-chain

### Phase 4 — Multi-Asset Pools & Cross-Chain (2027+)

```
  MULTI-CHAIN VISION
  ==================

  StarkNet                    Ethereum L1                 Other L2s
  +-----------------+         +-----------------+         +-----------+
  |  Palomito       |         |  Palomito       |         |  Palomito |
  |  Pool (USDC)    |<------->|  Pool (USDC)    |<------->|  Pool     |
  |                 |  Bridge  |                 |  Bridge  |           |
  |  + STRK pool    |         |  + ETH pool     |         |           |
  |  + ETH pool     |         |                 |         |           |
  +-----------------+         +-----------------+         +-----------+
         |
         v
  Accept premiums in STRK, ETH, or USDC
  Payouts always in USDC (via Ekubo/Avnu swap)
```

**Concepts:**
- Accept premiums in any token (auto-swap to USDC via Avnu/Ekubo aggregators)
- Multi-asset pool backing (USDC + STRK + ETH)
- Cross-chain pools via StarkNet bridging for unified liquidity
- Expand beyond flights: train delays, event cancellations, weather parametric insurance

---

## Profitability Model

| Parameter | Current Value | Notes |
|---|---|---|
| Premium rate | 5% (500 bps) | Hardcoded as `PREMIUM_BPS` |
| Payout | 100% of ticket price | `coverage_amount = ticket_price` |
| Payout ratio | 20:1 | Each $1 premium covers $20 payout |
| Break-even claim rate | 5% | If >5% of policies pay out, pool loses money |
| Expected claim rate | ~1-2% | Cancellations only (delays excluded) |
| Expected profit margin | ~3-4% | On premium volume |
| Max ticket price | $5,000 USDC | Limits tail risk per policy |

---

## License

MIT
