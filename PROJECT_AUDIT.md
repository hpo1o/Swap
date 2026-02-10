# Проектный аудит SwapProject

Дата: 2026-02-05

## Короткий итог
Проект уже имеет сильный фундамент: контракты разделены по ролям (Pool / SwapExecutor), есть unit-тесты, подключены OpenZeppelin SafeERC20 и простая LP-модель.

Однако в текущем виде есть критичные риски валидации входов, экономической логики и UX интеграции, из-за которых контракт нельзя считать production-ready.

## Что сделано хорошо
1. **Разделение ответственности**
   - `Pool` отвечает за AMM-логику и LP.
   - `SwapExecutor` изолирует стратегию чанкинга.

2. **Безопасная работа с ERC20**
   - Применяется `SafeERC20` при переводах.

3. **Базовая защита пользователя от проскальзывания**
   - В пуле есть `minAmountOut`, в executor — `minTotalOut`.

4. **Тестовый каркас уже есть**
   - Покрыты happy path и revert-сценарий по `TOTAL_SLIPPAGE`.

## Основные проблемы

### 1) Нет проверки валидности `tokenIn` в `Pool.swap`
Сейчас `zeroForOne` вычисляется как `tokenIn == token0`, и если передать любой другой адрес токена, логика пойдет как будто это `token1`-ветка. Это может привести к несогласованному состоянию резерва и ошибкам расчетов/переводов.

**Что добавить:**
- `require(tokenIn == address(token0) || tokenIn == address(token1), "INVALID_TOKEN_IN");`

### 2) В `SwapExecutor` комиссия отправляется пользователю, а не fee-recipient
Сейчас строка с комиссией переводит fee на `msg.sender`, то есть пользователю же, который и делает свап. Фактически комиссия не взимается.

**Что добавить:**
- отдельный адрес получателя комиссии (immutable `feeRecipient`) + возможность обновления через owner (или immutable в конструкторе).

### 3) Потеря остатка из-за округления в чанках
`amountPerChunk = totalAmountIn / chunks` и цикл на `chunks` итераций оставляют `remainder` неиспользованным, если деление нецелое.

**Что добавить:**
- на последней итерации использовать `amountThisChunk = totalAmountIn - spentSoFar`.

### 4) Отсутствие deadline-параметров
Без `deadline` транзакция может быть выполнена позже ожидаемого времени и с неактуальной ценой.

**Что добавить:**
- `require(block.timestamp <= deadline, "EXPIRED");` в swap/executor.

### 5) Нет reentrancy-защиты
Хотя используется `SafeERC20`, безопаснее закрыть внешние state-mutating функции (`swap`, `addLiquidity`, `removeLiquidity`, `executeAutoChunkedSwap`) модификатором `nonReentrant`.

### 6) TWAP реализован не как классический cumulative over full history
`getTWAP()` делит cumulative на `timeElapsed` с момента `blockTimestampLast`, что может давать экономически некорректную интерпретацию для внешних оракулов.

**Что улучшить:**
- хранить cumulative в стиле Uniswap (Q112/Q96), считать разность cumulative между двумя snapshots.

### 7) README пока шаблонный
README не описывает архитектуру проекта, безопасность, ограничения, сценарии запуска тестов и known issues.

## Логика, которая написана корректно
- Формула constant-product для расчета `amountOut` в пуле в целом корректная.
- Обновление резервов после swap сделано в правильном направлении для обеих веток.
- LP mint/burn на базе пропорции supply/reserves в целом соответствует базовой AMM-модели.

## Что можно убрать
- Лишние эмодзи и шумные комментарии в production-контрактах (для чистоты аудита и поддержки).
- Лишние/неиспользуемые утилиты, если дублируется расчет (часть логики есть в `SwapMath` и отдельно в `Pool`). Лучше унифицировать.

## Что добавить в ближайший спринт
1. **Negative tests / invariant tests**
   - invalid token input,
   - remainder handling в executor,
   - fee recipient behavior,
   - reentrancy checks,
   - reserve/product invariants.

2. **События**
   - `AddLiquidity`, `RemoveLiquidity`, `ExecutorSwap`.

3. **Архитектура доступа**
   - owner/roles для параметров комиссии и (при необходимости) pause.

4. **Сценарии edge-case токенов**
   - fee-on-transfer tokens,
   - non-standard ERC20 behavior.

## Приоритеты исправления
- **P0 (критично):** invalid `tokenIn` check, fee recipient bug, remainder bug.
- **P1:** deadline + reentrancy guard + больше тестов.
- **P2:** TWAP refinement + UX/docs + gas-оптимизация.

## Вердикт
Проект хорош как учебный/портфельный MVP, но перед деплоем в mainnet необходимо закрыть P0/P1 проблемы и расширить тестовое покрытие.
