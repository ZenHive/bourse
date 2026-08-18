# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Bourse.Position` gained `notional_currency` — the currency `notional` is
  denominated in, populated on the unified read path whenever `notional` is
  present. An unresolved currency fails loud rather than emitting an
  unlabelled number.
- `Bourse.Trade` gained `client_order_id` — the client-assigned order ID
  echoed on a fill when the venue returns one.
- alpaca `fetch_trades` and `fetch_my_trades` now dispatch. Public stock
  prints come from `GET /v2/stocks/{symbol}/trades` on `data.alpaca.markets`
  (IEX feed, 60-day lookback; a present-null `trades` key is an empty
  window). Paper fills come from `GET /v2/account/activities/FILL`. Wallet
  deposits, withdrawals, and transfers stay unsupported: the paper host
  404s those endpoints, and paper `JNLC` funding is not a customer
  transfer.

### Fixed

- binance (USD-M umbrella), bybit linear and derive perpetual markets now
  populate `contract_size` from the venue's own contract unit (`1`,
  `quantity_unit: "base"`), closing the last known linear gaps. Each recipe was
  confronted against the provider's contract, not copied from binanceusdm: a
  provider-published `contractSize` still wins, inverse COIN-M and bybit
  inverse keep reading the venue's field, and venues that state no unit
  (okx, binancecoinm) stay nil.
- binanceusdm unified `watch_ticker` delivers ticker frames. Binance's
  USD-M socket splits its streams across two hosts: `@miniTicker`, `@ticker`
  and `@aggTrade` are carried on `/market/ws` and merely acknowledged — then
  silent — on the public host, while `@depth20@100ms`, `@trade` and
  `@bookTicker` live on `/public/ws`. Both hosts are now authored and
  `watch_*` routes each stream to the one that carries it.
- WebSocket connections opened for an authored host switch are owned and
  reused. Repeated watches for streams on the same host share one socket
  instead of opening a new one per subscription, the `connect/3` options
  (message handler, heartbeat, `on_disconnect`, timeout) carry over to every
  routed connection, and `Bourse.WS.close/1` closes all of them — a caller
  never reaches into the handle's internals to clean up. Raw
  `Bourse.WS.subscribe/3` and `WS.Adapter.subscribe/3` route by authored host
  as well: a stream sent on a connection whose host does not carry it now
  either reaches the host that does or returns
  `{:stream_host_unavailable, url, reason}`, never an acknowledgement
  followed by silence.
- Mixed-host WebSocket subscriptions are atomic across authored hosts. If a
  later host fails, hosts that already accepted the call are unsubscribed
  before the error returns, so retrying does not stack a hidden subscription.
  Routed sockets are linked to their connection owner and cannot survive an
  owner crash as unreachable orphan connections.
- The unified boundary validates parameter value shapes before dispatch. A
  non-encodable value (keyword list, tuple, struct) returns
  `{:error, %Bourse.Error{type: :invalid_parameters}}` naming the parameter
  instead of raising inside the signing layer. Nothing is coerced and no
  positional signature changed.
- Binance-family unified order reads now see the Algo book. `fetch_order`,
  `fetch_open_order`, `fetch_orders`, `fetch_closed_orders`, and
  `fetch_canceled_orders` fan out to the algo endpoints, so an identifier
  `cancel_order` accepts no longer makes `fetch_order` answer
  `:order_not_found`. A successful algo-cancel acknowledgement
  `{algoId, code: 200}` synthesizes unified `status: "canceled"`. Venue
  `STOP` / `STOP_MARKET` types stay `stop` / `stop_market` instead of
  collapsing to `"limit"`.
- Binance-family order reads preserve every authored conditional type instead
  of collapsing it to `market` or `limit`: `stop`, `stop_market`,
  `take_profit`, `take_profit_market`, and `trailing_stop_market` now
  round-trip through their native literals. Spot, futures, and options use
  separate provider enums, and an unknown type fails loudly instead of being
  silently downcased.
- Unified `clientOrderId` now round-trips on Deribit: it goes out as
  `label` and comes back on both `%Bourse.Order{}` and `%Bourse.Trade{}`.
  A caller-supplied native `label` wins; values longer than 64 characters
  raise `:invalid_parameters`. A venue may map a client identifier in both
  directions or in neither; one-way mapping fails a catalog invariant.

## [0.6.0] - 2026-08-18

### Changed

- **Breaking (deribit):** linear future `contracts` now divide base
  `size_currency` by the base `contract_size`. The 0.5.0 formula
  `|notional| / contract_size` is inverse-only: on a USDC-perp it mixed
  quote `size` with a base contract size and reported ~mark_price
  contracts. Inverse futures are unchanged. Quote `notional` still comes
  from `size` on both books.

### Fixed

- binanceusdm linear markets now populate `contract_size` from the authored
  venue-level contract unit (`1`, `quantity_unit: "base"`) instead of leaving
  it nil when `exchangeInfo` omits `contractSize`. A provider-published size
  still wins; a venue that states no unit stays nil rather than defaulting to
  one. Inverse COIN-M continues to read the venue's `contractSize` field.
- Signed private requests are re-signed before every Req retry. A
  transient 408 no longer replays a frozen timestamp, nonce, or deadline
  that the venue then rejects as a recv-window or nonce error. After
  retries are exhausted the caller sees the original 408, not a follow-on
  rejection. The already-signed `HTTP.signed_request/4` path is now
  single-attempt; Dispatch uses `signed_request/5`.
- Bybit `SETTLEMENT` ledger `amount` and `direction` source the venue's
  `funding` component instead of `change`. USDC-perp rows were mixing
  8-hour session P&L (`cashFlow`) into `funding_fee`; linear-USDT rows
  where `cashFlow` is 0 are unchanged. Wallet `before`/`after` still
  describe the combined settlement.
