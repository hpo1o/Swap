# SwapProject — Production-Grade AMM on Testnet

Демонстрационный проект безопасного AMM-свапа на Solidity 0.8.20.  
Разработан как портфолио smart contract security engineer.

---

## Архитектура

```
src/
├── Pool.sol                  — AMM пул (constant product x*y=k)
├── SwapExecutor.sol          — Чанкованный свап с Oracle/TWAP защитой
├── libraries/
│   └── SwapMath.sol          — Формула AMM, sqrt, min
└── interfaces/
    └── AggregatorV3Interface.sol

test/
├── SwapTest.t.sol            — Unit + Invariant тесты
└── mocks/
    ├── ERC20Mock.sol
    ├── ERC20FotMock.sol      — Fee-on-transfer токен
    └── MockChainlinkFeed.sol
```

---

## Threat Model

### Что защищено

| Угроза | Механизм защиты |
|--------|----------------|
| Donation attack (первый депозит) | `MINIMUM_LIQUIDITY = 1000` заблокирован на `0xdead` |
| Потеря токенов при непропорциональном депозите | `_calcOptimalAmounts` принимает только пропорцию |
| Sandwich attack на чанки | `minAmountOut` на каждый чанк через TWAP |
| Манипуляция ценой оракула | Chainlink TWAP, проверка отклонения spot vs oracle ≤ 5% |
| Stale oracle | `maxOracleDelay = 1 hour`, ревертит при устаревших данных |
| Fee-on-transfer / rebasing токены | Проверка фактического баланса после `transferFrom` |
| Reentrancy | `nonReentrant` на всех state-changing функциях |
| Gas DoS (O(n) TWAP поиск) | Кольцевой буфер 720 слотов + бинарный поиск O(log n) |
| Gas DoS (бесконечные чанки) | `MAX_CHUNKS = 20` |
| Экстренная остановка | Guardian pause на Pool и SwapExecutor |
| TWAP манипуляция в одном блоке | Цена фиксируется до изменения резервов |
| Chainlink неверные временные окна | `startedAt` как граница раунда, не `updatedAt` |

### Что НЕ защищено (известные допущения)

- **Rebasing tokens** — токены с автоматическим изменением баланса (stETH, AMPL) не поддерживаются явно. FOT-проверка поймает часть случаев, но не все ребейзинг-сценарии.
- **Chainlink sequencer uptime** — нет проверки L2 Sequencer Uptime Feed. Для mainnet L2 (Arbitrum, Optimism) нужно добавить.
- **MEV / flashloan** — пул не защищает от flashloan-атак напрямую; это ответственность интегратора.
- **Oracle manipulation** — 5% порог отклонения spot/oracle настраиваем, но при низкой ликвидности пула манипуляция всё равно возможна.
- **uint32 timestamp** — `blockTimestampLast` переполнится в 2106 году. Для production использовать `uint40`.

---

## Параметры и лимиты

### Pool

| Параметр | Значение | Описание |
|----------|---------|----------|
| `FEE_BPS` | 30 (0.3%) | Комиссия пула |
| `MINIMUM_LIQUIDITY` | 1 000 | LP заблокированы навсегда |
| `OBS_CARDINALITY` | 720 | Слотов TWAP (~2ч при 10сек/блок) |
| `consult` min interval | 300 сек | Минимум 5 минут для TWAP |
| `getTwap` interval | 1 800 сек | 30 минут по умолчанию |

### SwapExecutor

| Параметр | Значение | Описание |
|----------|---------|----------|
| `EXECUTOR_FEE_BPS` | 10 (0.1%) | Комиссия executor'а |
| `MAX_CHUNKS` | 20 | Максимум чанков за одну транзакцию |
| `MIN_POOL_LIQUIDITY_THRESHOLD` | 1 000e18 | Минимальный резерв пула |
| `DEFAULT_MAX_PRICE_DEV_BPS` | 500 (5%) | Допустимое отклонение spot vs oracle |
| `DEFAULT_MAX_TWAP_SLIPPAGE_BPS` | 1 500 (15%) | Допустимое проскальзывание vs TWAP |
| `DEFAULT_MAX_ORACLE_DELAY` | 3 600 сек | Максимальный возраст данных оракула |
| `DEFAULT_ORACLE_TWAP_INTERVAL` | 300 сек | Интервал Chainlink TWAP |

---

## Events для Frontend/Backend интеграции

### Pool events

```solidity
// Своп выполнен — основной event для отображения трейдов
event Swap(
    address indexed sender,
    address indexed tokenIn,
    address indexed to,
    uint256 amountIn,
    uint256 amountOut,
    uint256 reserve0After,   // новые резервы для обновления UI
    uint256 reserve1After
);

// Ликвидность добавлена
event AddLiquidity(
    address indexed sender,
    uint256 amount0,
    uint256 amount1,
    uint256 liquidity,
    uint256 reserve0After,
    uint256 reserve1After,
    uint256 totalSupplyAfter  // для расчёта доли LP
);

// Ликвидность удалена
event RemoveLiquidity(
    address indexed sender,
    uint256 amount0,
    uint256 amount1,
    uint256 liquidity,
    uint256 reserve0After,
    uint256 reserve1After,
    uint256 totalSupplyAfter
);

// Пауза включена/выключена — для алертов мониторинга
event PauseToggled(address indexed guardian, bool paused);

// FOT-токен обнаружен — для диагностики
event FeeOnTransferDetected(address indexed token, uint256 expected, uint256 actual);
```

