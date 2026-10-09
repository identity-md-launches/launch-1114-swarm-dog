# Swarm dog (SDOG)

`src/SDOGToken.sol:SDOGToken` is a standalone ERC-20. Its constructor takes no
arguments and mints all **1,000,000,000 SDOG**, with **18 decimals**
(`1000000000000000000000000000` minor units), to `msg.sender` exactly once.
The name, symbol, decimals and total supply are constants. There is no owner,
admin, mint or burn entry point, pause, blacklist, proxy or upgrade mechanism.

Holders can transfer and approve spenders; `transferFrom` requires an allowance
even when called by the deployer. Transfers deliver the exact requested amount
without token fees, taxes or limits. Zero-value and self-transfers are supported.
Zero-address senders, recipients and spenders are rejected. Approvals replace the
previous allowance; maximum `uint256` approvals are unlimited and are not reduced
by spending. Standard `Transfer` and `Approval` events are emitted; spending an
allowance emits `Transfer` without an additional `Approval` event.

## Build and smoke tests

With Foundry and Solidity 0.8.26 installed, run from this directory:

```sh
forge build
forge test
forge fmt --check
```

The configuration pins Solidity 0.8.26, Cancun, optimizer enabled with 200 runs,
and `bytecode_hash = "none"`. There are no external Solidity dependencies,
submodules, installation steps, RPC requirements, environment-dependent tests,
FFI or filesystem permissions. All imports resolve to files in this project.

Six smoke tests cover constructor allocation, metadata, full-balance round-trip
transfers, zero and self-transfers, finite and unlimited approvals, and reverts
for insufficient allowance, insufficient balance and zero recipients. This
assignment does not include fuzz, invariant or live Uniswap integration tests.
The supplied protected harness is an external launch verification input, not
part of this project's smoke suite.

## Launch parameters and responsibilities

`launch.json` is the deployment manifest. The order selects **Ethereum mainnet**;
the manifest deliberately has no chain field. Deploy the token directly through
the launch factory with an empty constructor argument list. The factory must be
the constructor caller, since that caller receives the entire supply. No
application contracts are requested (`contracts` is empty).

| Parameter | Fixed value |
| --- | --- |
| Paired currency (IMD) | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| Uniswap v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Pool fee / tick spacing | `3000` (0.3%) / `60` |
| Pool allocation | `9000` bps of the whole supply (900,000,000 SDOG) |
| Opening market cap | `2500000000000000000000` paired-currency minor units (2500 IMD) |
| Remainder recipient | `0x000000000000000000000000000000000000dead` |
| Provenance initial price | `125270724187523965593206900` |

All addresses and economics above are supplied by the assignment. The remainder
recipient is the explicitly requested destination. These values do not create
token privileges or constructor dependencies.

The factory is responsible for forwarding 10% (100,000,000 SDOG) through its
Merkle distributor, seeding the single-sided pool from its remaining deployer
balance, and sending any remainder, including unused seed rounding residue, to
`remainderTo`. The 90% pool allocation plus the 10% swarm allocation uses the
whole nominal supply. The token neither withholds nor distributes either share.
The distributor handles claims; trades move SDOG to and from the PoolManager
using the same ERC-20 rules as every other account.

The manifest's initial price is the supplied provenance-only `sqrtPriceX96`
encoding of paired-currency minor units per SDOG minor unit assuming SDOG is
currency0. The launch deployer must derive the actual opening price from the
economics and the deployed currency ordering. Pool creation, liquidity accounting,
distribution, onchain deployment, and source verification remain the launch
operator's responsibilities. This project makes no external protocol calls and
requires no post-deployment token configuration. No transaction was broadcast.