- Authored conditional request entries no longer overwrite or delete a
  caller-supplied native parameter. The conditional only supplies the
  default; a matching case (for example deribit `trailingAmount` →
  `trailing_stop`) still applies. Deribit `trigger: "index_price"` now
  reaches the venue instead of being stripped.
- Binance and binanceusdm unified `watch_*` channels author the provider's own
  stream names (`{symbol}@depth20@100ms`, `{symbol}@trade`,
  `{symbol}@miniTicker`) instead of CCXT message hashes such as
  `orderbook::{symbol}`. The venue acknowledged those hashes and then delivered
  nothing, so a subscription looked healthy and stayed silent; live tests now
  pin frame arrival, not the subscribe acknowledgement. binancecoinm authors no
  market-stream templates and fails loud with `:no_channel_templates` rather
  than subscribing to a name that cannot deliver. One residual is recorded in
  the venue carve register: on the authored USD-M `/ws` host,
  `watch_ticker`'s `@miniTicker` still acks without delivering.
- Deribit mutation-lifecycle compensation holds when a mutating call fails
  *after* the request left the process — a transport raise, a non-JSON 200, or
  a redaction failure. The attempted act is tracked from the moment the request
  is built, so compensation never reports that no call was needed; when the
  order id is unrecoverable it sweeps the run's session label via
  `private/cancel_by_label`. Lifecycle plans are rejected up front when a
  mutating step follows cleanup without its own authorized compensator.

## [0.5.0] - 2026-08-18

### Added

- Deribit current-REST mutation adjudication records reviewed safety and
  reachability decisions for every raw mutating operation. Its capture task
  executes only an approved, reversible buy/cancel lifecycle on testnet,
  redacts credential material, verifies cleanup and the final state, and feeds
  the registered observations into the reality oracle; unsafe, value-moving
  and persistent operations remain explicitly unverified in the production
  verification ledger.
- `Bourse.Position` gained `base_quantity` — the absolute position size in the
  base currency where the venue reports it natively (currently populated for
  deribit futures from `size_currency`; `nil` elsewhere).
- `Bourse.Error` gained a dedicated `:invalid_nonce` type: venue errors that
  resolve through the InvalidNonce class (nonce/timestamp drift, e.g. Binance
  `-1021` outside recvWindow) now carry `retry_class: :network` and
  `should_retry?/1` true, instead of being folded into the terminal
  `:authentication_error`/`:auth` bucket. Genuine credential rejection
  (`:authentication_error`, `:permission_denied`) stays non-retryable.
  `:invalid_nonce` never melts the circuit breaker: clock/nonce drift is a
  client-side condition, not venue downtime, so it cannot open the
  exchange-wide circuit.

### Changed

- **Breaking (lighter):** transfer history rows changed shape. `TransferEntry`
  `timestamp`/`datetime` are now read as milliseconds (previously mis-scaled
  1000× as seconds), `from_account`/`to_account` carry account-index strings
  (previously the route strings `"perps"`/`"spot"`, which moved into `info` as
  `from_route`/`to_route`), and `fee.currency` is pinned to `"USDC"` — the
  venue's signed payload names the field `usdc_fee`, so the fee is
  USDC-denominated regardless of the asset moved (previously derived from
  `asset_id`).
- **Breaking (lighter):** trade history rows changed shape. `Trade`
  `timestamp`/`datetime` are now milliseconds (previously mis-scaled 1000×),
  `side`/`taker_or_maker`/`order_id` are populated from the account's role in
  the fill (ask/bid account matching), `type` dropped to `nil` (the venue's
  `type: "trade"` is not an order type), and `fee` appears when the venue
  returns `maker_fee`/`taker_fee`. The fee VALUE is a raw pass-through with an
  unverified scale — the provider types it `int32` and no observed testnet
  fill carries the field; see `docs/prod-verification-ledger.md` (C-T546i)
  before trusting `fee.cost` on lighter.
- Lighter `Balance.free["USDC"]` is populated from the account-level
  `available_balance` (previously unmapped); `used` remains the per-asset
  `locked_balance`, which does not include cross-margin encumbrance — see the
  C-T546 register note on the two accounting layers.
- Time-window translation is now asserted against returned rows, not the
  absence of an error: `until` actually reaches the wire on binance-family,
  okx and deribit reads, and binance spot no longer drops `since` on its
  klines/trades reads (task 553's live returned-window matrix pins both
  boundaries per probed venue/method).
- Deribit `fetch_trades` honors `until`: the authored request now maps
  `until → end_timestamp` and an until-only call routes onto
  `get_last_trades_by_instrument_and_time` (previously `until` silently never
  reached the wire and the newest page came back; caught live by the promoted
  time-window probe, C-T553f).
- Emulated configuration reads no longer answer `{:ok, nil}` when the
  underlying plural has no row for the requested symbol:
  `fetch_trading_fee`, `fetch_leverage`, `fetch_margin_mode` and
  `fetch_market_leverage_tiers` now return
  `{:error, %Bourse.Error{type: :exchange_error}}` naming the symbol. Live
  blast radius today: `fetch_leverage` (binance, binancecoinm, binanceusdm)
  and `fetch_market_leverage_tiers` (binance); the other two handlers are
  defensive uniformity with no venue currently emulating them. `fetch_position`
  deliberately keeps `{:ok, nil}` — a missing row means the account is flat,
  which is a valid answer. Emulation errors also now carry the venue id string
  in `Bourse.Error.exchange` (previously a boot-dependent atom or `:unknown`).
- binancecoinm trading fees are singular-only: `fetch_trading_fee/2` wires the
  symbol-mandatory `GET /dapi/v1/commissionRate` (COIN-M has no all-symbols
  commission read), and `fetch_trading_fees/1` now refuses with
  `:not_supported` instead of surfacing the venue's raw `-1102` missing-symbol
  error. The venue-agnostic parse compensation that wrapped a lone
  `TradingFee` struct into a symbol-keyed map is retired.
