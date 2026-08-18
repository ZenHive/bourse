# Cross-venue carve register

Append-only schema confrontations that define a shared unified contract across venues. Follow the
allocation and evidence rules in `docs/authored-specs.md`; venue-local decisions belong in their
venue register.

**Canonical for cross-venue carves.** This file is the complete record for confrontations whose
scope spans venues; venue-specific decisions remain canonical in their owning registers.

## 2026-08-18 — client identifier round-trip (Task 622)

**C-T622a — A venue maps a client identifier in both directions or in neither
(task 622). Outcome: CONFIRM class invariant.** One-way mapping — unified
`clientOrderId` renamed onto a native request key without a matching order and
trade field-map return — fails
`test/bourse/client_order_id_round_trip_invariant_test.exs`. A surface whose
provider contract has no returnable client identifier carries a named exemption
citing that contract. Deribit's round-trip is C-T622; Binance family, Derive,
Hyperliquid, and Lighter trade rows are exempted from the fill echo because those
providers do not return the client identifier on fills.

<!-- carve-evidence-status
{"carve_id":"C-T622a","date":"2026-08-18","semantic_source":{"kind":"provider_owned","reference":"Per-venue provider contracts for client identifiers: Deribit label; Binance Account Trade List orderId-only fills; Hyperliquid userFills oid; Lighter ask_client_id/bid_client_id; Derive get_trade_history trade_id/order_id"},"observed_evidence":{"kind":"live_venue","reference":"Live test.deribit.com labelled market order plus matching private/get_user_trades_by_instrument fill on 2026-08-18; catalog invariant test/bourse/client_order_id_round_trip_invariant_test.exs"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-07-23 — Four-venue option identity and instrument-Greeks surface (Task 398)

**C-T398 — Coherent option discovery + instrument Greeks by canonical symbol (task 398).
Outcome: CONFIRMED across Deribit, OKX, Bybit, and Derive; reality tier 1 for live discovery
and delta sign/range; conventions are provider-owned authored metadata.**

`Bourse.Unified.OptionSurface` discovers active option markets and joins risk data by
**canonical unified symbol**. Each instrument carries native id, strike, expiry, settlement,
call/put type, optional bid/ask/IV/OI, plus distinct **source timestamp** (venue) and
**observed_at** (local wall clock). Incomplete candidates (combo/spread rows missing strike
or type) are rejected rather than emitted as partial records; ambiguous symbol matches and
stale data (`max_age_ms`) fail explicitly.

Per-instrument Greeks project authored `markets.greeks_conventions` so every populated Greek
names its native field, denomination, unit, bump size and time basis. Unsupported fields
(OKX/Bybit rho) stay `supported: false` with no fabricated value. Call deltas are asserted
in `[0, 1]` and put deltas in `[-1, 0]` against live native payloads without comparing
numeric Greek values across venues.

Venue-owned native-field choices: C-T398a (Deribit nested `greeks.*`), C-T398b (OKX `*BS`
family — continues C35), C-T398c (Bybit top-level Greeks), C-T398d (Derive nested
`option_pricing.*` through unified `fetchGreeks`).

<!-- carve-evidence-status
{"carve_id":"C-T398","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Provider-owned option/Greeks documentation cited in C-T398a through C-T398d"},"observed_evidence":{"kind":"live_venue","reference":"Tagged Deribit, OKX, Bybit, and Derive OptionSurface discovery + instrument_greeks live tests on 2026-07-23"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-07-23 — Canonical option quantity and reversible native conversion (Task 397)

**C-T397 — Unified option quantity is base-currency exposure (task 397). Outcome: CONFIRMED across
Deribit, OKX, Bybit, and Derive; reality tier 1.**

`Order.amount`, `filled`, and `remaining` use units of the option's base currency. An option
market names its venue wire field/unit and native increment. `contract_size` means base units
per one native contract; a contracts-based venue converts `native = base / contract_size` and
`base = native * contract_size`. Conversion is decimal-exact: the result must be a multiple of
the named native/canonical step or it returns `quantization_error`. Missing unit, step, or
multiplier semantics is an error, never an implicit multiplier of one.

The venue-owned evidence and live success/error pairs are registered as C-T397a (Deribit),
C-T397b (OKX), C-T397c (Bybit), and C-T397d (Derive). The tagged tests place only far,
maker-only orders and cancel them in the same lifecycle.

<!-- carve-evidence-status
{"carve_id":"C-T397","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Provider-owned option quantity and instrument documentation cited in C-T397a through C-T397d"},"observed_evidence":{"kind":"live_venue","reference":"Tagged Deribit, OKX, Bybit, and Derive success/error option lifecycles run against their test/demo APIs on 2026-07-23"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-07-22 — Currency `active` rollup is an authored per-venue decision (Task 482)

**C-T482 — No silent default for first-class currency `active` rollups (task 482).**
Outcome: CONFIRMED as an owned unified-contract carve.

`Bourse.ResponseParser` derives network-level and (when authored) currency-level `active` from
per-chain deposit/withdraw flags via `active_requires_both`:

- `true` → active only when **both** directions are enabled on that chain (currency-level:
  any chain that is fully active)
- `false` → active when **either** direction is enabled (currency-level: any chain with a
  usable funding direction)

**Option (b):** keep the deliberate venue split, but every first-class authored currency rule
that uses `currency_networks` or `currency_network_summary` with `field: "active"` **must**
declare `active_requires_both` as a boolean. Omission is only legal for the long-tail (which
inherits OR). `test/bourse/currency_active_rollup_test.exs` fails when a first-class map drops
the flag. Per-venue confrontations against provider-owned chain-status fields live in the
owning registers as C-T482a (binance), C-T482b (okx), C-T482c (bybit); C-T442a/b/f remain the
original per-network deliberate-divergence records and are not rewritten.

## 2026-07-19 — Authored venue default_family for multi-endpoint selection (Task 378)

**C-T378a — Venue-level `config.default_family` slot (task 378).** Outcome: CONFIRMED as an
owned schema carve (not a CCXT field-name import). Multi-endpoint unified methods called with no
family signal (no symbol, no `type`/`subType`) must not resolve by bare `hd(configs)` list
ordering. The fall-through family is **authored** on the venue under `config.default_family`
(`spot` | `linear` | `inverse` | `option` | `swap` | `future`), loaded onto
`%Bourse.Exchange{default_family: ...}` and honored by `Bourse.Unified` selection after
configured/authored `endpoint_selection` rules. First-class venues refuse unresolved multi-
endpoint selection with a named `bad_request` (loud) rather than silently picking element zero;
long-tail public-data-only specs keep the legacy positional default. Preferred path within a
family (e.g. `positionRisk` vs `leverageBracket`) remains per-method
`endpoints.request.endpoint_selection` — the same rules+default shape already used for
`fetchBalance` / `fetchTicker`. Venue-local `Bourse.Unified` clause maps (tasks 368/373
`@binanceusdm_preferred_paths`) are retired.

**C-T378b — No-arg-read audit set and bare-hd predicate (task 378).** Outcome: CONFIRMED.
The named method set is `Bourse.Unified.no_arg_read_methods/0`; the predicate
`Bourse.Unified.bare_hd_no_arg_pairs/0` counts first-class `{exchange, method}` multi-endpoint
pairs that still resolve by bare `hd(configs)` under empty params. Acceptance: the list is
empty. Fan-out / param-fan-out methods and pairs with authored selection or `default_family`
section pick are excluded; loud first-class failures are not bare-hd resolutions.

## 2026-07-18 — Unified write/action return boundary (Task 358)

**Decision:** Every unified write/action method returns either its CCXT-defined
unified struct, an already-parsed order-like result, or the decoded venue JSON
body. It never exposes the HTTP transport envelope (`status`, `headers`, and
`body`).

**Evidence:** OKX EEA demo `setLeverage` returns the code-0 venue body on
success and code `59102` when leverage exceeds the venue maximum. CCXT-JS is
the compatibility reference: `addMargin`/`reduceMargin` return
`MarginModification`, `closePosition` returns `Order`, and action methods
without a parsed CCXT return retain their venue body.

## Schema-level multi-venue (moved from authored-specs.md, task 466)

These entries define a shared unified contract. Venue-local evidence for a named party may also be mirrored under that venue's register without a second heading.

**C-T562 — Response-envelope clocks remain available to row field maps (task 562). Outcome: CONFIRMED.**

- Bybit's recorded `fetchTicker` response carries `body.time = 1781993749592`
  outside `body.result.list`; the ticker row carries no `time`. The authored
  ticker timestamp therefore reads from the response envelope.
- Hyperliquid's recorded `fetchBalance` response carries its clock at the
  response root. Its balance timestamp uses the same envelope-source vocabulary.
  The confrontation reads that mapping against the recorded envelope with `time`
  removed from the row, so a post-parse `body.time` backfill cannot mask a
  field-map miss.
- A recording verifies an envelope-sourced field only when replay binds the
  carried value into the unified result. Merely preserving the key in fixture
  bytes does not establish parser coverage.

<!-- carve-evidence-status
{"carve_id":"C-T562","date":"2026-08-18","semantic_source":{"kind":"provider_owned","reference":"Bybit official V5 Get Tickers and Hyperliquid clearinghouseState response contracts, indexed by priv/authority/bybit/manifest.json and priv/authority/hyperliquid/manifest.json"},"observed_evidence":{"kind":"live_venue","reference":"Live Bybit testnet fetchTicker returned timestamp 1787062804933 on 2026-08-18; registered Bybit fetch_ticker and Hyperliquid fetch_balance recordings pin both envelope placements","fixture":"test/fixtures/responses/bybit/fetch_ticker.json"},"compatibility_reference":null,"resolved_tier":1}
-->

**C36 — Ticker `vwap` is a price, never contract size. Outcome: DIVERGE from CCXT's blind `quoteVolume/baseVolume`.**

- *Exchange semantics (non-CCXT, OKX V5 market ticker docs + live mainnet 2026-07-17):*
  [Get ticker](https://www.okx.com/docs-v5/en/#order-book-trading-market-data-get-ticker)
  defines `vol24h` as "unit of contract … number of contracts" for derivatives and
  "quantity in base currency" for SPOT/MARGIN; `volCcy24h` as "unit of currency …
  number of base currency" for derivatives and quote quantity for SPOT/MARGIN.
  Instrument `ctVal` (Get instruments) is the face value of one contract
  (`0.01` BTC for `BTC-USDT-SWAP`, `100` USD for `BTC-USD-SWAP`).
- *Live evidence (public `www.okx.com`, 2026-07-17):*

  | surface | instId | last | vol24h | volCcy24h | `volCcy/vol24` | meaning |
  |---|---|---:|---:|---:|---:|---|
  | spot | BTC-USDT | 63418.3 | 4455.85 (BTC) | 2.86e8 (USDT) | **64222.7** | real VWAP ≈ last |
  | linear swap | BTC-USDT-SWAP | 63391.4 | 8305293.78 (contracts) | 83052.94 (BTC) | **0.01** | `ctVal`, not a price |
  | inverse swap | BTC-USD-SWAP | 63335 | 2696948 (contracts) | 4207.92 (BTC) | **0.00156** | not a price; true notional VWAP would need `vol24h * ctVal / volCcy24h` ≈ 64092 |

- *Cross-venue check (same day, same trap class — do not re-litigate per venue):*
  - **Bybit linear** `turnover24h/volume24h` ≈ last (quote/base — formula is a price).
  - **Bybit inverse** `turnover24h/volume24h` ≈ 1/price-scale; `volume/turnover` ≈ last — same blind divide is not a price.
  - **Deribit** publishes `stats.volume` + `volume_usd`; authored ticker leaves `vwap` null.
  - **Binance USDM** supplies venue-native `weightedAvgPrice` (not a volume ratio).
  - **Binance COIN-M** `volume` is contracts / `baseVolume` is base — ratio ≈ 1/last, same class.
- *CCXT's carve:* `safeTicker` sets `vwap = quoteVolume / baseVolume` whenever both
  exist. On OKX that is authored as `volCcy24h / vol24h`. Correct for SPOT; for
  linear SWAP it freezes `ctVal` (live + historical GitHub #12128 both show
  `vwap: 0.01` next to a ~$39k–$64k last). Tier-2 fixtures ratify the shared bug.
- *Our carve + rationale:* **`vwap` means a volume-weighted average price, or nil.**
  For OKX, compute `volCcy24h/vol24h` only when `instType ∈ {SPOT, MARGIN}`; on
  SWAP/FUTURES/OPTION leave `vwap` nil rather than emit contract size. Inverse
  could be reconstructed with `ctVal` but the ticker row alone does not carry it,
  and inventing a second formula mid-parse without market metadata is out of
  scope — nil is the honest portable value. The decision is **schema-level**
  (one register entry for all venues): never publish a non-price as `vwap`.
  Per-venue volume→base/quote field maps stay separate (out of this carve).
- *Compatibility cost:* intentional divergence from CCXT on OKX contract tickers
  (`vwap` nil vs CCXT's `ctVal`). Spot/margin parity retained. Consumers that
  need contract counts still have `base_volume`/`quote_volume`/`info`.
- *Implementation:* 279. *Evidence sources:* OKX V5 ticker + instruments field definitions
  (non-CCXT) and live mainnet rows above; offline stubs pin spot VWAP and
  linear/inverse nil. The offline authored-spec tests pin the carve.
- *Bybit outcome (CONFIRMED, task 315):* The [V5 Get Tickers
  documentation](https://bybit-exchange.github.io/docs/v5/market/tickers) makes
  `category` mandatory and defines the Linear/Inverse ticker's `turnover24h`
  and `volume24h` fields; Bybit's [turnover-versus-volume
  FAQ](https://bybit-exchange.github.io/docs/faq#what-is-the-difference-between-turnover-and-volume)
  defines turnover as the opposite currency to volume. Live public mainnet
  (`api.bybit.com`, 2026-07-17) confirms the units differ by category:

  | category | symbol | last | volume24h | turnover24h | blind `turnover/volume` | unified `vwap` |
  |---|---|---:|---:|---:|---:|---:|
  | linear | BTCUSDT | 63199.40 | 58938.7540 | 3778506601.2070 | **64109.03** | **64109.03** |
  | inverse | BTCUSD | 63135.30 | 223794756.0000 | 3493.1019 | **1.56085e-05** | **nil** |

  `volume24h` is the BTC quantity for linear BTCUSDT, so turnover/volume is a
  USDT price. For inverse BTCUSD it is USD contract quantity while turnover is
  BTC, producing an inverse-price scale rather than a price — C36 says nil.
  **Option is the same carve (CONFIRMED, task 329):** the ticker documentation
  defines `turnover24h` and `volume24h` for options, while Bybit's
  [turnover-versus-volume FAQ](https://bybit-exchange.github.io/docs/faq#what-is-the-difference-between-turnover-and-volume)
  establishes that turnover is denominated in the opposite currency to volume.
  Live public mainnet (`api.bybit.com`, 2026-07-17) recorded
  `BTC-17JUL26-64000-C-USDT` with `lastPrice=5`, `volume24h=294.69`, and
  `turnover24h=18825758.541`; the blind ratio is **63883.26**, approximately
  the BTC underlying price, not the option premium. Therefore `option`, like
  `inverse`, leaves `vwap` nil. The carve deliberately does not reconstruct
  another ratio: Bybit's field semantics do not establish it as a portable
  volume-weighted option-premium contract.
- *Bybit mechanism:* the raw V5 ticker row carries no category (unlike OKX's
  `instType`), but `category` rides the envelope at `result.category` and every
  Bybit read already annotates it onto its rows. So the same payload-gated
  `kind: "when"` shape OKX uses applies here, guarding on the annotated
  `category`. This is what makes the carve hold on `fetchTickers`, which sends
  no `symbol` and therefore has **no market context to discriminate on** — a
  request-context `market.inverse` rule alone leaves the plural path publishing
  `1.56e-05`. The nested `market.inverse` arm is kept as a second, independent
  signal for symbol-scoped reads. Both point at nil, so a missing signal can
  only cost a `vwap`, never publish a wrong one.
- *Bybit residual:* calling the generated `Bourse.Bybit.parse_ticker/1` directly on
  a raw inverse row still computes the ratio — that row carries neither category
  nor market context, so no signal exists to carve on. This is an information
  limit of the raw escape hatch, not the unified path; it is why the annotation
  (not the raw row) is the carve's anchor.
- *Bybit implementation:* 315, extended by 329. *Evidence sources:* Bybit V5 ticker field definitions +
  turnover/volume FAQ (non-CCXT, tier-1 semantic) and the live mainnet rows
  above; offline stubs pin linear VWAP and inverse/option nil on both the
  singular and plural read paths.

## Historical confrontations (moved from authored-specs.md, task 466)

**C29 — `add_margin` positional order. Outcome: ALIGNED-to-ccxt.**

- *CCXT's carve:* `addMargin(symbol, amount, params)`.
- *Exchange-flow confrontation:* margin adjustment is instrument-scoped before it is amount-scoped;
  the Bybit and OKX unified sweeps (2026-07-16) both exposed our reversed positional API.
- *Our carve + rationale:* `add_margin(exchange, symbol, amount, opts \\ [])`. The prior
  `(amount, symbol)` order was neither exchange-semantic nor compatible with the reference API.
- *Compatibility cost:* none; this removes an accidental incompatibility.

**C30 — `reduce_margin` positional order. Outcome: ALIGNED-to-ccxt.**

- *CCXT's carve:* `reduceMargin(symbol, amount, params)`.
- *Exchange-flow confrontation:* this is the inverse operation of add-margin and identifies the
  same margin instrument before supplying the adjustment amount.
- *Our carve + rationale:* `reduce_margin(exchange, symbol, amount, opts \\ [])`, matching the
  exchange flow and C29 rather than retaining a reversed local convention.
- *Compatibility cost:* none; this removes an accidental incompatibility.

**C-T309 — `set_margin` positional order. Outcome: ALIGNED-to-ccxt (task 309).**

- *CCXT's carve:* `setMargin(symbol, amount, params)`.
- *Exchange-flow confrontation:* setting absolute isolated margin is instrument-scoped before it
  is amount-scoped — the same flow as add/reduce margin on venues that expose all three (Bybit
  isolated position margin, OKX position-margin set). Task 259 aligned `add_margin` /
  `reduce_margin` (C29/C30) but left `set_margin` at `[:amount, :symbol]`, so a caller who
  mirrored the siblings would ship `amount="BTC/USDT:USDT"`, `symbol=1`. Client-side,
  `maybe_denormalize_symbol/2` no-ops on a non-binary symbol, so nothing failed before HTTP.
- *Our carve + rationale:* `set_margin(exchange, symbol, amount, opts \\ [])`. Align with CCXT
  and the C29/C30 siblings; extend `validate_venue_params` so an unresolvable symbol raises
  `Bourse.Symbol.Error` before any HTTP request (same pre-check as add/reduce).
- *Compatibility cost:* callers who already used the reversed local order must swap args; the
  prior order was an accidental leftover, not a deliberate divergence.

**C31 — `create_convert_trade` quote identifier. Outcome: ALIGNED-to-ccxt.**

- *CCXT's carve:* `createConvertTrade(id, fromCode, toCode, amount, params)`, where `id` is the
  quote returned by `fetchConvertQuote`.
- *Exchange-flow confrontation:* a conversion quote is an executable offer, not merely a pair and
  amount; the Bybit and OKX convert flows require that identifier to execute the quoted trade.
- *Our carve + rationale:* `create_convert_trade(exchange, id, from_code, to_code, amount, opts \\ [])`.
  Omitting `id` made an executable conversion unrepresentable.
- *Compatibility cost:* callers now supply the required quote identifier; without it the old API
  could not represent the exchange operation at all.

**C39 — `fetch_order_book` depth. Outcome: CONFIRMED-as-ours.**

- *CCXT's carve:* `fetchOrderBook(symbol, limit?, params)` accepts a numeric depth positionally.
- *Confrontation:* this client reserves the final positional slot for the uniform opts channel;
  its generated signature is `fetch_order_book(exchange, symbol, opts \\ [])`. A depth is a
  request option, not part of the portable order-book identity.
- *Our carve + rationale:* callers pass `limit: depth`. A bare depth is rejected as a typed
  `:bad_request` naming `fetch_order_book` and the expected opts shape.
- *Compatibility cost:* callers porting CCXT positional depth use a keyword option; this preserves
  one Elixir calling convention across exchange-specific request options.

**C37 — `fetch_positions_adl_rank` symbols. Outcome: CONFIRMED-as-ours.**

- *CCXT's carve:* `fetchPositionsADLRank(symbols?, params)` accepts a symbols list positionally.
- *Confrontation:* a multi-symbol filter is optional request selection, while the client exposes
  single-symbol ADL rank as `fetch_position_adl_rank(exchange, symbol, opts \\ [])`.
- *Our carve + rationale:* the plural method remains `fetch_positions_adl_rank(exchange, opts \\ [])`;
  callers pass `symbols: [...]`. A bare list returns a typed, method-specific `:bad_request`.
- *Compatibility cost:* a CCXT positional list becomes an explicit keyword filter, making it
  distinguishable from the single-symbol method at the call site.

**C38 — `fetch_orders_classic` symbol. Outcome: CONFIRMED-as-ours.**

- *CCXT's carve:* `fetchOrdersClassic(symbol?, since?, limit?, params)` accepts an optional symbol
  positionally.
- *Confrontation:* this client's no-required-parameter unified methods carry optional filters in
  opts, preserving a stable `(exchange, opts)` shape rather than adding optional positional slots.
- *Our carve + rationale:* `fetch_orders_classic(exchange, opts \\ [])` takes `symbol:`, `since:`,
  and `limit:` as opts. A bare symbol returns a typed, method-specific `:bad_request`.
- *Compatibility cost:* callers porting CCXT use `symbol: "BTC/USDT"`; optional filters stay named
  and cannot be confused with the opts channel.

**C1 — precision values need a discriminator; carry it per market, not per exchange class.
Outcome: CONFIRM CCXT's tick-size normalization · DIVERGE on where the discriminator lives.**

- *CCXT's carve:* an exchange-**class** constant `precisionMode` (TICK_SIZE for all first-class
  venues — `deribit.ts:486`, `bybit.ts:1088`, `hyperliquid.ts:221`, `binance.ts:1318`,
  `okx.ts:1100`); the `precision` map values are tick sizes, and a consumer must hold the
  exchange object to interpret them.
- *Exchange semantics (non-CCXT):* heterogeneous by nature — deribit `tick_size` "specifies
  minimal price change" (docs.deribit.com `get_instruments`): a step float; bybit
  `tickSize`/`qtyStep`: "the step to increase/reduce order price/quantity" (bybit v5
  instruments-info): step strings; hyperliquid `szDecimals`: "sizes are rounded to the
  szDecimals of that asset" (HL gitbook tick-and-lot-size): **decimal places**.
- *Our carve + rationale:* the authored spec already carries per-venue `precision.mode`
  (`"tick_size"`, consumed by `Bourse.Order.Sanity.precision_increment/3`) — surface it on
  `%Bourse.Market{}` as `precision_mode`, and make every field-map **honor the declared mode**.
  Live 2026-07-15: our HL parse emits the raw integer `%{"amount" => 5}` under a spec-declared
  `tick_size` mode — an internal contradiction (should be `1.0e-5`); registered
  our-reading-wrong. Per-market field beats CCXT's class constant: self-describing market data
  survives serialization boundaries (MCP consumers, dumps) without the exchange object.
- *Compatibility cost:* none on values (same tick-size floats CCXT emits once HL is normalized);
  the struct field is additive.
- *Implementation:* 170 (surface the field; deribit), 171 (bybit spot `basePrecision` member),
  209 (HL amount normalization).

**C4 — inverse-perp `cost`. Outcome: CONFIRM Bourse.**

- *CCXT's carve:* `cost = inverse ? amount/price : amount×price` (`deribit.ts:1552-1555`).
- *Exchange semantics (non-CCXT):* "For perpetual and inverse futures the amount is in USD
  units" (docs.deribit.com) → the settlement-currency cost of a reversed trade is
  `amount / price`. Reality and CCXT agree.
- *Our carve:* the same rule (`Bourse.ResponseParser` `"computed"` + `inverse_op`). The live
  $204M-cost defect (`docs/tier1-divergence-report.md` § 2) is our market parse leaving
  `inverse` nil — an implementation bug pinned by the tier-1 oracle, **not** a carve question.
- *Compatibility cost:* n/a. *Implementation of the flag fix:* 170.

**C5 — funding cadence/interval. Outcome: CONFIRM CCXT for bybit + hyperliquid · Deribit
superseded by C-T535a (DIVERGE from CCXT).**

- *CCXT's carve:* bybit — per-symbol `fundingInterval` minutes → `"Nh"` string
  (`bybit.ts:2788-2811`); hyperliquid — hardcoded `'1h'` (`hyperliquid.ts:1407`); deribit —
  hardcoded `'interval': '8h'` (`deribit.ts:3315`).
- *Exchange semantics (non-CCXT):* bybit's v5 ticker publishes a per-symbol whole-hour funding
  interval; live testnet carried `fundingIntervalHour: "8"`. Hyperliquid documents hourly
  funding. Deribit's funding-history contract explicitly publishes hourly rows and separately
  labels `interest_1h` and `interest_8h`; the 2026-08-04 registered testnet recording contains
  12 rows over 12 hours with every adjacent timestamp gap equal to 3,600,000 ms. Its scalar
  `get_funding_rate_value` accepts an arbitrary query window, so the request width is not the
  publication cadence.
- *Our carve + rationale:* bybit `FundingRate.interval` = per-symbol `"Nh"` from
  `fundingIntervalHour` / `fundingInterval` when present in the payload (CONFIRM CCXT's carve;
  GREEN on reality-bearing cassettes and live testnet — task 290). Offline static fixtures that
  omit the field correctly yield `nil` (CCXT's fixture `"8h"` is markets-cache contamination;
  response gate B3). HL `interval = "1h"` is an evidence-backed fallback. Deribit
  `interval = "1h"`; its history rows parse `interest_1h` into typed structs, and C-T535a binds
  the fallback to the registered timestamp-spacing evidence.
- *Compatibility cost:* Deribit deliberately differs from CCXT's `"8h"`, which describes the
  compatibility client's snapshot query window rather than the provider's hourly cadence.
- *Tier-1 oracle:* the provider-owned Deribit history documentation plus the manifest-registered
  testnet history recording cited by C-T535a.
- *Implementation:* 171 (bybit), 209/370 (HL), 535 (Deribit correction and shared invariant).

**C7 — position `contractSize` is market-derived, not payload-derived. Outcome: DIVERGE — nil at parse
(with Bybit linear exception, task 306 / C34).**

- *CCXT's carve:* `parsePosition` reads `position['contractSize']` (`deribit.ts:2734`) — absent in
  the payload — and base `safePosition` **backfills it from the loaded market object**
  (`base/Exchange.ts`, "if contractSize is undefined get from market"). The static fixture's
  `contractSize: 10` is the BTC-PERPETUAL *market's* value, not position data.
- *Exchange semantics (non-CCXT):* deribit's `private/get_positions` response carries no contract
  size; it is per-instrument market data (live testnet 2026-07-15: BTC-PERPETUAL `10.0`,
  ETH-PERPETUAL `1`, SOL_USDC spot `0.1` via `public/get_instrument`). **Bybit linear V5** is the
  exception: instruments and positions use unit contract size `1` for all linear symbols (live
  2026-07-17; not per-instrument market metadata).
- *Our carve + rationale:* `%Bourse.Position{}.contract_size` stays **nil** at parse for deribit /
  inverse / other market-derived venues — our parse is payload-scoped and holds no loaded-markets
  context. **Bybit linear** stamps `contractSize: "1"` during category annotation (C34) — a
  category-level venue constant, not a symbol regex. Inverse bybit stays nil (minOrderQty is
  market-derived).
- *Compatibility cost:* CCXT (with markets loaded) reports a number where we report nil on
  deribit/inverse; linear bybit now matches CCXT's `1`.
- *Implementation:* 170 (this task); 306 (bybit linear stamp).

**C21 — Canonical query space encoding: `%20`, not www-form `+`. Outcome: DIVERGE from Elixir
`URI.encode_query/1`; CONFIRM Huobi/HTX venue docs (and match CCXT `qs` as cross-check only).**

- *Prior bug:* `Bourse.Signing.encode_query_pairs/2` (and therefore plain `urlencode`,
  `urlencodeWithArrayRepeat`, and HmacRecipe's `urlencodeNested` branch) delegated to
  `URI.encode_query/1`, which encodes a space as `+` (`URI.encode_query(%{"a" => "x y"}) ==
  "a=x+y"`). That is `application/x-www-form-urlencoded` media-type encoding, not the
  percent-encoding venues document for signed query strings.
- *Exchange semantics (non-CCXT):* Huobi/HTX spot Authentication → Signature Method
  (https://huobiapi.github.io/docs/spot/v1/en/#authentication): *"Use UTF-8 encoding and URL
  encoded, the hex must be upper case. For example, The semicolon ':' should be encoded as
  '%3A', The space should be encoded as '%20'."* HTX/Huobi/Bittrade recipes use the shared
  `urlencode` encoder for the signed query component, so a space-bearing param would sign
  bytes the venue re-canonicalizes differently under a `+` encoder and surface as auth
  failure. Bybit V5 signs the raw query string as sent; Binance requires percent-encoding of
  non-ASCII/special characters before signing — neither documents `+` as the space form for
  the HMAC payload.
- *CCXT cross-check (not oracle):* CCXT JS `urlencode` is `qs.stringify`, which emits `%20`
  for spaces (verified locally), matching Huobi's rule — still not the grader.
- *Our carve + rationale:* default shared encoder uses `URI.encode/2` with
  `URI.char_unreserved?/1` so spaces become `%20` and hex stays uppercase. **No venue has been
  shown to require www-form `+` for the signed canonical query**; if one does, add an explicit
  per-venue/per-encoder carve (do not silently restore `URI.encode_query` globally).
  `rawencode` remains unencoded values (Bybit V5 header-signed query). Form body
  `Content-Type: application/x-www-form-urlencoded` still rides the same encoder for recipe
  placement — `%20` is accepted by form parsers and keeps the signed body byte-identical to
  the query encoder.
- *Compatibility cost:* deliberate vs Elixir stdlib www-form; aligned with Huobi docs and with
  CCXT JS `urlencode` on the space character.
- *Live evidence (2026-07-16, deribit testnet):* signed URL
  `/api/v2/private/cancel_by_label?label=task%20286%20pin` (no `+`); live
  `private_get_cancel_by_label` with `label: "task 286 pin"` returned HTTP 200 /
  `jsonrpc result: 0` (0 cancelled — nonsense label). Auth passed under `%20`; an
  encoding mismatch would surface as an authentication error, not a zero cancel count.
- *Implementation:* 286.

**C15 — GET array query encoding: empty-bracket keys (`ids[]=`), not CCXT bracket-index.
Outcome: DIVERGE from CCXT default `urlencode` (qs indices) AND from OpenAPI form/explode prose.**

- *Contested id:* `C15` was landed twice in parallel (task 240 here, task 257 for OKX). This entry
  keeps the bare id because the live citations of "C15" — task 271's array-dialect sweep body and
  `out_of_scope` — mean *this* Deribit-grounded array carve. The OKX sibling is **C15a**; a
  citation of "C15" that concerns OKX instrument-type keying means that entry, not this one.
- *CCXT's carve:* default `urlencode` → `qs.stringify` with bracket-index arrays
  (`ids[0]=a&ids[1]=b`) (`base/functions/encode.js`); Deribit's `sign()` uses that default
  (`deribit.js:sign` → `this.urlencode(params)`).
- *Exchange semantics (non-CCXT, live 2026-07-16 testnet):* Deribit OpenAPI marks array
  query params as `style: form, explode: true` (which *would* be `ids=a&ids=b`), but the
  live HTTP query parser disagrees:
  - `ids[0]=…` (CCXT) → `-32602 value required`
  - `ids=a&ids=b` / bare scalar / JSON-stringified array → `-32602 value must be a list`
  - `ids[]=a&ids[]=b` → **200** with `result: [{order_id, …}]` on
    `private/get_order_margin_by_ids`
  - `public/private subscribe` with any form that reaches the exchange → `10030
    must_be_websocket_request` (HTTP cannot subscribe; the win is no client-side crash)
  - POST full JSON-RPC body with a real JSON array also works — out of scope for GET
    encoding. Nested array-of-objects (`execute_block_trade` `trades`) is not safely
    representable as GET query pairs; we fail loud naming the param.
- *Our carve + rationale:* plain `Bourse.Signing.urlencode/1`, public `Bourse.HTTP` GET
  building, and HmacRecipe's plain `urlencode` branch expand scalar lists as empty-bracket
  keys (`ids%5B%5D=…`). Recipe venues that need bare-key repeat keep
  `urlencodeWithArrayRepeat` (`array_style: :repeat`). Nested list/map items raise
  `ArgumentError` naming the param — never `URI.encode_query`'s opaque list crash.
- *First-class sweep (live 2026-07-17):* Deribit's explicit `query_encoder: "urlencode"`
  keeps this carve. Binance spot testnet `GET /api/v3/ticker/price` accepts
  `symbols=["BTCUSDT","ETHUSDT"]` as a percent-encoded JSON array (200, two ticker rows)
  and rejects repeated bare `symbols` keys (400 / `-1101 Duplicate values for parameter
  'symbols'.`). Binance and Binance USDⓈ-M therefore use the explicit
  `urlencodeJsonArray` recipe encoder. OKX, Bybit, Hyperliquid, and Derive are N/A: their
  current first-class GET surfaces expose no array-valued query parameter.
- *Compatibility cost:* deliberate vs CCXT-JS default array dialect on GET; grounded in
  Deribit live results over OpenAPI prose. Signature bytes for scalar-array GETs now
  follow the empty-bracket string.
- *Implementation:* 240, 271.

**C28 — balance availability branches are per currency row. Outcome: CONFIRM venue semantics +
CCXT compatibility; express the branch in the keyed-collection descriptor.**

- *Exchange semantics:* OKX's per-currency `availEq` is "Available equity of currency" and is
  applicable only to Futures / Multi-currency margin / Portfolio margin modes — **not** Spot mode
  ([OKX Get balance](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-balance);
  account-mode field matrix on the same page: details `> availEq` empty for Spot). When `availEq`
  is absent or empty, `availBal` / `frozenBal` are the available and frozen cash balances. Bybit
  UNIFIED wallet rows document `availableToWithdraw` as **Deprecated for `accountType=UNIFIED`
  from 9 Jan 2025** and always return `""`
  ([Bybit Get Wallet Balance](https://bybit-exchange.github.io/docs/v5/account/wallet-balance));
  the legacy non-empty path is no longer produced on UTA. When availability keys are empty,
  `locked` + `totalPositionIM` + `totalOrderIM` account for used. Hyperliquid spot rows expose
  `total` and `hold`, so available balance is their difference.
- *CCXT carve:* `parseTradingBalance` and `parseBalance` select these values per row, then
  `safeBalance` fills exactly one missing member of `{free, used, total}`.
- *Our carve + rationale:* `when_keys_absent` keeps the condition at the keyed-collection row,
  not at the response branch. Empty strings are treated as absent (`Bourse.Safe`). OKX maps
  `frozenBal` only without a usable `availEq`; Bybit maps the used sum only without either
  availability key; otherwise reconciliation derives the missing member. Hyperliquid authors
  `total` and `hold`, letting the same three-way fill derive `free`.
- *Implementation:* 265 (descriptor + offline both-branch pins); 307 (tier-1 live branch
  confrontation).
- *Evidence sources (tier 1):* exchange API docs above as the non-CCXT semantic source + live demo rows
  (2026-07-17). Live branch selection:
  - **OKX EEA demo** (`sandbox: true`, `hostname: "my.okx.com"`, `acctLv=1` Spot mode): all 6
    `data[0].details[]` rows carried `availEq=""` and took the **availEq-absent** branch
    (`free` ← `availBal`, `used` ← `frozenBal` via `when_keys_absent`). Unified free/used/total
    matched. **Known gap:** the availEq-**present** branch (numeric `availEq` on Futures /
    multi-currency / portfolio rows) was not observed on this Spot-mode demo; offline authored
    rows still pin it.
  - **Bybit demo** (`base_url: "https://api-demo.bybit.com"`, UNIFIED wallet-balance): all 4
    coin rows carried `availableToWithdraw=""` and no usable `free`, and took the
    **availability-keys-absent** branch (`used` ← `locked+totalPositionIM+totalOrderIM`, free
    reconciled as total−used). **Known gap:** the availableToWithdraw-**present** branch is not
    observable on UTA UNIFIED after the 2025-01-09 deprecation (venue always returns `""`);
    offline authored rows still pin it.
  - Outcome: **CONFIRM** (no DIVERGE) — live rows match the authored branch selection. Offline
    stubs remain the coverage for the unobservable opposite branches; static fixtures are a
    tier-2 compatibility net only.

**C-T351 — DEX signing environment follows the effective exchange sandbox (task 351). Outcome: CONFIRMED for Hyperliquid; ALIGNED for Derive.**

- *Exchange semantics (live Hyperliquid testnet, 2026-07-18):* an L1 cancel signed
  with phantom-agent source `"a"` is interpreted as a different wallet and rejected
  before business validation; source `"b"` reaches the missing-order business
  response. The source is therefore part of the signed environment, not credential
  metadata.
- *Our carve + rationale:* dispatch injects the constructed exchange's sandbox state
  as the signer's `:testnet` context. Credentials retain `sandbox` only as the
  direct-signer fallback, so `Exchange.new(..., sandbox: true)` governs both the
  selected testnet host and the signature.
- *Derive confrontation:* Derive order signing already has distinct production and
  api-demo EIP-712 domain separators. Its order signer reads the same `:testnet`
  context first, so the dispatch context selects the api-demo separator whenever
  the exchange is sandboxed; the credential flag remains the compatible fallback.
- *Evidence sources:* the network-tagged fabricated Hyperliquid cancel uses credentials with
  `sandbox: false` and must reach the venue's missing-order envelope. Offline
  dispatch coverage pins the resulting testnet phantom signature; Derive coverage
  pins its sandbox-domain selection.
- *Implementation:* task 351.

## Evidence status records

<!-- carve-evidence-status
{"carve_id":"C7","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Deribit get_positions and get_instrument schemas cited in C7"},"observed_evidence":{"kind":"live_venue","reference":"Live instrument metadata established market-specific contract sizes; no independent position-response recording is registered for the missing field"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT backfills contractSize from loaded markets"},"resolved_tier":2,"known_gap_reason":"Observation establishes the market value but not an independently recorded position payload proving field absence"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T482","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":null,"resolved_tier":3,"known_gap_reason":"Internal unified-contract rule requiring first-class authored declaration of active_requires_both; per-venue chain-status confrontations are C-T482a/b/c"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T378a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T378a and its register context"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T378a and its register context"},"resolved_tier":2,"known_gap_reason":"Provider-owned semantics are recorded, but no independent live or recorded venue observation establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T378b","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":null,"resolved_tier":3,"known_gap_reason":"This internal authoring outcome records no provider-owned semantic source, independent venue observation, or CCXT compatibility evidence"}
-->

<!-- carve-evidence-status
{"carve_id":"C36","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C36 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C36 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C36 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C29","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C29 and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C30","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C30 and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T309","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T309 and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C31","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C31 and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C39","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C39 and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C37","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C37 and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C38","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C38 and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C1","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C1 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C1 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C1 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C4","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C4 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C4 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C4 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C5","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C5 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C5 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C5 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C21","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C21 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C21 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C21 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C15","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C15 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C15 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C15 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C28","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C28 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C28 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C28 and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T351","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T351 and its register context"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

## 2026-08-04 — unified time-window request boundary (Task 540)

**C-T540 — A documented unified `since` reaches a provider-native time field on every
first-class venue (task 540). Outcome: CONFIRM provider boundaries.**

- *Provider semantics:* the ten venue authority indexes document method-specific start-time
  fields; their spellings and encodings remain venue-owned.
- *Our carve:* authored request shapes rename or compute `since` before dispatch. Final request
  shaping removes nil top-level optionals, so an omitted value cannot become an empty query
  parameter.
- *Verification:* the ten-venue request-shape sweep pins one documented read per venue. Live
  accepted-request evidence pins Binance `fetchOrders` and Derive `fetchTrades`; the remaining
  venue mappings stay at provider-contract tier until separately recorded.

<!-- carve-evidence-status
{"carve_id":"C-T540","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"First-class venue authority manifests and method contracts cited by the venue-specific C-T540 entries"},"observed_evidence":{"kind":"recorded_venue","reference":"Binance fetchOrders and Derive fetchTrades accepted-request goldens captured 2026-08-04"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The cross-venue request-shape invariant is complete, but only Binance and Derive carry task-specific accepted-request recordings"}
-->

## 2026-08-12 — InvalidNonce is retryable, not auth (Task 604)

**C-T604 — Nonce/timestamp drift is a dedicated retryable error type (task 604).
Outcome: DIVERGE from the prior lossy collapse of InvalidNonce into
`:authentication_error`.**

- *Provider semantics:* Binance documents `-1021` INVALID_TIMESTAMP as client
  clock / `recvWindow` drift
  ([Spot errors.md](https://github.com/binance/binance-spot-api-docs/blob/master/errors.md):
  "Timestamp for this request is outside of the recvWindow" / "was 1000ms ahead
  of the server's time"). Authored venues map those codes through the
  `InvalidNonce` class; genuine signature/key failures stay
  `AuthenticationError` (e.g. Binance `-1022`).
- *Our carve:* `Bourse.Error` maps `"InvalidNonce"` → `:invalid_nonce` with
  `retry_class: :network` (`should_retry?/1` true). `:authentication_error` and
  `:permission_denied` remain `:auth` (terminal without intervention). Per-venue
  `errors.retry_classification` tables stay class-name-keyed and unchanged.
- *Verification:* classification unit tests pin both sides of the split; Binance
  `-1021`/`-1022` and Bybit/OKX InvalidNonce codes resolve through
  `Exchange.error_codes` + `HTTP.Errors.classify_response/5`.

<!-- carve-evidence-status
{"carve_id":"C-T604","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"https://github.com/binance/binance-spot-api-docs/blob/master/errors.md (-1021 INVALID_TIMESTAMP)"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"No manifest-registered live InvalidNonce recording; classification is pinned against authored codes (binance/binanceusdm/binancecoinm exact -1021 → InvalidNonce; bybit 10002; okx 50102/60006) and provider docs"}
-->

## 2026-08-12 — unified rate-unit contract (Task 600)

**C-T600a — Each unified rate-like field has one cross-venue unit (task 600). Outcome:
DIVERGE from venue-native units where a pass-through would make the unified contract
contradict itself.**

- Margin percentages and implied volatility are fractions (`0.1 = 10%` and `0.75 = 75%`).
- Funding, interest, maker/taker, and nested fee rates are fractions.
- Ticker change and position PnL `percentage` fields are percent points (`10 = 10%`).
- Fee `percentage` flags are booleans, not numeric rates.
- The manifest-wide guard derives venues from `runtime_support.json`, derives extras by their
  `unified_key`, and rejects a second unit for the same unified field.

<!-- carve-evidence-status
{"carve_id":"C-T600a","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Venue contracts cited by C-T600b through C-T600j"},"observed_evidence":{"kind":"recorded_venue","reference":"Manifest-registered venue responses and parser goldens cited by C-T600b through C-T600j"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Several carried null or unreachable slots have provider-contract evidence without a populated venue row"}
-->

## 2026-08-14 — unified position value axes (Task 610)

**C-T610 — Position `notional` preserves the provider value and carries its
currency in `notional_currency`. Outcome: DIVERGE from a single
contract-multiplication identity (task 610).**

`notional_currency` is populated whenever `notional` is populated. Consumers can
therefore reject or convert mixed currencies mechanically instead of consulting a
prose exception. Task 613 made that currency contract explicit and executable.
The frozen cross-venue invariant starts from raw venue payloads,
runs the read-parse annotation path, and grades each applicable arithmetic branch:

| Provider quantity basis | Arithmetic invariant | Venues/branches |
|---|---|---|
| Shares | `shares × current_price = notional` | Alpaca |
| Base-denominated contracts | `contracts × contract_size = base quantity`; where the payload carries mark, `base quantity × mark = notional` | Binance linear, Binance USD-M, Bybit linear, Deribit linear, Derive, Hyperliquid, Lighter, OKX linear |
| Quote-denominated contracts and quote notional | `contracts × contract_size = notional` | Deribit inverse futures |
| Quote-denominated contracts and settlement notional | `contracts × contract_size = notional × mark` | Binance COIN-M and inverse Bybit/OKX rows |

The emitted currencies follow the value source: Alpaca market value and OKX
`notionalUsd` are USD; ordinary linear values use the unified quote currency;
COIN-M and inverse Bybit/OKX values use the unified settlement currency. Deribit
future `size` is quote notional on both settlement branches. `base_quantity` is a
separate, deliberately narrow field populated only from Deribit future
`size_currency`; Deribit options and other venues leave it nil even when their
`contracts` quantity is base-denominated.

<!-- carve-evidence-status
{"carve_id":"C-T610","date":"2026-08-14","semantic_source":{"kind":"provider_owned","reference":"Venue position and instrument contracts cited by the venue-specific position carves"},"observed_evidence":{"kind":"provider_shaped","reference":"Raw provider-shaped rows passed through Bourse.Unified.ReadParse in test/bourse/position_unit_invariant_test.exs plus venue position recordings"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The arithmetic matrix has provider-contract or recorded evidence at its venue-specific tiers; no single live run can populate every venue position simultaneously"}
-->