### SwapExecutor events

```solidity
// Полный снапшот свапа — для истории транзакций и аналитики
event SwapExecuted(
    address indexed sender,
    address indexed pool,
    address tokenIn,
    address tokenOut,
    address indexed to,
    uint256 totalAmountIn,
    uint256 totalAmountOut,  // уже без комиссии executor'а
    uint256 feeAmount,       // комиссия executor'а
    uint256 chunksUsed,      // для аналитики эффективности
    uint256 oraclePriceX18   // цена оракула в момент свапа
);

// Каждый чанк — для дебага и детальной аналитики
event ChunkExecuted(
    address indexed pool,
    uint256 chunkIndex,
    uint256 amountIn,
    uint256 amountOut,
    uint256 minAmountOut  // защитный минимум для этого чанка
);

// Проверка оракула — для мониторинга и алертов на отклонение цены
event OracleChecked(
    uint256 oraclePriceX18,
    uint256 spotPriceX18,
    uint256 deviationBps,    // текущее отклонение
    uint256 maxDeviationBps  // допустимый максимум
);
```

### Пример индексации (ethers.js)

```typescript
// Слушаем все свапы в пуле
pool.on('Swap', (sender, tokenIn, to, amountIn, amountOut, r0, r1) => {
  console.log(`Swap: ${amountIn} → ${amountOut}`);
  updateReserves(r0, r1); // обновляем UI без доп. RPC-запроса
});

// Мониторинг оракула — алерт при большом отклонении
executor.on('OracleChecked', (oraclePrice, spotPrice, deviationBps) => {
  if (deviationBps > 300n) {
    alertSlack(`Oracle deviation: ${deviationBps} bps`);
  }
});

// Мониторинг паузы
pool.on('PauseToggled', (guardian, isPaused) => {
  if (isPaused) alertSlack(`Pool PAUSED by ${guardian}`);
});
```

---

## Deploy Checklist

### Pre-deploy

- [ ] Запустить полный тест-сьют: `forge test -vvv`
- [ ] Запустить инвариантные тесты: `forge test --match-contract Invariant -vvv`
- [ ] Проверить отсутствие warnings: `forge build`
- [ ] Проверить gas-репорт: `forge test --gas-report`
- [ ] Убедиться что адреса токенов валидны и не являются proxy с upgrade риском
- [ ] Проверить что Chainlink feed активен и имеет достаточную историю раундов
- [ ] Определить адрес GUARDIAN (multisig рекомендован, не EOA)

### Deploy sequence

```bash
# 1. Деплой токенов (если testnet)
forge create src/test/mocks/ERC20Mock.sol:ERC20Mock \
  --constructor-args "TokenA" "TKA" 18 \
  --rpc-url $RPC_URL --private-key $PK

# 2. Деплой Pool
forge create src/Pool.sol:Pool \
  --constructor-args $TOKEN0 $TOKEN1 $GUARDIAN \
  --rpc-url $RPC_URL --private-key $PK

# 3. Деплой SwapExecutor
forge create src/SwapExecutor.sol:SwapExecutor \
  --constructor-args $FEE_RECIPIENT $CHAINLINK_FEED $GUARDIAN \
  --rpc-url $RPC_URL --private-key $PK

# 4. Первый депозит (минимум 1000 * MINIMUM_LIQUIDITY^2 в каждом токене)
cast send $POOL "addLiquidity(uint256,uint256,uint256,uint256,uint256,uint256)" \
  100000000000000000000000 \
  100000000000000000000000 \
  0 0 0 $(($(date +%s) + 300)) \
  --rpc-url $RPC_URL --private-key $PK
```

### Post-deploy verification

- [ ] Проверить `pool.GUARDIAN()` == ожидаемый адрес
- [ ] Проверить `pool.TOKEN0()` и `TOKEN1()` корректны
- [ ] Проверить `pool.paused()` == false
- [ ] Сделать тестовый малый своп и проверить event `Swap`
- [ ] Проверить `pool.getTwap()` возвращает разумное значение (нужно подождать 30 мин после первого депозита)
- [ ] Убедиться что `executor.CHAINLINK_FEED()` возвращает актуальные данные

### Мониторинг (рекомендуется)

- [ ] Настроить алерт на event `PauseToggled`
- [ ] Настроить алерт на event `FeeOnTransferDetected`
- [ ] Настроить алерт на `OracleChecked.deviationBps > 300`
- [ ] Мониторить `getReserves()` на аномальные изменения

---

## Запуск тестов

```bash
# все тесты
forge test -vvv

# только инвариантные
forge test --match-contract InvariantPoolTest -vvv

# только unit
forge test --match-contract PoolUnitTest -vvv

# с gas репортом
forge test --gas-report

# coverage
forge coverage
```

---

## Известные ограничения для аудитора

1. **Нет protocol fee** — вся комиссия идёт LP. Протокол берёт комиссию только в SwapExecutor (0.1%).
2. **Нет flash loans** — намеренно исключено для простоты.
3. **Один пул на пару** — нет фабрики, деплоится вручную.
4. **TWAP только 30 мин** — для production с высокой волатильностью может быть недостаточно.
5. **Guardian — не multisig** — в testnet это EOA. В production обязательно Gnosis Safe.