- Ledger parsing is route-scoped: venues whose ledger endpoints carry
  different type vocabularies per route (OKX `account/bills` vs `asset/bills`,
  binance-family `income` vs the options `bill` endpoint) parse each response
  with the vocabulary of the endpoint that produced it. Binance options ledger
  entries no longer hard-fail (the venue documents `type` as a free string —
  it passes through). Generated `parse_ledger_entry/2` on routed venues
  requires `opts[:route]` and fails loudly on an unknown route rather than
  parsing with the wrong vocabulary.
- Ledger `type` carries one registered cross-venue taxonomy: sixteen unified
  values (`trade`, `fee`, `deposit`, `withdrawal`, `transfer`, `funding_fee`,
  `realized_pnl`, `liquidation`, `settlement`, `interest`, `rebate`,
  `commission`, `cashback`, `referral`, `conversion`, `bonus`) plus venue-faithful
  snake_case labels for events outside the registry. The same economic event
  now emits the same value on the remapped venues: OKX bill type `8` and
  binance-family `FUNDING_FEE` both emit `funding_fee`; `REALIZED_PNL` is
  `realized_pnl` instead of the flattened `trade`; `AUTO_EXCHANGE` is
  `conversion`. OKX account-bills labels are derived from the venue's own
  `account/subtypes` recording (mechanically re-derived in the suite, not
  asserted in prose). Bybit and hyperliquid are reconciled onto the same set:
  bybit `LIQUIDATION`/`SETTLEMENT`/`DELIVERY`/`INTEREST` and transfer events
  emit their registered classes, hyperliquid `withdraw`/`vaultWithdraw` emit
  `withdrawal` and `vaultDeposit` emits `deposit`, and the coverage suite
  rejects any venue-specific label whose raw event carries a registered class.
  Bybit `SETTLEMENT` emits `funding_fee` (the venue's transaction-log enum
  pins it as perpetual funding settlement), the `BONUS` family emits `bonus`,
  and `CURRENCY_BUY`/`CURRENCY_SELL`/`CONVERT` emit `conversion`; hyperliquid
  `rewardsClaim` emits the venue-faithful `rewards_claim` (the L1 schema
  defines it as builder/referrer fee claims, not a promotional credit).
- **Breaking (deribit):** positions carry one unit contract. Future `notional`
  is the venue's quote-USD `size` (it was previously sourced from the
  base-denominated `size_currency`), `base_quantity` carries the base size, and
  `contracts` is derived as `|notional| / contract_size` from loaded market
  metadata. Without `load_markets`, deribit future `contracts` and
  `contract_size` are now `nil` (previously `contracts` carried the raw quote
  `size`). Binance COIN-M `notional` remains coin-settled under a named carve
  exception.

  **Upgrade note — this one changes a number, not a shape.** A denomination
  change does not fail at a match site the way a row-shape change does: a
  consumer that reads `position.notional` for deribit futures keeps compiling
  and keeps running, and silently computes exposure in the other currency at
  the other magnitude. Re-check every `notional` consumer on a money path
  (exposure, risk, hedging, sizing), not just the ones that pattern-match the
  struct. If you build the exchange **without** calling `load_markets` — a
  common shape for a long-lived connection process that constructs once and
  reads positions on demand — then `contracts` and `contract_size` are `nil`
  on every position read on that path; attach markets at construction, or read
  `notional`/`base_quantity`, which do not depend on market metadata.

### Fixed

- Deribit trade `cost` on symbol-less reads (`fetch_my_trades` without a
  symbol) is payload-derived: inverse fills emit `amount / price` instead of
  `amount * price` (previously off by ~2.5e9x on BTC-PERPETUAL), options keep
  the base-coin `amount * price` identity, and the classifier consults loaded
  markets before degrading to instrument-id parsing. Unified endpoint
  identities now include every section plus the HTTP method and path, so
  same-path routes under different methods or sections no longer collide.
- Unified rate-like fields carry pinned units end-to-end: implied volatility
  and funding/margin rates are fractions, ticker/option `percentage` is
  percent points, and the unit invariant now grades emitted parser output
  against frozen venue bodies rather than authored declarations alone.

## [0.4.0] - 2026-08-12

### Added

- New venue: `coinbaseexchange` (api.exchange.coinbase.com), the client's first
  deliberately public-only venue — `fetch_ohlcv` and `fetch_ticker`, no auth
  path (`capabilities.has`: 2 supported, 111 explicitly unsupported). Unified
  symbols (`ETH/USD`) route to Coinbase's dash product ids; requests spanning
  more than 300 rows are paginated at 299 inclusive intervals per page and
  merged back into the venue's newest-first wire order. Live-recorded venue
  behavior is documented in the authored spec and carve register: the series is
  sparse (trade-less intervals are omitted) and the forming bucket appears once
  it contains a trade. A follow-up completed half-open candle windows, covered
  unaligned page tails, and relaxed the credential gate for public-only venues.
- `binancecoinm` grew the venue surface it previously declared unsupported:
  order history, leverage tiers, open interest, trading fees, ledger and ADL
  quantile reads.
- `lighter` now exposes balance and positions (previously absent despite the
  account response carrying both), plus liquidations, trades, transfers and
  withdrawal history recordings.
- Provider-operation reality capture: recorded-evidence manifests for provider
  operations, proven on Deribit public REST with a populated success, a
  `get_time` success and an invalid-parameter error fixture.

### Changed

- `lighter` deposit history (`fetchDeposits`) now requires a caller-supplied
  `l1_address` — the venue endpoint cannot infer the account. Callers that
  omitted it must pass it explicitly.

