# SDOG tests

Run the Solidity suite offline with `forge build` and `forge test`. Fuzz properties
use Foundry's default 256 runs. The invariant is bounded to 64 sequences of 32 calls
with unexpected handler reverts treated as failures.

- `SDOGToken.t.sol`: the existing contributor's smoke tests, preserved unchanged.
- `SDOGBehavior.t.sol`: exact constructor allocation and mint event, lossless
  transfers, arbitrary recipients, event payloads, approval replacement/revocation,
  finite and unlimited spending, zero/maximum/self cases, all ERC-20 custom errors,
  rollback, absence of mint/burn/admin/upgrade entry points, and opcode checks.
- `SDOGInvariant.t.sol`: funded actors and an independent balance/allowance model;
  random transfers, approvals, revocations, delegated spends, and invalid attempts.
  Checks conservation and rollback after each call. After each sequence all holders
  must still be able to transfer their entire balances back to one holder.
- `SDOGPoolManager.t.sol`: the official v4 PoolManager runs locally at the specified
  mainnet address. Both token orderings use the economic opening price, a 90%
  single-sided seed, the 3000 LP fee, and tick spacing 60. Tests cover exact-input
  buys/sells, exact-output buys, fee accrual, exact settlement/take amounts, and
  atomic rollback for unpaid swaps and unfunded sellers. All SDOG originates in its
  constructor; no cheatcode writes token balances.

`python3 test/test_launch_manifest.py` additionally checks the exact manifest,
required build settings, and the compiled token ABI after `forge build`. This uses
only the Python 3.11+ standard library. These read-only checks are separate because
Foundry's unchanged filesystem permissions do not allow reading the root manifest
from a Solidity test.

The offline dependencies and their licenses/revisions are in `vendor/README.md`.
They are ordinary files; no package install, submodule, RPC, environment variable,
FFI, or configuration change is needed for the Solidity suite.

Integration limits: the paired currency is a local 18-decimal ERC-20 fixture, and
the launch/trader drivers reproduce the token movement and settlement calls. The
suite does not implement or test ProjectFactory authorization, Merkle proofs, or
the network's initialization guard. A mainnet fork run against live IMD and the
deployed factory/distributor remains outside this offline suite. The tests make
no claim about the live chain's current code or state.
