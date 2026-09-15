# Task 702 — authored public WebSocket channel confrontation

Provider documentation and live observations below were collected on 2026-09-15.
CONFIRMED means the authored template, after the existing channel/envelope
formatter, matched the provider contract and delivered real data. DIVERGE names
an authored mismatch; acceptance of a replacement without data is recorded as a
remaining verification gap. Acknowledgements alone do not prove delivery.

## Alpaca

| Method | Authored template | Provider counterpart | Outcome |
|---|---|---|---|
| `watchTrades` | `trades:{symbol}` | `trades` symbol array in an `action=subscribe` message | CONFIRMED |

The existing envelope adapter renders `trades:FAKEPACA` as
`{"action":"subscribe","trades":["FAKEPACA"]}`. Provider sources:
[streaming contract](https://docs.alpaca.markets/us/docs/streaming-market-data),
[stock trade messages](https://docs.alpaca.markets/us/docs/real-time-stock-pricing-data).
Live authentication used the existing environment credentials without recording
them. `wss://stream.data.alpaca.markets/v2/test` delivered:

```json
[{"T":"t","S":"FAKEPACA","i":1,"x":"N","p":134.56,"s":3,"c":[" "],"z":"A","t":"2026-09-15T11:01:53.291535755Z"}]
```

The provider also documents quotes and bars; no new watch methods are added.

## Coinbase Exchange

| Method | Authored template | Provider counterpart | Outcome |
|---|---|---|---|
| `watchTrades` | `{symbol}` | `product_ids` with the configured `matches` and `heartbeat` channels | CONFIRMED |

The symbol is a product identifier, not a channel name. The existing envelope
supplies the channels named in the provider's
[Exchange feed contract](https://docs.cdp.coinbase.com/exchange/websocket-feed/channels).
`wss://ws-feed.exchange.coinbase.com` received
`{"type":"subscribe","product_ids":["BTC-USD"],"channels":["matches","heartbeat"]}`.
It delivered a historical `last_match`, then this new trade (excerpt omits order IDs):

```json
{"type":"match","trade_id":1092969670,"side":"buy","size":"0.00000009","price":"77049.84","product_id":"BTC-USD","sequence":136118091158,"time":"2026-09-15T11:01:54.452213Z"}
```

It also delivered:

```json
{"type":"heartbeat","last_trade_id":1092969669,"product_id":"BTC-USD","sequence":136118091026,"time":"2026-09-15T11:01:54.000000Z"}
```

The provider also documents ticker and level2; no new watch methods are added.

## Bybit

Provider contracts: [ticker](https://bybit-exchange.github.io/docs/v5/websocket/public/ticker),
[trades](https://bybit-exchange.github.io/docs/v5/websocket/public/trade),
[orderbook](https://bybit-exchange.github.io/docs/v5/websocket/public/orderbook),
[kline](https://bybit-exchange.github.io/docs/v5/websocket/public/kline),
[liquidations](https://bybit-exchange.github.io/docs/v5/websocket/public/all-liquidation).

All ten authored public method/template occurrences are retained in this inventory:

| Method | Original template | Documented counterpart | Outcome and action |
|---|---|---|---|
| `watchLiquidations` | `liquidations::{symbol}` | `allLiquidation.{symbol}` | DIVERGE; replace; replacement delivery remains unproven |
| `watchOHLCVForSymbols` | `kline.{timeframe}.{symbol}` | `kline.{interval}.{symbol}` | CONFIRMED using interval `1`; retain |
| `watchOHLCVForSymbols` | `ohlcv::{symbol}::{timeframe}` | `kline.{interval}.{symbol}` | DIVERGE; remove invalid alternate |
| `watchOrderBookForSymbols` | `orderbook:{symbol}` | `orderbook.{depth}.{symbol}` | DIVERGE; replace with `orderbook.50.{symbol}` |
| `watchTicker` | `.{symbol}` | `tickers.{symbol}` | DIVERGE; remove invalid alternate |
| `watchTicker` | `ticker:{symbol}` | `tickers.{symbol}` | DIVERGE; remove invalid alternate |
| `watchTicker` | `tickers` | `tickers.{symbol}` | CONFIRMED; formatter appends symbol; retain |
| `watchTickers` | `tickers` | `tickers.{symbol}` | CONFIRMED; formatter appends symbol; retain |
| `watchTradesForSymbols` | `publicTrade.{symbol}` | `publicTrade.{symbol}` | CONFIRMED; retain |
| `watchTradesForSymbols` | `trade:{symbol}` | `publicTrade.{symbol}` | DIVERGE; remove invalid alternate |

No provider-owned counterpart was found for any of the six divergent strings
themselves; the counterpart column identifies the documented stream for that
method. Subscriptions were sent individually to
`wss://stream-testnet.bybit.com/v5/public/linear` with
`{"op":"subscribe","args":["<topic>"]}`. The existing formatter collapses
repeated separators and strips leading separators. These are the exact
`ret_msg` values in separate provider rejection frames:

| Original template | Rendered topic | Provider `ret_msg` |
|---|---|---|
| `liquidations::{symbol}` | `liquidations:BTCUSDT` | `error:handler not found,topic:liquidations:BTCUSDT` |
| `ohlcv::{symbol}::{timeframe}` | `ohlcv:BTCUSDT:1` | `error:handler not found,topic:ohlcv:BTCUSDT:1` |
| `orderbook:{symbol}` | `orderbook:BTCUSDT` | `error:handler not found,topic:orderbook:BTCUSDT` |
| `.{symbol}` | `BTCUSDT` | `error:handler not found,topic:BTCUSDT` |
| `ticker:{symbol}` | `ticker:BTCUSDT` | `error:handler not found,topic:ticker:BTCUSDT` |
| `trade:{symbol}` | `trade:BTCUSDT` | `error:handler not found,topic:trade:BTCUSDT` |

Each rejection had `success:false`, `req_id:""`, `op:"subscribe"`, and a
connection-specific `conn_id`. For example:

```json
{"success":false,"ret_msg":"error:handler not found,topic:liquidations:BTCUSDT","conn_id":"da7r0pitbetqa8diesh0-m4ao","req_id":"","op":"subscribe"}
```

Real testnet data evidence (selected provider fields; omitted fields are not inferred):

```json
{"topic":"tickers.BTCUSDT","type":"snapshot","ts":1789470111552,"data":{"symbol":"BTCUSDT","lastPrice":"77257.50"}}
{"topic":"kline.1.BTCUSDT","data":[{"start":1789470120000,"end":1789470179999,"interval":"1","open":"77257.2","close":"77256.8","high":"77257.2","low":"77256.8","volume":"0.015","turnover":"1158.8555","confirm":false,"timestamp":1789470134641}],"ts":1789470134641,"type":"snapshot"}
{"topic":"orderbook.50.BTCUSDT","type":"snapshot","ts":1789470134595,"data":{"s":"BTCUSDT","b":[["77256.80","0.007"]],"a":[["77257.10","0.013"]],"u":18760,"seq":9685122321}}
{"topic":"publicTrade.BTCUSDT","type":"snapshot","ts":1789470139409,"data":[{"T":1789470139371,"s":"BTCUSDT","S":"Sell","v":"0.003","p":"77256.70","L":"MinusTick","i":"0e5ae7e6-811a-5884-98c9-6cb3aede1505","BT":false,"RPI":false,"seq":9685122331}]}
```

The orderbook excerpt retains one level per side; the provider delivered 50.
The trades excerpt retains one of two received trades. Production
`wss://stream.bybit.com/v5/public/linear` independently delivered
`publicTrade.BTCUSDT` at `ts=1789470146235`, with price `77064.00`, size `0.029`.

### Accepted replacement without delivery

`allLiquidation.BTCUSDT` returned `success:true` on both hosts, then no data
within 65 seconds on testnet and 60 seconds on production. An additional
production observation of BTC/ETH/SOL yielded no usable data evidence. This
event-driven replacement is provider-documented and accepted, but remains
unproven for delivery. Keep it in `docs/prod-verification-ledger.md`; an
acknowledgement is not a pass. The regression test pins the old topic's rejection;
it does not turn idle liquidation acknowledgements into coverage.

### Separate private inventory

| Method | Authored template | Provider contract | Scope |
|---|---|---|---|
| `watchOrders` | `order` | [Private order](https://bybit-exchange.github.io/docs/v5/websocket/private/order): `order` | Private semantic channel; unchanged, no private handshake/data proof claimed |
| `watchMyTrades` | `:{symbol}` | [Private execution](https://bybit-exchange.github.io/docs/v5/websocket/private/execution): `execution` | No public counterpart; private correction remains outside this task |

The public host rejected raw `order` and `:BTCUSDT` with
`error:handler not found,topic:order` and `error:handler not found,topic::BTCUSDT`.
These public negative probes do not grade the private host's channel delivery.

### Reproduction

The audit used Node 26's built-in `WebSocket`, one subscription per tested topic,
and retained a real topic/data frame or an explicit provider rejection. No
recording or acknowledgement graded correctness. Durable live regression:

```sh
mix test.json test/live/ws/bybit_watch_frame_delivery_test.exs --include network --include integration --quiet
```

The test exercises default unified ticker/orderbook/trades channel selection,
requires real ticker prices, a nonempty uncrossed book and real trade price/size,
and asserts the former liquidation topic's provider error. The parent delivery
records the independent test execution and first-frame lane results.

## Derive

The complete four-row confrontation, actual rejection frames, slim ticker
notification and parse decision are in [C-T702](authored-spec-carves/derive.md#2026-09-15--public-ws-channel-confrontation-task-702).
Public denominator: `watchTicker` / `ticker.{symbol}.100` is DIVERGE (replaced
with `ticker_slim.{symbol}.100`, real data and parsed prices received);
`watchTrades` / `trades.{symbol}` is CONFIRMED by a production trade notification
(`trade_id: f69d1a1d-5c4f-4f7b-b66a-1234838364ee`, price `2485.2`, amount `0.1`,
timestamp `1789470739946`; full frame in the carve). Demo remains idle in
repeated 60-second waits and retains its ledger entry.
The two private `:{symbol}` entries are separately DIVERGE and explicitly
unresolved; no public counterparts or symbol-derived subaccount IDs are invented.

## Deribit

| Authored method | Template | Provider counterpart | Outcome |
|---|---|---|---|
| `watchBidsAsks` | `quote.{symbol}` | `quote.{instrument_name}` | CONFIRMED |
| `watchTicker` | `ticker.{symbol}.{timeframe}` | `ticker.{instrument_name}.{interval}` | CONFIRMED with `100ms` |
| `watchTickers` | `ticker.{symbol}.{timeframe}` | Same ticker subscription | CONFIRMED with `100ms` |

Provider sources: [quote](https://docs.deribit.com/subscriptions/market-data/quoteinstrument_name),
[ticker](https://docs.deribit.com/subscriptions/market-data/tickerinstrument_nameinterval).
Production `wss://www.deribit.com/ws/api/v2`, request
`{"jsonrpc":"2.0","id":1,"method":"public/subscribe","params":{"channels":["quote.BTC-PERPETUAL","ticker.BTC-PERPETUAL.100ms"]}}`
returned subscription data (excerpts):

```json
{"channel":"quote.BTC-PERPETUAL","data":{"timestamp":1789470160492,"instrument_name":"BTC-PERPETUAL","best_ask_price":77086.5,"best_bid_price":77086,"best_ask_amount":11590,"best_bid_amount":183260}}
{"channel":"ticker.BTC-PERPETUAL.100ms","data":{"timestamp":1789470160492,"instrument_name":"BTC-PERPETUAL","last_price":77086.5,"state":"open","mark_price":77088.23}}
```

Private `watchMyTrades: user.trades.any.any.{timeframe}` remains outside the
public denominator. No public orderbook template is authored here; provider book
channels are not added by this audit.

## Hyperliquid

All six public method/template occurrences, exact rejection frames and delivered
book/trade/candle evidence are recorded in [the Task 702 carve](authored-spec-carves/hyperliquid.md#2026-09-15--public-watch-channel-names-task-702).
`l2Book`, `trades`, `candle` are CONFIRMED provider types;
`orderbook:{symbol}`, `trade:{symbol}`, `candles:{timeframe}:{symbol}` are DIVERGE
and removed. Book/trade subscriptions now include `coin`. Candle requires an
explicit subscription object with `coin` and `interval`; there is no added unified
OHLCV method. Production candle delivered; idle demo candle remains ledgered.
Native coin IDs were tested. Resolving unified pairs to Hyperliquid coin IDs is a
separate existing limitation: `BTC/USDT` must not be represented as proof for `BTC`.
Private inventory: `watchOrders: orderUpdates`; `watchMyTrades: :{symbol}, userFills`.
These were not graded as public feeds.

## OKX

| Authored method | Template | Provider counterpart | Outcome |
|---|---|---|---|
| `watchBidsAsks` | `tickers` | `{"channel":"tickers","instId":"BTC-USDT"}` | CONFIRMED |
| `watchTicker` | `tickers` | Same ticker object | CONFIRMED |
| `watchTickers` | `tickers` | Same ticker object | CONFIRMED |
| `watchMarkPrice` | `mark-price` | `{"channel":"mark-price","instId":"BTC-USDT-SWAP"}` | CONFIRMED |
| `watchMarkPrices` | `mark-price` | Same mark-price object | CONFIRMED |
| `watchTradesForSymbols` | `trades` | `{"channel":"trades","instId":"BTC-USDT"}` | CONFIRMED |
| `watchOHLCV` | `candle{timeframe}` | `{"channel":"candle1m","instId":"BTC-USDT"}` on `/business` | CONFIRMED name; DIVERGE authored host |
| `watchOHLCVForSymbols` | `candle{timeframe}` | Same business-host candle object | CONFIRMED name; DIVERGE authored host |

Sources: [OKX API](https://www.okx.com/docs-v5/en/) and the provider's
[business-host migration notice](https://www.okx.com/de/help/changes-to-v5-api-websocket-subscription-parameter-and-url).
Production `/ws/v5/public` subscription data excerpts:

```json
{"arg":{"channel":"tickers","instId":"BTC-USDT"},"data":[{"last":"77116.6","bidPx":"77116.5","askPx":"77116.6","ts":"1789470161267"}]}
{"arg":{"channel":"trades","instId":"BTC-USDT"},"data":[{"tradeId":"1057206154","px":"77116.5","sz":"0.000011","side":"sell","ts":"1789470162718"}]}
{"arg":{"channel":"mark-price","instId":"BTC-USDT-SWAP"},"data":[{"markPx":"77086.9","ts":"1789470161241"}]}
```

Same `candle1m` request on `/public` rejected:

```json
{"event":"error","msg":"Subscribe failed, wrong URL or channel:candle1m,instId:BTC-USDT doesn't exist. Please use the correct URL, channel and parameters referring to API document.","code":"60018","connId":"25ebf8bb"}
```

On `/ws/v5/business` it delivered:

```json
{"arg":{"channel":"candle1m","instId":"BTC-USDT"},"data":[["1789470120000","77082.7","77116.6","77082.6","77116.6","1.57843610","121697.290334104","121697.290334104","0"]]}
```

The channel names are retained. Business-host routing needs a separate correction
and remains in the verification ledger; a direct provider frame is not a claim
that repository host routing works. Private inventory outside the public audit:
`watchMyTrades: ANY`, `watchOrders: ANY`, `watchPositions: ANY, positions`.
`ANY` is a local object-template sentinel, not itself a provider channel name.
OKX serves book channels but none is authored in this venue's watch template map;
no new watch methods are added.

## Denominator and limitations

31 public method/template occurrences were audited: Alpaca 1, Bybit 10,
Coinbase Exchange 1, Deribit 3, Derive 2, Hyperliquid 6, OKX 8. Identical channel
subscriptions shared by method aliases use the same delivered provider evidence;
method rows remain individually listed. Private entries in the common maps are
listed separately, including Derive's two explicitly requested rejected hashes.
No provider-name inference is taken from CCXT. Every absent public counterpart
and every accepted-but-idle channel remains visible above and in
[the verification ledger](prod-verification-ledger.md#task-702--public-ws-template-audit-delivery-gaps-2026-09-15).

## Verification performed

- `mix test.json test/bourse/ws/channels_test.exs test/bourse/ws/channels_fallback_test.exs test/bourse/ws/derive_ticker_test.exs test/bourse/ws/envelope_handler_mappings_test.exs test/bourse/ws/message_router_test.exs test/live/ws/bybit_watch_frame_delivery_test.exs test/live/ws/derive_watch_frame_delivery_test.exs test/live/ws/hyperliquid_watch_frame_delivery_test.exs --quiet --output /tmp/task-702-tests.json`
  — **69 passed, 0 failed**, including fresh provider data. This is implementer
  execution, not independent reviewer approval.
- Before changing runtime modules: `Bourse.WS.Envelope` coverage reached **100%**;
  `Bourse.WS.Channels` rose from **77.69% to 84.62%** with missing fallback/shape
  tests. After the channel change it measured **84.73%**.
- `mix bourse.verify_ws_first_frame --report artifacts/task-702-ws-before.json`
  — failed on Derive's deprecated ticker rejection and Binance COIN-M's absent
  template.
- `mix bourse.verify_ws_first_frame --report artifacts/task-702-ws-after.json`
  — Derive changed **failed → passed**, channel `ticker_slim.ETH-PERP.100`, first
  frame `acknowledgement`, subsequent `data_frame: data`. The provider notification
  shape and real prices are quoted in the Derive carve. No other venue changed
  status. The whole lane remains **failed**, solely because Binance COIN-M returns
  `:no_channel_templates`; that venue is explicitly outside Task 702.

Reports under `artifacts/` and `/tmp/` are execution output, not committed fixtures.
The reviewer remains the independent approval gate. Accepted-but-idle feeds and
OKX business-host routing are not represented as completed live proof.

The dispatch prechecks passed formatting, compilation with warnings as errors,
strict Credo, Doctor and Sobelow. Separate `bourse.authority_check`,
`bourse.error_authority`, `bourse.claude_check`, `bourse.agents_md --check`,
`ex_dna --max-clones 0` and `reach.check --arch --smells --strict --path lib`
also passed. Credo's complexity finding on the added coin wrapping was fixed by
extracting the coin-object helper; no rule was suppressed.

`mix check.dispatch` completed its full live test stage with **3,147 passed,
14 confirmed failures, 1 flaky result and 82 excluded dangerous tests** (3,244
total). One failure was a stale Bybit facade assertion expecting
`orderbook:BTCUSDT`; it was corrected to the observed `orderbook.50.BTCUSDT`.
The other 13 failures are on unchanged REST/account-state paths:

- Binance `fetchOrderList`: no account order-list ID available.
- Lighter: 10 account/history/signing reads rejected the configured account with
  `20013`, `invalid auth: couldnt find account` (promotion 1, signing 2,
  REST-read contract cases 7).
- OKX: option open-interest history and option trades returned no populated rows.

The flaky result was OKX `fetchStatus`, whose first request was rate-limited and
whose automatic retry passed. Those failures were not hidden, skipped or treated
as success. The full dispatch gate is **not green**. Later static alias stages
were also run separately, as listed above; the full suite was not repeated to
regrade unrelated provider failures.

Final targeted verification after the facade expectation and formatter helper fixes:

```sh
mix test.json test/bourse/ws test/bourse/ws_first_frame_test.exs test/live/ws/bybit_watch_frame_delivery_test.exs test/live/ws/derive_watch_frame_delivery_test.exs test/live/ws/hyperliquid_watch_frame_delivery_test.exs --quiet --output /tmp/task-702-ws-final.json
```

**411 passed, 0 failed, 0 excluded, 0 skipped.** This includes the complete WS unit
suite, first-frame classification tests and fresh provider-live delivery tests for
all three changed venues. `git diff --check` also passed.