### Fixed

- `lighter` funding rates are scaled from the venue's percent representation to
  the unified fraction.
- Binance-family plural funding reads no longer stamp a fabricated 8h interval
  onto instruments that never fund; the default is gated on perpetuals.
- Bulk list reads return unified symbols instead of venue-native ones, so their
  rows join against other unified results.
- Binance futures capability declarations corrected: `binancecoinm`
  `setPositionMode`/`setLeverage` and `binanceusdm` `fetchLeverage` (via
  `symbolConfig`) are served and now declared.
- `binancecoinm` maps the self-trade-prevention status `EXPIRED_IN_MATCH` to
  `canceled`, per the venue's STP contract.
- `binanceusdm` leverage reads share the `fetch_margin_mode` vocabulary for
  `marginMode` via the enum map.
- String-keyed market rows are restricted to string ids, preserving the Task
  215 rejection semantics.

### Removed

- The trading-domain layer (`Bourse.OptionProposal`, `Bourse.OptionReadiness`,
  `Bourse.OptionSaga`, `Bourse.PortfolioRisk` and their submodules, tests and
  the domain-boundary guard) moved to its own repository,
  https://github.com/ZenHive/bourse_trading, which consumes this client's
  published Hex package. The package contents are unchanged — these modules
  were never in the tarball; the `@domain_prefixes` exclusion machinery in
  `mix.exs` went with them.

## [0.3.0] - 2026-08-10

### Security

- The Lighter signer's Go module pinned `go-ethereum` 1.15.6 and `gnark-crypto`
  0.14.0 through `lighter-go`, carrying six advisories (four p2p denial-of-service
  issues, an ECIES public-key validation gap in the RLPx handshake, and unchecked
  memory allocation during gnark-crypto vector deserialization). Both are now
  overridden to `go-ethereum` 1.17.0 and `gnark-crypto` 0.18.1. Signing is
  unchanged: an authenticated testnet call was verified against `zklighter` before
  and after the bump, and the parser/framing coverage gate still holds.

### Fixed

- The Lighter signer helper could not talk to the BEAM on Windows. Windows opens
  the standard streams in text mode, which rewrites `0x0A` on the way out and
  stops reading at `0x1A` — both corrupt the length-prefixed binary frames the
  Port protocol exchanges, so the helper exited and the next `Port.command/2`
  raised `:epipe`. The helper now puts `stdin`/`stdout` in binary mode before
  reading its first frame. The build itself was also broken on that platform:
  `:erlang.system_info(:system_architecture)` answers `"win32"` there — the OS,
  not the CPU — so `mix ccxt.build_lighter_signer` now resolves the Windows
  architecture from the environment instead.

- `Bourse.WS.connect(exchange, :private)` returned an open but unauthenticated
  socket on every venue. The auth patterns and the state machine that drives
  them both existed; nothing called them from the facade. Private subscriptions
  on such a connection are accepted by some venues and simply never deliver, so
  the failure surfaced as an empty stream rather than an error. A `:private`
  connection now completes the venue's handshake before it is returned, and a
  rejected handshake closes the socket and surfaces the venue's reason.
  Confirmed differentially against bybit, deribit and okx: each private
  subscribe is accepted on the authenticated connection and rejected on
  `authenticate: false`.
- Deribit's refusal of a subscribe is an empty `result` list, not an error
  object — an envelope otherwise identical to success, which `subscribe/3` read
  as acceptance. Observed on `test.deribit.com`: the same `user.portfolio.btc`
  subscribe returns `"result" => []` unauthenticated and the channel name back
  when authenticated.
- The listen-key pre-auth step in `Bourse.WS.Auth.ListenKey` raised `BadMapError` on the authored
  binance config, which carries its endpoints as a map where the module
  expected a list.
- The binance family had no working private WebSocket path at all, and both
  halves failed differently.

  `binanceusdm` needed a REST round-trip nothing performed. `connect/3` now
  issues the listen key before opening the socket and connects to the URL the
  key produces, and `Bourse.WS.Adapter` refreshes it on the venue's schedule.
  The endpoints it resolves are the generated raw endpoint names; the authored
  config previously named CCXT methods that match no function in this client,
  so resolution looked complete and could not be called. Confirmed against
  `demo-fstream.binance.com`: an order placed on the account produced
  `ORDER_TRADE_UPDATE` on the authenticated connection, and a syntactically
  valid but wrong key produced nothing while reporting `:connected` throughout
  — which is why `authenticate: false` is now refused for this pattern with
  `{:error, {:auth_not_optional, :listen_key}}` rather than returning a socket
  that cannot be authenticated later.

  `binance` spot was authored against an endpoint the venue has removed:
  Binance retired the spot and margin listen keys on 2026-02-20, and
  `POST /api/v3/userDataStream` answers HTTP 410 Gone. The private section is
  re-authored onto the venue's WebSocket API — host
  `ws-api.binance.com/ws-api/v3`, opened by a signed
  `userDataStream.subscribe.signature` request — under the new
  `:ws_api_signature` auth pattern. Confirmed against
  `ws-api.testnet.binance.vision`: with the request sent, an order produced
  `executionReport` and `outboundAccountPosition`; without it, the identical
  order produced nothing.
- `binancecoinm` had no WebSocket configuration at all, so `Bourse.WS.connect/3`
  answered `{:error, :unsupported_exchange}` for a venue that streams and issues
  listen keys like its USD-M sibling. Its authored slice now carries the
  delivery stream hosts and the `url_param` auth mechanism, and its listen key
  resolves from `dapiPrivate_*` rather than the linear endpoints — COIN-M and
  USD-M share one demo account and one key pair but are separate wallets with
  separate user data streams, so the other half's key connects and delivers
  nothing. Confirmed against `demo-dstream.binance.com`: an order placed and
  cancelled on the COIN-M wallet produced `ORDER_TRADE_UPDATE` for both
  transitions on the keyed socket, while a decoy key reported `:connected` and
  received nothing.
