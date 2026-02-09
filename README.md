## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## SwapProject architecture (current)

- `Pool.sol` — AMM pool (LP token, liquidity add/remove, swap, internal reserve-based TWAP observations).
- `SwapExecutor.sol` — execution layer with chunked swap strategy and oracle-based risk checks.
- `SwapExecutor` now uses **Chainlink** as price source via:
  - `AggregatorV3Interface`
  - Chainlink TWAP calculation over recent rounds (`_chainlinkTwapX18`)
  - stale/invalid round protections (`ORACLE_STALE`, `ORACLE_BAD_PRICE`, `ORACLE_NO_DATA`, `ORACLE_INCOMPLETE_ROUND`)

## Chainlink TWAP execution guards

When calling `executeAutoChunkedSwap(...)` (or advanced `executeAutoChunkedSwapWithOracleParams(...)`), the executor validates:

1. **Deadline and token correctness**
2. **Spot vs oracle-TWAP deviation bound** (`PRICE_DEVIATION_TOO_HIGH`)
3. **Realized output vs oracle-TWAP expected output** (`TWAP_SLIPPAGE_TOO_HIGH`)
4. **Oracle freshness and round quality** before execution

This makes one-block manipulations (flash/sandwich style) significantly harder to exploit in execution decisions.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
