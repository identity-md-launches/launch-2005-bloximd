# BloxIMD (BLOX)

A fixed-supply ERC-20 for a custom token launch on Ethereum (chain id 1).

| Property        | Value                                                  |
| --------------- | ------------------------------------------------------ |
| Solidity name   | `BloxToken` (`src/BloxToken.sol`)                      |
| `name()`        | `BloxIMD`                                              |
| `symbol()`      | `BLOX`                                                 |
| `decimals()`    | `18`                                                   |
| `totalSupply()` | `1000000000000000000000000000` (1,000,000,000 × 10^18) |
| Constructor     | no arguments                                           |

## Behaviour

- The constructor mints the whole supply once to `msg.sender` (the deployer; in the launch this is
  IMD's ProjectFactory, which then distributes it). Nothing can mint afterwards.
- Standard ERC-20 `transfer`, `approve`, `transferFrom`, `allowance`, `balanceOf`.
  An allowance of `type(uint256).max` is treated as infinite and not decreased.
- Every transfer moves exactly the amount it names: no fee, tax, burn or reflection, so the launch
  flows (factory → MerkleDistributor, distributor → claimants, the pool seed and swaps through the
  Uniswap v4 PoolManager) arrive whole without needing any exemption list.
- Failures revert with custom errors: `InsufficientBalance`, `InsufficientAllowance`,
  `InvalidReceiver` (transfer to the zero address), `InvalidSpender` (approve of the zero address).

## Trust assumptions and operational responsibilities

- No owner, admin, minter, pause, blacklist, freeze, upgrade or burn function exists. Once deployed
  the contract has no privileged role and needs no operator; nobody can move or freeze a holder's
  balance except the holder (or a spender they approved).
- No external calls, `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`; no libraries to link.
- Approval race: like every ERC-20, changing a non-zero allowance to another non-zero value can be
  front-run by the spender; holders should set it to 0 first if this matters.
- The supply split (10% swarm via the factory's MerkleDistributor, 80% pool seed, 10% to
  `0xff3e8d9ba776662ca6ed1420ee366afb436d2684`) is performed by the launch factory, not by this
  contract.

## Deployment parameters

- Compiler pinned in `foundry.toml`: solc `0.8.26`, optimizer on (200 runs), `bytecode_hash = "none"`.
- The token takes no constructor arguments. It is deployed by IMD's launch via
  `ProjectFactory.launchCustom`; no application contracts accompany it. This repository contains
  no deploy script and authorises no transactions.

## After launch

Nothing to configure: the contract has no settings and no owner.

## Development

```sh
forge build
forge test
forge fmt --check
```

Tests (`test/BloxToken.t.sol`) cover metadata, the one-time mint, the absence of admin entry
points, transfers, allowances, all revert paths, and fuzzed supply conservation. They use a tiny
local cheatcode interface (`test/utils/MiniTest.sol`) so the project has no external dependencies.

Passing tests are not a security audit.