- `Bourse.WS.connect/3` forced `market_type: :spot` when resolving a listen key
  endpoint, so a venue that trades no spot resolved either an endpoint it does
  not serve or none at all. The market type now comes from the venue's own
  authored default unless the caller names one.
- Fifty-one declared unified reads resolved to no parser slot: their descriptor
  return tokens were plural collection names (`LeverageTiers`, `Liquidations`,
  `MarginModes`, `OpenInterests`, `IsolatedBorrowRates`) that the return-type
  table did not recognise, so the reads fell through and returned the provider's
  raw transport envelope inside `{:ok, …}`. The alias table now maps each plural
  token onto its singular parse type, the `last_price` parse type and
  `Bourse.LastPrice` are wired, `fetchLeverageTiers` is forced to a list return
  so a flat tier body is not collapsed into one all-nil record, and
  `fetchMarginModes` / `fetchOpenInterests` / `fetchIsolatedBorrowRates` re-key
  their row lists by symbol like `fetchTickers`.
- Parser aliases are now gated on registered venue recordings rather than
  declared blind. Binance leverage-tier brackets are flattened to per-symbol tier
  rows, Hyperliquid open interest is annotated from `metaAndAssetCtxs`, and reads
  that cannot be satisfied by a single provider response or verified against a
  sandbox — Deribit `fetchLiquidations` (settlement history, not liquidations),
  the Binance composite position / dust / isolated-borrow reads, and OKX single
  deposit/withdrawal lookups — are marked unsupported with carve records instead
  of silently mis-parsing.

- `Bourse.create_order/6` on the binance family submitted a requested stop as a
  naked market order. `time_in_force`, `reduce_only`, `trigger_price` and
  `stop_loss_price` are unified options the futures write path had no authored
  binding for, so they were dropped before signing — an order meant as a
  protective stop reached the venue with neither its trigger nor its reduce-only
  flag and executed immediately as an opening market sell. All four now reach the
  signed request, and a conditional order routes to Binance's Algo Order API
  (`POST /fapi/v1/algoOrder`) rather than the regular order endpoint, which
  rejects migrated stop types with `-4120`. Confirmed against
  `demo-fapi.binance.com`: an ETHUSDT stop-limit remained `NEW` carrying its
  requested trigger, `reduceOnly=true` and `GTC`; the request is pinned by an
  accepted-request golden and `-4120` on the retired route is pinned as a
  recorded exchange error.

- `take_profit_price` was accepted by `create_order/6` and then discarded on the
  same path, so a take-profit order was also sent as a naked market order. It now
  routes to the Algo book and resolves to the venue's `TAKE_PROFIT` /
  `TAKE_PROFIT_MARKET` types by the caller's order type. Binance's Algo contract
  accepts one conditional leg per order, so passing `stop_loss_price` and
  `take_profit_price` together is refused up front with
  `Bourse.Error` `:invalid_parameters` naming the two options — two-leg
  protection on this venue is the separate order-list surface, not an algo order.

- Binance USD-M conditional orders were write-only. Once placed on the Algo book
  they were invisible to every read and cancel path: `fetch_open_orders/2`
  returned only the regular book, `cancel_order/3` answered
  `:order_not_found` for a live algo order, and `cancel_all_orders/2` left the
  algo book resting. Authored order-book routes now span both books —
  `fetch_open_orders` merges the two responses, `cancel_all_orders` broadcasts to
  both, and `cancel_order` tries the regular book and falls through to the algo
  book on `:order_not_found` (and only on that error). The algo cancel sends
  `algoId` rather than `orderId`.

- `Bourse.cancel_all_orders/2` on binance USD-M used a route that cancelled
  nothing and then failed to parse the venue's acknowledgement. The call reached
  a spot-shaped endpoint, left resting FAPI orders untouched, and returned a
  parse error built from an all-nil order because Binance answers a bare
  `{"code": 200, "msg": "The operation of cancel all open order is done."}`
  envelope, not an order row. It now sends
  `DELETE /fapi/v1/allOpenOrders?symbol=…`, treats the `code=200` body as a
  success acknowledgement, and preserves `-1121` for an unknown symbol. Confirmed
  against `demo-fapi.binance.com`: three resting orders were cancelled and
  `fetch_open_orders/2` returned zero afterwards.

- `Bourse.set_margin_mode/3` never sent the symbol. On the generic binance client
  both the symbol and the margin mode were authored as unresolved identifier
  references, so every argument variant returned Binance `-1102` while the raw
  `POST /fapi/v1/marginType` succeeded with the same credentials. On the
  dedicated `binanceusdm` client the same shape was worse: the unified symbol was
  written into `marginType`, so the venue received `marginType=ETHUSDT`. The
  unified symbol now becomes `symbol=ETHUSDT` and `"cross"` / `"isolated"` map to
  the provider values `CROSSED` / `ISOLATED`. Verified live in both directions on
  USD-M and COIN-M demo, with the account restored to its original mode.

- `Bourse.fetch_balance(exchange, type: :swap)` on the generic binance client
  read the Spot Testnet wallet. Atom market types did not participate in endpoint
  selection at all, so `:swap` fell through to the spot route: futures keys got a
  401 invalid-key response from the spot host and spot keys returned the spot
  asset list — silently the wrong account. `fetch_swap_balance/2` was also
  unsupported, leaving no unified route to the USD-M wallet. `:spot` now reaches
  Spot, `:swap` reaches USD-M `fapi/v3/account`, `:delivery`/`:inverse` reach
  COIN-M `dapi/v1/account`, and `:linear` normalizes to `:swap`. All three
  succeeded live against their matching sandbox hosts; `:margin` is a named
  exclusion because Spot Testnet serves no SAPI host.

- An authored request parameter whose value was the boolean `false` was treated
  as absent and replaced by the authored default. The lookup that walks a
  parameter's source and its fallback sources stopped on the first *truthy*
  value, so `false` never survived to the wire. The visible case was
  `set_position_mode/2` on `binanceusdm`: asserting one-way mode lost
  `dualSidePosition=false` and failed `-1102` instead of reaching the venue.
  Presence is now decided by `nil`, so `false` is sent. Confirmed against
  `demo-fapi.binance.com`: re-asserting the live one-way mode now reaches
  Binance's business validation `-4059` with the boolean intact.

- `Bourse.fetch_funding_rate/2` left `interval` nil on all three binance venues.
  The funding-cadence carve had been confronted for bybit and hyperliquid and
  never for binance, so the current-rate read returned a `%Bourse.FundingRate{}`
  with no cadence at all — anything annualizing or summing funding had nothing to
  multiply by. The current premium-index row is now joined to the venue's own
  per-symbol funding-info list (`fundingIntervalHours`), falling back to Binance's
  documented eight-hour cadence only when the venue publishes no adjusted row for
  that symbol. OKX derives its cadence from the provider's own
  `nextFundingTime − fundingTime` pair instead of an authored constant. Live
  sandbox calls returned `interval: "8h"` on all four surfaces, against an
  observed pre-change `interval: nil`.

- The funding-interval join was wired to the USD-M list for every symbol and ran
  only on the singular read. On the generic binance client an inverse symbol
  looked its cadence up in the USD-M funding list, which does not carry it, and
  `fetch_funding_rates/2` — the plural read most consumers use — was never
  enriched at all and kept returning `interval: nil` for every row. Inverse and
  `future` market families now resolve `dapiPublic` for both the premium index
  and the funding-info list, and the plural read is enriched row by row. Verified
  live: 857 symbols enriched in one call — 443 at `4h`, 413 at `8h`, 1 at `1h`.
  The dedicated `binancecoinm` client serves the inverse read; on the generic
  client an inverse symbol still resolves to the venue's linear pair form, which
  the premium-index endpoint answers with an empty list — a known open defect.

- The funding-interval join silently returned the wrong answer when it could not
  identify the instrument. If no native symbol could be resolved from the parsed
  row or the caller's params, the lookup matched nothing and fell through to the
  eight-hour default, stamping a plausible cadence onto a row it had never
  matched. It now refuses with a `Bourse.Error` instead of joining nothing.

- `Bourse.fetch_funding_history/2` on binance returned
  `{:error, {:no_field_map, …}}` — the parse type was declared and wired with no
  authored field map behind it, so a declared read failed on a successful venue
  response. The USD-M income rows now parse into `%Bourse.FundingHistory{}` with
  `id`, `code`, `amount`, `timestamp` and normalized `symbol`, pinned against a
  registered live row (`tranId 1380186948815340520`, `-0.01286054 USDT`,
  `BTC/USDT:USDT`). The three remaining unparsed pairs — binance and OKX
  `fetch_margin_adjustment_history/2`, hyperliquid `fetch_funding_history/2` —
  stay explicitly unsupported rather than shipping a field map guessed from
  documentation: producing a row on those venues needs an isolated position and a
  margin mutation, or a position held across a funding boundary, so each is
  recorded in `docs/prod-verification-ledger.md` with the exact call that would
  close it.

- Unified endpoint selection ignored version priority and the private half of
  each venue family. The section preference lists were ordered so that
  `fapiPublic` outranked `fapiPublicV2`/`V3`, spot listed no private or `sapi`
  sections at all, and options listed no `eapiPrivate` — so a mapped method whose
  only route lived in a versioned or private section could not be reached by any
  documented parameter set. The lists are now ordered newest-version-first and
  carry the private sections, and ten previously unreachable binance-family
  methods gained authored selection rules: `fetchOpenOrder`, `fetchOrderTrades`,
  `fetchMyLiquidations`, `fetchConvertTrade`, `fetchConvertTradeHistory`,
  `fetchTradingFee`, `fetchOptionMarkets`, `fetchLeverages`,
  `fetchAccountPositions` and `fetchPositionsRisk`.

- `Bourse.fetch_leverages/2` on `binanceusdm` collapsed the venue's rows into a
  single all-nil record. The read shared the singular `fetchLeverage` parse
  branch, which unwraps one row, and the response was not recognized as a list
  body — so a per-symbol leverage read returned one row with no symbol on it.
  `fetchLeverages` now re-keys its rows by unified symbol like `fetchTickers`,
  `fetch_account_positions/2` and `fetch_positions_risk/2` are recognized as list
  bodies, and a leverage row whose symbol must be back-filled resolves against
  the loaded markets first, so a native id that exists in both the linear and
  inverse catalogs resolves to the one the answering endpoint actually serves.

- Lighter's private order reads demanded a symbol the venue documents as
  optional. `market_id` was authored as unconditional dynamic construction, so
  `fetch_open_orders/2` and `fetch_closed_orders/2` could not be called without
  one, although the provider's OpenAPI marks it optional on both
  `accountActiveOrders` and `accountInactiveOrders` and states that omitting it
  returns orders across all markets. A symbol-less call now omits `market_id`; a
  symbol-scoped call still resolves and sends the numeric market id. Confirmed
  against `testnet.zklighter.elliot.ai`: both endpoints answered 200 with
  `market_id` omitted and with market `0` supplied.

### Changed

- Lighter order statuses now normalize to the unified vocabulary. The authored
  slice declared `enum_passthrough`, so `%Bourse.Order{}.status` carried the
  venue's own strings verbatim — a consumer matching on `"canceled"` missed
  `"canceled-post-only"`, `"canceled-self-trade"`, `"canceled-reduce-only"` and
  nine further cancellation reasons, and `"filled"` never matched `"closed"`. All
  sixteen documented values are now enumerated: the twelve cancellation variants
  map to `canceled`, `filled` to `closed`, and `open` / `pending` / `in-progress`
  to `open`. The venue's own string remains available on `info`.

- An ambiguous multi-endpoint refusal now names the parameter sets that would
  resolve it. The error previously said only to author a default family or pass
  `type`/`subType`/`symbol`; it now probes the documented selection parameter sets
  against the method's own endpoints and reports the ones that work — or states
  that none does, which is a different and more actionable failure.

### Added

- `Bourse.WS.authenticate/2`, the handshake as a callable step, for connections
  opened with `authenticate: false` or credentials that expired mid-session. It
  returns the venue's session metadata (`%{ttl_ms: …}` where disclosed), which
  is what `Bourse.WS.Adapter` schedules re-auth from.
- `%Bourse.WS{}` carries an `:auth` field recording which pattern the venue
  accepted and what it disclosed about the session. A public connection and one
  that connected without a handshake both leave it `nil`.
- `Bourse.WS.ListenKey`, the listen key round-trip and its refresh, and
  `connect/3`'s `:pre_auth_opts` for the request options that belong to it —
  a timeout or a base URL override — rather than to the socket.

- `Bourse.OrderList` and three unified reads for it — `fetch_order_list/2`,
  `fetch_order_lists/2` and `fetch_open_order_lists/2`. Binance OCO groups have
  their own `orderListId`, client id, contingency type, lifecycle status and
  transaction time, and their `orders` entries are references rather than
  complete order rows — so they were invisible to the unified surface entirely:
  no read returned them, and they did not appear in `fetch_orders/2` or
  `fetch_open_orders/2` either. The new type is venue-neutral, because Binance
  also publishes OTO, OTOCO, OPO and OPOCO groups. Routing and the error contract
  are confirmed against `testnet.binance.vision`: `/api/v3/allOrderList` and
  `/api/v3/openOrderList` returned successful empty arrays, and `/api/v3/orderList`
  without an identifier returned `-1102` naming `origClientOrderId` and
  `orderListId`. The populated-row projection follows Binance's own contract; the
  test account carried no order group, so those rows are not reality-verified yet.

- Derive `fetch_transfers/2`, mapped to the venue's ERC-20 transfer history. The
  capability was authored `false` while the endpoint exists and is enabled:
  `tx_hash` becomes the transfer id, `asset`, `amount` and `timestamp` keep their
  provider values, and `is_outgoing` selects the source and destination
  subaccount. Confirmed against `api-demo.lyra.finance`: the authenticated call
  returned HTTP 200 for demo subaccount 144422, with an empty event list.

  Three sibling capabilities were confronted in the same pass and stay `false`
  deliberately, each with a recorded reason rather than an unexplained gap.
  `fetchLiquidations` — Derive's liquidation history describes portfolio auctions
  with no instrument, price, side or contract size, so it cannot produce a
  `%Bourse.Liquidation{}` without inventing them. `fetchBorrowInterest` — the
  interest history is a two-sided subaccount cash ledger with no borrowed
  currency, principal or rate. `fetchSettlementHistory` — the endpoint does serve
  settlement rows, but this client has no typed settlement-history return
  contract, and enabling the route would hand back a raw transport map.

## [0.2.0] - 2026-08-06

### Fixed

Findings from the 2026-08-04 live venue sweep, which compared this client against
CCXT JS endpoint by endpoint on the same testnets. Each was generalized to the
defect class rather than patched per venue.

- Unified reads returned raw venue envelopes, collapsed multi-row responses to a
  single row, or keyed results by un-normalized venue symbols. A whole-surface
  contract guard now holds every unified read to the same shape.
- `fetch_canceled_orders/2`, `fetch_closed_orders/2` and `fetch_orders/2`
  returned identical, unfiltered rows.
- Unified read parsing raised on legitimate venue responses instead of returning
  a typed error.
- Authored enum slices rejected real venue values; a single unmapped order status
  disabled four Hyperliquid read methods.
- Field maps were present but inert: populated venue fields arrived as `nil`, and
  one scalar parse dropped the year from a timestamp.
- Time-window request params (`since`, `limit`) did not reach the venue on every
  venue that accepts them.
- `Bourse.WS.subscribe/2` reported success when the venue rejected the
  subscription, and its return shape varied by venue.
- Funding cadence came from an authored constant rather than observed venue data
  — Deribit was recorded as 8h for an hourly venue, overstating funding roughly
  eightfold in anything that multiplied by it.

Reported by consumers against the published package:

- `Bourse.Testnet` exited the calling process when the registry was not running.
  Because the registry is deliberately not an application child, a consumer
  calling `register_all_from_env/1` from its own `test_helper.exs` lost its
  entire suite before a single test ran. Writes now return
  `{:error, :not_started}` and reads raise an `ArgumentError` naming
  `start_link/1`, instead of a `GenServer` exit and an opaque ETS badarg.
- Derive's ticker mapped `high`, `low`, `change` and `percentage` from a `stats`
  object the venue publishes on neither its demo nor its production host, and
  documents nowhere — an inherited carve whose only surviving evidence was a
  January 2025 sample. The four fields are recorded as absent, registered as
  carve `C-T560d`.

Packaging and attribution, found while auditing the extraction:

- The tarball shipped Bourse.Spec.Promotion and its two helpers — 1,049 lines
  of repo-internal tooling that reads deliberately unpackaged reality manifests,
  so in a consumer project it could only fail on missing files. `Path.wildcard/1`
  yields directory entries, Hex expands a listed directory recursively, and
  `lib/bourse/spec` matched no exclusion prefix. Directory entries are now
  dropped outright rather than excluded one prefix at a time, and the guard
  asserts against the *built* tarball, where the expansion is actually visible.
- The tarball also shipped the oracle / recording / replay / drift cluster, which
  reads `test/fixtures/**` and `priv/reference_cache/` — neither of them packaged.
  Two of those modules named `Req.Plug`, which exists only from req 0.7 and only
  behind the `only: [:dev, :test]` `:plug` dependency, so a consumer resolving
  `~> 0.6.1` compiled the package with undefined-module warnings. The cluster is
  now excluded from both the tarball and hexdocs, and a new gate scans every
  shipped module's AST for references to dependencies a consumer may not have.

### Changed

- `Bourse.Testnet` no longer starts as a child of `Bourse.Application`. It is a
  credential registry for sandbox testing and has no place in a consumer's
  always-on supervision tree; callers that want it start it explicitly.

### Added

- `Bourse.Testnet.started?/0`, so a caller can ask whether the registry is
  running rather than discover it from a failure.
- `NOTICE`, shipped in the package. The authored venue specs still carry method
  and return descriptions taken verbatim from CCXT, `docs.ccxt.com` links
  included; CCXT is MIT, whose terms require the copyright notice to travel with
  that text. No such notice was ever tracked, in this repository or its
  predecessor — publishing the package is what made the omission consequential.
- A CI workflow running the offline gate — format, warnings-as-errors, Credo,
  Doctor, Sobelow, the offline suite, the reality oracle, the documentation
  claims, `deps.audit` and Dialyzer. Until now those ran only on the maintainer's
  host and through dispatch review, so an outside pull request and a fresh clone
  had no gate at all.
- This repository. `bourse` is extracted from the working repo it grew up in,
  which stays behind as the private authoring workbench `bourse-workbench`.
  Carried over: the client (`Bourse.Exchange` / `Dispatch` / `HTTP` / `Signing` /
  `Symbol` / `Unified` / `WS` plus the unified response structs), the ten authored
  runtime specs, the verification layer (the ccxt.oracle_gate Mix task, the recorded
  response and accepted-request evidence, live drift checking), the spec-authoring
  and venue-promotion tooling, the authority corpus and its validators, and the
  trading domain layer.

  Left in the workbench: the complete version-pinned CCXT reference corpus (110
  documents), the classification tooling and corpus-wide audits that can only be
  answered against it, and the task roadmap with its CHANGELOG gate. This
  repository carries a 15-document reference slice covering the supported venues,
  which its own offline tests read; both manifests pin the same upstream revision,
  so the two copies are checkable rather than silently divergent.

## [0.1.0] - 2026-08-03

First hex.pm release as `bourse`, succeeding the retired `ccxt_client` package.
Published before this repository existed, from the tree that is now the private
`bourse-workbench` history — there is no `v0.1.0` tag here.

### Added

- Ten provider-authored venue integrations — `alpaca`, `binance`,
  `binancecoinm`, `binanceusdm`, `bybit`, `deribit`, `derive`, `hyperliquid`,
  `lighter`, `okx` — each generated at compile time from one complete owned JSON
  spec. Runtime support is a closed set: constructing any other exchange fails
  with `unsupported_exchange`.
- Two API surfaces. Raw per-exchange endpoint functions pass exchange responses
  through unchanged with signing, rate limiting, circuit breaking, and transport
  handled. The unified `Bourse` API adds cross-exchange methods returning
  normalized structs, with bang variants and machine-readable descriptions.
- Signing for every supported venue, including first-party signers for the three
  DEX venues: EIP-712 for Derive, msgpack action hashing for Hyperliquid, and a
  zk-Schnorr Port helper for Lighter. `Bourse.Signing` dispatches the authored
  recipes; no signing behavior is inferred at runtime.
- WebSocket support via `Bourse.WS` — a thin wrapper over `zen_websocket` driven
  by authored per-exchange subscription and auth patterns.
- Discovery and agent integration: `Bourse.describe/0-2` for method signatures,
  parameters, errors, and return shapes, plus `Bourse.MCP.tools/0` for MCP tool
  autodiscovery.
- Operational layers: per-credential weighted rate limiting with response-header
  feedback, per-exchange circuit breakers, telemetry events, and sandbox
  resolution for all ten venues via `Bourse.Exchange.new/2`.

### Changed

- Renamed from `ccxt_client` to `bourse`, with the `CCXT.*` namespace becoming
  `Bourse.*`. See the migration notes in the README.
- Interpretive judgment moved out of the runtime and into the authored specs.
  The heuristic signing classifier, symbol pattern inference, and long-tail
  fallback are removed; the runtime reads authored fields instead of guessing.
- Correctness is verified against recorded venue reality — registered response
  recordings, accepted-request goldens, and recorded exchange errors — rather
  than against third-party client behavior.

### Fixed

- Alpaca `fetch_ohlcv/3-4` had no working call shape: the default path returned
  an empty list, failing silently as success, and the documented `since` option
  produced an HTTP 400. The authored request slice now emits a real dated window.

### Packaging

- The published package carries the library and the ten authored specs. The
  repo-internal authoring and audit tooling is not shipped; `mix
  ccxt.build_lighter_signer`, the prerequisite for private Lighter calls, is the
  one task consumers receive.

[0.6.0]: https://hex.pm/packages/bourse/0.6.0
[0.5.0]: https://hex.pm/packages/bourse/0.5.0
[0.4.0]: https://hex.pm/packages/bourse/0.4.0
[0.3.0]: https://hex.pm/packages/bourse/0.3.0
[0.2.0]: https://hex.pm/packages/bourse/0.2.0
[0.1.0]: https://hex.pm/packages/bourse/0.1.0
