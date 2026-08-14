# Deribit carve register

Append-only schema confrontations for Deribit. Follow the allocation and evidence rules in
`docs/authored-specs.md`; this file records decisions and does not define doctrine.

**Canonical for this venue.** Historical narrative may still appear in `docs/authored-specs.md`;
this file is the complete Deribit carve record.

## 2026-08-14 — chart-data returned window (Task 553)

**C-T553e — Deribit chart data consumes unified bounds as `start_timestamp` and
`end_timestamp` (task 553). Outcome: CONFIRM provider contract.** The computed request shape
already derived the two native fields, but left the raw `until` alias beside them. The authored
omit list now consumes that alias. A live testnet probe asserts the parsed first and last candle
timestamps land at the requested bounds rather than accepting a merely successful response.

<!-- carve-evidence-status
{"carve_id":"C-T553e","date":"2026-08-14","semantic_source":{"kind":"provider_owned","reference":"Deribit public/get_tradingview_chart_data start_timestamp/end_timestamp contract"},"observed_evidence":{"kind":"live_venue","reference":"Live test.deribit.com fetchOHLCV returned-window assertion on 2026-08-14"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T565a — `fetchLiquidations` is not a liquidation surface on Deribit; the wired
endpoint returns settlement history (task 565). Outcome: DIVERGE; capabilities.has = false.**

- *Exchange semantics:* Deribit's
  [`public/get_last_settlements_by_instrument`](https://docs.deribit.com/api-reference/market-data/public-get_last_settlements_by_instrument)
  returns a `settlements` array of delivery/settlement records, not forced-liquidation
  events. The authored unified mapping pointed `fetchLiquidations` at that endpoint.
- *Live evidence (2026-08-08, testnet):* `fetchLiquidations("BTC-PERPETUAL")` answered
  `result.settlements` (empty list on the probe) inside a JSON-RPC envelope. No
  liquidation price, side, or quantity fields are present.
- *Our carve:* `capabilities.has.fetchLiquidations = false`. Declaring the method as a
  liquidation read would alias onto `%Bourse.Liquidation{}` and silently mis-parse
  settlement rows. Settlement history remains a net-new unified type owned by the
  sibling of task 565.

<!-- carve-evidence-status
{"carve_id":"C-T565a","date":"2026-08-08","semantic_source":{"kind":"provider_owned","reference":"Deribit public/get_last_settlements_by_instrument documentation"},"observed_evidence":{"kind":"live_venue","reference":"Deribit testnet fetchLiquidations BTC-PERPETUAL returned result.settlements 2026-08-08"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T535a — Deribit publishes hourly funding history; an eight-hour query window is not the
venue cadence (task 535). Outcome: DIVERGE from CCXT; reality tier 1.**

- *Exchange semantics:* Deribit's provider-owned
  [`public/get_funding_rate_history`](https://docs.deribit.com/api-reference/market-data/public-get_funding_rate_history)
  contract defines the response as hourly history and labels `interest_1h` and `interest_8h`
  separately. `public/get_funding_rate_value` accepts an arbitrary start/end window; that query
  width does not define the history publication cadence.
- *Live evidence (2026-08-04, testnet):* a 12-hour `BTC-PERPETUAL` request returned 12 rows.
  Every adjacent `timestamp` gap was exactly 3,600,000 ms, and every row carried both
  `interest_1h` and `interest_8h`. The response is frozen and manifest-registered at
  `test/fixtures/responses/deribit/fetch_funding_rate_history.json`; a same-day worktree probe
  reproduced the 3,600,000 ms spacing. Bybit's own testnet history provided the differing
  control: three `BTCUSDT` rows were spaced 28,800,000 ms and its ticker reported `8h`.
- *Our carve:* `FundingRate.interval` is `"1h"`, tied in the field rule to this carve and the
  registered history recording. `funding_rate_history` maps `interest_1h` and `timestamp` into
  `%Bourse.FundingRateHistory{}` rows. The scalar funding-rate call remains a value over its
  requested window; `interval` describes the venue cadence rather than that request width.
- *Shared invariant:* an authored funding interval may read a provider response field directly,
  or a literal fallback must name its carve, derivation, and provider evidence. A bare
  `{"default": "Nh"}` rule fails the catalog-wide test.

<!-- carve-evidence-status
{"carve_id":"C-T535a","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"Deribit public/get_funding_rate_history documentation"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/deribit/fetch_funding_rate_history.json: 12 rows, all adjacent gaps 3600000 ms, captured from test.deribit.com 2026-08-04"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT deribit fetchFundingRate labels its eight-hour query-window result with interval 8h"},"resolved_tier":1}
-->

**C-T511a — Deribit `order_state` is a closed seven-value provider enum, including queued
speed-bump states (task 511). Outcome: CONFIRM venue; reality tier 1.**

- *Exchange semantics:* Deribit's
  [`private/get_order_state`](https://docs.deribit.com/api-reference/trading/private-get_order_state)
  contract names exactly `open`, `filled`, `rejected`, `cancelled`, `untriggered`,
  `triggered`, and `speed_bumped`. Its
  [speed-bump lifecycle](https://docs.deribit.com/starbase/speed-bumps) acknowledges an order
  before release to the matching engine, so `speed_bumped` is live and non-terminal.
- *Our carve:* `open`, `untriggered`, `triggered`, and `speed_bumped` map to unified `open`;
  `filled` maps to terminal `closed`; `cancelled` maps to terminal `canceled`; and `rejected`
  maps to terminal `rejected`. All seven outcomes are **CONFIRMED** against the provider
  contract. No CCXT-derived state is added, and no provider state is omitted.
- *Live evidence (2026-07-24, testnet):* a marketable option sell returned synchronous
  `order_state=speed_bumped` with an empty `trades` array, then order history showed the fill
  at its limit about 1–2 seconds later. Its close buy behaved the same way. A cancel racing
  release returned provider error `11044 not_open_order`. The synchronous empty-trades
  acknowledgement is therefore not fill truth; order history and positions reconcile it.
- *Shared invariant:* an authored order-status enum no longer converts an unknown raw state
  to `nil`. It returns a named parse error containing venue, source field, and raw value unless
  that exact order-status rule explicitly declares passthrough.

<!-- carve-evidence-status
{"carve_id":"C-T511a","date":"2026-07-24","semantic_source":{"kind":"provider_owned","reference":"Deribit private/get_order_state and speed-bump documentation cited in C-T511a"},"observed_evidence":{"kind":"live_venue","reference":"Deribit testnet marketable option open/close speed_bumped acknowledgements, later filled history, and cancel-race 11044 observed twice 2026-07-24"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T398a — Deribit option Greeks live under nested `greeks.*` with full five-Greek support
(task 398). Outcome: CONFIRM venue; reality tier 1.**

- *Exchange semantics:* ticker rows nest delta/gamma/vega/theta/rho under `greeks` and publish
  bid/ask IV as percent. Combo/spread instruments may appear with `kind=option` without strike
  or option type.
- *Our carve:* `markets.greeks_conventions` maps all five Greeks to `greeks.*`. Discovery
  rejects incomplete combo/spread candidates rather than emitting partial identity records.
- *Live evidence (2026-07-23):* OptionSurface discovery + instrument_greeks on testnet with
  call/put delta sign and range assertions.

<!-- carve-evidence-status
{"carve_id":"C-T398a","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Deribit public/ticker greeks object"},"observed_evidence":{"kind":"live_venue","reference":"Deribit testnet OptionSurface discover + instrument_greeks 2026-07-23"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T397a — Deribit option `amount`, `contracts`, and `contract_size` are distinct named
surfaces (task 397). Outcome: CONFIRMED against provider docs and live testnet; reality tier 1.**

- *Exchange semantics:* Deribit's
  [`private/buy`](https://docs.deribit.com/api-reference/trading/private-buy) defines option
  `amount` in the underlying base currency and permits `contracts` as the contract-count
  alternative. [`public/get_contract_size`](https://docs.deribit.com/api-reference/market-data/public-get_contract_size)
  names the base-currency size of one option contract.
- *Live evidence (2026-07-23):* `BTC-23JUL26-57000-C` reported
  `min_trade_amount=0.1`, `contract_size=1`, settlement BTC, expiry, strike, and call type.
  Testnet accepted and canceled both a unified `amount=0.1` order and a raw
  `contracts=0.1` order; the latter echoed both `amount=0.1` and `contracts=0.1`.
  Raw `amount=0.05` returned JSON-RPC `-32602`, `param=amount`, reason
  `must be a multiple of the minimum order size`.
- *Our carve:* canonical and native `amount` are base units. `contract_size` remains available
  for exact conversion to the alternate `contracts` field; it is never treated as the amount
  step. The existing `qty_tick_size || min_trade_amount` step carve remains C2.

<!-- carve-evidence-status
{"carve_id":"C-T397a","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Deribit private/buy and public/get_contract_size documentation cited in C-T397a"},"observed_evidence":{"kind":"live_venue","reference":"Deribit testnet option amount/contracts success and minimum-amount provider error observed 2026-07-23"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T506a — Deribit option positions use `kind=option` and `instrument_name` for identity;
`size` remains base exposure (task 506). Outcome: CONFIRM venue; reality tier 1.**

- *Exchange semantics:* [`private/get_positions`](https://docs.deribit.com/api-reference/upcoming/account-management/private-get_positions)
  defines `instrument_name` as the instrument identifier, `kind` as the instrument type, and
  option `size` in the base currency.
- *Live evidence (2026-07-23, testnet):* buy order `109144507702` opened 0.1
  `BTC-31JUL26-65000-C`. The raw position carried `kind=option`, `size=0.1`, and that native
  instrument id; unified parsing returned `BTC/USD:BTC-260731-65000-C` with contracts 0.1.
  Reduce-only close order `109144513119` left zero residual. The scrubbed position and
  instrument rows are frozen in `test/fixtures/responses/deribit/fetch_positions.json`.
- *Our carve:* position identity reads the provider `kind` before generic native-id fallback.
  Deribit's authored base-unit quantity is a pass-through, so no contract multiplier is applied.

<!-- carve-evidence-status
{"carve_id":"C-T506a","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Deribit private/get_positions instrument_name, kind, and option size semantics"},"observed_evidence":{"kind":"live_venue","reference":"Deribit testnet option open/position/close lifecycle orders 109144507702 and 109144513119; frozen fetch_positions body"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T380a — `fetchTradingFees` expands the fee schedule over the requested currency's markets only (task 380). Outcome: DIVERGE from CCXT; tier 2, live deferred.**

- *Exchange semantics (non-CCXT):* Deribit's
  [`private/get_account_summary`](https://docs.deribit.com/api-reference/account-management/private-get_account_summary)
  ([pinned authority manifest](../../priv/authority/deribit/manifest.json), artifact
  `api-openapi`) is a **per-currency** call —
  the request carries `currency=BTC`, and the returned `result.fees[]` rows are that currency's
  maker/taker schedule keyed by `instrument_type` (`perpetual` / `future` / `option`). Nothing in
  the response describes any other settlement currency.
- *CCXT's carve:* `fetchTradingFees` loops `for (let i = 0; i < this.symbols.length; i++)` over
  **every** market and assigns the fee tier purely by market type — so a BTC-derived schedule is
  stamped onto ETH (and every other currency's) symbols. Verified against
  `ccxt/ts/src/deribit.ts` on master, fetched 2026-07-19.
- *Our carve + rationale:* emit rows only for markets whose `base` matches the responded
  `result.currency` (the `market_fee_rows` transform's `currency_key`). Reporting BTC's schedule
  as ETH's fee is a wrong *number*, not a formatting difference, and this client's rule is that
  the value must be right (§ Compatibility ≠ correctness). Consequence: `fetch_trading_fees/1`
  returns the default-currency slice, not the whole market list — a caller wanting another
  currency passes `code:` per call. Documented here rather than silently narrowed.
- *Compatibility cost:* our symbol-keyed map is a strict subset of CCXT's. No static
  request/response fixture exists for this method, so no fixture-gate baseline entry changes.
- *Verification tier:* **tier 2 / authored.** `test.deribit.com` returned HTTP 502 on
  unauthenticated `public/get_time` throughout the authoring and review window (2026-07-19
  venue outage; production answered 200 in the same minute), so the tier-1 confrontation is
  deferred — see `docs/prod-verification-ledger.md`.

**C-T380a current-contract amendment — task 468, confronted 2026-07-22. Outcome: DIVERGE from
the current Deribit contract; tier 2, populated-body verification deferred.**

- *Exchange semantics (non-CCXT):* Deribit's
  [`private/get_account_summary`](https://docs.deribit.com/api-reference/account-management/private-get_account_summary)
  schema version `2.1.1`, retrieved and hash-pinned on 2026-07-22 by the
  [Deribit authority manifest](../../priv/authority/deribit/manifest.json), defines `fees` as
  an object keyed first by index name (for example, `btc_usd`), then by instrument type. Each
  instrument object carries `default.type`, `default.maker`, `default.taker`, and an optional
  `block_trade` fee. The provider's populated response example has that same nested shape.
- *Confrontation outcome:* the original currency boundary remains correct: Deribit says the
  returned fee indexes and instrument types are related to the requested currency. The
  authored **carrier shape** does not: C-T380a's `fees[]` rows keyed by `instrument_type` with
  `maker_fee` / `taker_fee` diverge from the current exchange-owned contract.
- *CCXT cross-check (not authority):* CCXT 4.5.65 still reads `fees` as a list and selects
  `instrument_type` / `maker_fee` / `taker_fee`; its agreement with the authored transform is
  compatibility evidence for the legacy shape only.
- *Live reachability:* a signed 2026-07-22 testnet call returned `currency=BTC` but omitted both
  `fee_group` and `fees`, as Deribit documents for an account without discounts. The only
  provisioned Deribit credential is this testnet account; no discounted or production account
  is available. Without a populated venue body, the parser is not rewritten from the schema
  example alone. The slice remains **tier 2 / authored**, and the concrete blocker and required
  field-by-field evidence remain in `docs/prod-verification-ledger.md`.

**C-T380b — `TradingFee.info` carries the venue's raw fee row, not the market object (task 380). Outcome: DIVERGE from Bourse.**

- *CCXT's carve:* sets `'info': market` — the *CCXT-constructed market object*, not venue data.
- *Our carve + rationale:* `info` carries the parsed unified row, with Deribit's own
  `result.fees[]` entry (`instrument_type` / `maker_fee` / `taker_fee`) reachable at
  `info["info"]`. `info` is meant to be the venue's raw payload; a CCXT market struct is this
  library's own construct and carries no exchange evidence.
- *Compatibility cost:* callers reading `info` for market metadata must read the market cache
  instead. Known wrinkle: the raw fee sits one level down at `info["info"]` rather than directly
  at `info` — flattening it is a cosmetic follow-up, not a value defect.

**C-T380b amendment — task 431. Outcome: DIVERGE from CCXT, resolved.**

- *Resolved carve:* transform-synthesized rows carry the venue object in the shared
  `_bourse_info` parser annotation. The shared read-parse enrichment path consumes that annotation
  for every synthesized row, so `TradingFee.info` is directly Deribit's `result.fees[]` entry;
  no nested `info` wrapper remains.
- *Compatibility cost:* unchanged. `info` remains venue evidence rather than CCXT's constructed
  market object, and callers needing market metadata use the loaded market cache.

**C-T430 — `Position.percentage` is computed from unrealized PnL over initial margin, adopting
CCXT's 4-dp-truncated recipe (task 430). Outcome: CONFIRMED against CCXT
`Exchange.safePosition` source.**

- *Exchange semantics:* Deribit's `private/get_positions` row carries no percentage field. CCXT
  does not compute one in `deribit.parsePosition` either — it leaves `'percentage': undefined`
  and the **base class** fills it: `safePosition` runs
  `stringMul(stringDiv(unrealizedPnl, initialMargin, 4), '100')` whenever both operands are
  present. Our deribit slice had the slot authored as an explicit `null`, so we emitted `nil`
  where CCXT emits a number.
- *Our carve + rationale:* adopt it. `percentage` means unrealized PnL as a percentage of
  initial margin, which is well-defined from the two values Deribit does return
  (`floating_profit_loss`, `initial_margin`) — this is a genuine gap in our slice, not a
  deliberate divergence. Authored as a `pnl_percentage` computed rule rather than composing
  `div` + `scale`, because the divide is **truncated to 4 dp before** the ×100 and the rule
  pipeline scales before it truncates.
- *Why the truncation is load-bearing:* the recorded inverse-perp case divides to
  `-0.014591883…`; full precision would render `-1.46`, while CCXT's truncate-then-scale yields
  the `-1.45` its 4.5.65 oracle records. Pinned by `response_parser_test.exs`
  ("pnl_percentage truncates the divide to 4dp before scaling by 100"); the deribit
  fixture-replay gate that also pinned it at the time is since retired (`check.dispatch`
  now runs `mix ccxt.oracle_gate`).
- *Verification tier:* **tier 2 / compatibility.** The oracle is CCXT 4.5.65's recorded
  `parsedResponse` plus CCXT's own `safePosition` source; no live Deribit call can falsify a
  value the venue never sends. The arithmetic — not the venue's semantics — is what is pinned.
- *Sibling gap, not fixed here:* `safePosition` is base-class, so bybit and derive
  `fetchPositions` are red on the same missing field; adjudicating those is task 442.

## Task 344 — residual identifier_reference request renames (2026-07-17)

**C-T344 — Deribit residual identifier_reference request renames (task 344). Outcome: CONFIRMED
against Deribit authority and live testnet validation.**

Task 237 made unresolved `identifier_reference` entries loud for first-class venues. A fresh
shaped-method sweep on Deribit still raised for two residual bindings that task 237's currency
slice left unresolved in the full vendored defaults:

| Method | Native key | Authored binding | Deribit authority |
| --- | --- | --- | --- |
| `fetchOrderTrades` | `order_id` | `source: "id"` (+ omit `symbol`) | `private/get_user_trades_by_order` requires `order_id` |
| `fetchMyLiquidations` | `instrument_name` | `source: "symbol"` (+ date transform) | `private/get_settlement_history_by_instrument` |
| `fetchLiquidations` | `instrument_name` | same | `public/get_last_settlements_by_instrument` |
| `fetchOpenInterest` | `instrument_name` | same | `public/get_book_summary_by_instrument` |
| `fetchFundingRate` | `instrument_name` | same (8h window stays dynamic_construction) | `public/get_funding_rate_value` |
| `transfer` / `withdraw` | `amount` / `address` | self-reference (same unified key) | closes residual `kind: unresolved` stubs |

**Live pins (testnet 2026-07-17):**

- *Success — instrument_name family:* `fetch_open_interest("BTC/USD:BTC")` → HTTP 200 with
  `info.instrument_name == "BTC-PERPETUAL"` (without the rename Deribit returns -32602
  `instrument_name` required).
- *Error — order_id family:* `fetch_order_trades("not-a-real-order-id-task-344")` → JSON-RPC
  `-32602` with `data.param == "order_id"` / `reason == "invalid_order_id"` (proves the rename
  reached address validation rather than a missing-param reject).

`fetchOptionChain` / `fetchVolatilityHistory` still carry full-file `currency` identifier_reference
stubs; they do **not** raise under the required-params sweep because the unified first arg is
labeled `:symbol` and the generic fallback binds `currency` from that positional (CCXT fixtures
pass the bare code `"BTC"` under that key). Correct `code→currency` authoring is deferred until
the shared method_defs label matches CCXT's `code` (out of this task's raise-closing scope).
GET-array dialect remains task 271.

## Historical confrontations (moved from authored-specs.md, task 466)

**C2 — deribit amount granularity: minimum ≠ step, and the live payload names no step.
Outcome: REPLICATE CCXT's proxy, gap registered.**

- *CCXT's carve:* `precision.amount = min_trade_amount` (`deribit.ts:1003`) — a documented
  **minimum** placed in a **step** slot.
- *Exchange semantics (non-CCXT):* `min_trade_amount` = "Minimum amount for trading. For
  perpetual and inverse futures the amount is in USD units. For options and linear futures it
  is the underlying base currency coin" (docs.deribit.com `get_instruments` +
  `private/buy` amount description, fetched 2026-07-15). Live testnet: options show
  `min_trade_amount: 0.1` ≠ `contract_size: 1.0` — the two candidate proxies genuinely differ,
  so the choice is load-bearing. The docs site describes a dedicated `qty_tick_size` ("Minimum
  quantity change (step size) for order amounts") but the live testnet `get_instruments`
  payload does **not** carry it — a docs-vs-live gap, recorded, re-check against production.
- *Our carve + rationale:* amount step := `qty_tick_size` when the payload provides it, else
  `min_trade_amount` (CCXT's proxy — matches observed order-entry granularity on both perps and
  options); `limits.amount.min` carries `min_trade_amount` as the authoritative minimum so the
  min-vs-step conflation stays visible instead of silent.
- *Compatibility cost:* none (identical value to CCXT today; the `qty_tick_size` branch only
  improves it).
- *Implementation:* 170.

**C3 — deribit tiered tick sizes (`tick_size_steps`). Outcome: shared-lossy, deliberately
kept — registered.**

- *CCXT's carve:* drops the field entirely (zero occurrences in `deribit.ts`).
- *Exchange semantics (non-CCXT):* options carry price-tiered tick sizes — live testnet
  2026-07-15: BTC option `tick_size: 0.0001` with
  `tick_size_steps: [%{"above_price" => 0.005, "tick_size" => 0.0005}]`.
- *Our carve + rationale:* scalar `precision.price` = base `tick_size` (CCXT-compatible); the
  tiers stay available raw in `market.info`. A single scalar structurally cannot express the
  tier; minting a typed field now would be gratuitous divergence (no consumer needs tiered
  order-sanity yet) — deferred, not rejected.
- *Compatibility cost:* zero today; the day a consumer places tiered-option orders, order
  sanity must consult `info["tick_size_steps"]` or this entry gets promoted to a typed field.
- *Implementation:* none — this register entry is the deliverable.

**C16 — deribit transaction `state`. Outcome: DIVERGE — map the venue's full state enum instead of
CCXT's two-entry passthrough.**

- *CCXT's carve:* `deribit.ts parseTransactionStatus` maps only `{completed: 'ok', unconfirmed:
  'pending'}` and returns `safeString(statuses, status, status)` — every other state passes
  through **raw**, so a CCXT caller sees venue strings (`"rejected"`, `"replaced"`) sitting in a
  field whose vocabulary is supposed to be CCXT's unified `ok|pending|canceled|failed`.
- *Exchange semantics (non-CCXT — Deribit API reference):* the state enums are closed and
  documented. Withdrawals: `unconfirmed` (awaiting email confirmation), `confirmed`, `cancelled`,
  `completed`, `interrupted`, `rejected`. Deposits: `pending`, `completed`, `rejected`,
  `replaced`.
- *Our carve + rationale:* the authored `enum_map` covers that full union — `completed → ok`;
  `pending`/`unconfirmed`/`confirmed → pending` (in flight, not terminal); `cancelled → canceled`;
  `interrupted`/`rejected`/`replaced → failed`. A caller reading `Transaction.status` gets unified
  vocabulary for every state Deribit documents, which CCXT's passthrough does not deliver.
- *Compatibility cost:* a consumer that pattern-matched CCXT's raw `"rejected"`/`"replaced"`
  strings now reads `"failed"` — deliberate: the field's contract is the unified enum.
- *Residual (accepted, not silent):* `enum_default: "failed"` means an **undocumented or newly
  added** Deribit state resolves to `"failed"` rather than CCXT's raw passthrough. The map is
  complete against today's documented enums, so this fires only if Deribit adds a state. The
  parser's `map_enum/2` has no passthrough mode; giving it one is a spec-vocabulary change, not a
  deribit slice change. Tracked as the residual on this entry.
- *Evidence sources:* Deribit API reference state enums (tier-1 semantic) + the two live testnet deposit
  records (`completed → ok`), `test/bourse/deribit_authored_integration_test.exs`.

**C17 — deribit dated-instrument market identity. Outcome: CONFIRM VENUE + CCXT COMPAT.**

- *Contested id:* `C17` was landed twice in parallel (task 236 here, task 258 for OKX). This entry
  keeps the bare id; the OKX sibling is **C17a**. A citation of "C17" about the OKX sandbox
  `fetchCurrencies` `50038` short-circuit — the CHANGELOG's "Carve C17: sandbox `fetchCurrencies`"
  line and task 277's "demo answers 50038 per carve C17" — means **C17a**, not this carve.
- *Exchange semantics (non-CCXT — Deribit API reference):* instruments are addressed by
  `instrument_name`, and dated futures/options expose `expiration_timestamp`; options also expose
  `strike` and call/put type. Native ids encode that identity directly:
  `BTC-16JUL26` for a dated inverse future and `BTC-16JUL26-56000-C` for a call option.
- *CCXT's carve:* CCXT-JS 4.5.65 represents those as `BTC/USD:BTC-260716` and
  `BTC/USD:BTC-260716-56000-C`, so for the **inverse (USD-quoted, base-settled)** leg the unified
  symbol carries every field required to recover the original `instrument_name`.
- *Our carve + rationale:* Deribit's authored option pattern is `option_ddmmmyy`; inverse dated
  futures encode as base-date native ids (`BTC-16JUL26`), while the unified symbol keeps
  quote/settle plus expiry. `expiry_datetime` is derived from Deribit's epoch field.
- *The `future` flag — DIVERGE from the authored field-map key.* The authored
  `market.field_map.future` keys on `settlement_period` (`{perpetual: false, month: true, week:
  true}`, `enum_default: false`). That key **cannot express the flag**: Deribit also emits
  `settlement_period: "day"` (23 of 74 live dated futures, testnet 2026-07-16 — the nearest-dated
  ones, which is why the defect read as "correlated with expiry"), and options carry the same
  day/week/month periods, so the map reported `future: true` for 3896 of 4564 live options. The
  flag is therefore resolved from the market **type**, matching CCXT-JS `deribit.ts`
  (`future = !swap && kind.includes('future')`): dated `kind=future`/`future_combo` → true;
  perpetual, option, option_combo, spot → false. The `settlement_period` enum_map is left in the
  spec because `swap` legitimately keys on it (`perpetual` is a real period).
- *Evidence sources:* live Deribit testnet `fetch_markets` / `fetch_ticker` on 2026-07-16 (4961 markets, 0
  duplicate symbols; dated-future flag 74/74, options 0/4564, perpetuals 0/109) plus
  `test/bourse/deribit_authored_spec_test.exs`.
- *Follow-up closed by C23/C24:* the USDC-quoted dated-instrument grammar is now modelled by the
  same symbol executor: `BTC_USDC-22JUN26` round-trips as `BTC/USDC:USDC-260622`, and
  `AVAX_USDC-22JUN26-5d5-C` round-trips as `AVAX/USDC:USDC-260622-5.5-C`.

**C27 — Deribit combo instruments retain their native ids. Outcome: DIVERGE from a single-leg unified grammar.**

- *Exchange semantics (non-CCXT — Deribit API reference + live testnet `public/get_instruments` on 2026-07-17):* Deribit calls these combo books and describes them as multiple futures and/or options traded as one strategy. The instrument list labels them `future_combo` and `option_combo`; live examples include future spreads `BTC-FS-17JUL26_PERP` / `BTC-FS-31JUL26_17JUL26` and reversal option combos such as `BTC-REV-18JUL26-65000`. Linear USDC option combos (e.g. call-spread `DOGE_USDC-CS-28AUG26-0d1184_0d12`) reuse C24's lowercase `d` decimal-strike encoding inside multi-leg ids — that is Deribit's own naming, not a unified option shape.
- *CCXT's carve (compatibility reference):* CCXT-JS 4.5.65 also returns the native ids as symbols. This is compatibility evidence only, not the semantic oracle.
- *Our carve + rationale:* retain each combo's `instrument_name` verbatim as its symbol. The unified `BASE/QUOTE:SETTLE-expiry-strike-C/P` grammar identifies one contract; inventing a grammar for variable multi-leg strategies would either hide leg ratios/directions or falsely imply a single underlying instrument. Market `type` still follows the venue's own kind (`future_combo` -> `future`, `option_combo` -> `option`), matching CCXT's `kind.indexOf('combo')` branch.
- *Where the carve is enforced:*
  1. **Market read path (task 299):** retains the id **before** the symbol executor is consulted — combos never enter `from_exchange_id/3` on `fetch_markets`.
  2. **Public `from_exchange_id/3` contract (task 305):** not a combo-specific guard. Under the selected pattern the result is **identity**, a **unified conversion** (string contains `/`), or a **raise** — never a rewritten intermediate that is still exchange-id-shaped. Grammar no-match (the combo case) returns the input id **unchanged**; a non-identity rewrite with no `/` raises `Bourse.Symbol.Error` (`:unrepresentable_id`). The bug this closed: reverse option/future paths applied `String.upcase/1` before matching and, on no-match, returned the uppercased intermediate — so `DOGE_USDC-CS-28AUG26-0d1184_0d12` became `…0D1184_0D12` (plausible, resolves to nothing). `to_exchange_id/2` was already safe the other way (no `/` → `parse_extended/1` fails → verbatim).
- *Confronted, not assumed:* Deribit's combo namespace is multi-leg and variable (`FS`, `REV`, `CS`, …); it is **not** a single-leg option/future id with extra noise. Identity passthrough is the right public-API answer because the id *is* the symbol under this carve — failing loud is reserved for partial transforms that rewrite without producing a unified form, not for "grammar does not apply." CCXT-JS 4.5.65's native-id return is compatibility only; the oracle is Deribit's `instrument_name` + kind.
- *Live evidence (testnet `public/get_instruments`, 2026-07-17):* 188 of 4971 markets carry no-slash symbols — exactly the 145 `future_combo` + 43 `option_combo` rows, none of them USDC dated-instrument parse failures. `to_exchange_id/2` over all 4971 live symbols raises zero exceptions and round-trips every combo id. `test/bourse/deribit_authored_integration_test.exs` is the live evidence; the offline authored-spec regression pins FS, REV, and the `d`-strike USDC combo; `test/bourse/symbol_test.exs` pins that `from_exchange_id/3` identity-passthroughs the d-strike combo and never emits the uppercased rewrite.

**C23 — Deribit linear dated futures use `BASE_USDC-DMMMYY`. Outcome: CONFIRM VENUE + CCXT COMPAT.**

- *Exchange semantics (non-CCXT — Deribit API reference):* Deribit's instrument naming table
  defines dated futures as `BTC-DMMMYY`, and `public/get_instruments` is the addressable
  instrument list (`instrument_name`, `base_currency`, `quote_currency`, `settlement_currency`,
  `expiration_timestamp`). Live USDC rows extend that same dated identity with an explicit
  base/quote prefix, e.g. `BTC_USDC-22JUN26`: the underscore separates `base_currency` from
  `quote_currency`, and the suffix remains the documented `DMMMYY` expiration.
- *CCXT's carve:* CCXT-JS 4.5.65 represents the same id as `BTC/USDC:USDC-260622`, preserving
  base, quote, settle, and expiry so `marketId` can recover the exact `instrument_name`.
- *Our carve + rationale:* `:future_ddmmmyy` now has a Deribit-linear branch:
  `BASE/USDC:USDC-YYMMDD` encodes to `BASE_USDC-DMMMYY`, while inverse
  `BASE/USD:BASE-YYMMDD` keeps the C17 base-only id. This is spec-authored execution, not a
  new heuristic layer; the authored future examples in `authored/deribit.json` are the offline
  round-trip gate.
- *Implementation:* 287.
- *Id note:* authored as **C22** by task 287 while task 296's Binance market-surfaces carve was
  landing under the same id; reconciled to **C23** at land time so the append-only namespace stays
  unique. C22 remains the Binance surfaces/enum-casing carve.

**C24 — Deribit linear option strikes encode decimal points as `d`. Outcome: CONFIRM VENUE + CCXT COMPAT.**

- *Exchange semantics (non-CCXT — Deribit API reference):* the instrument naming table states
  that Linear Options use `d` as the decimal point for decimal strikes, with example
  `XRP_USDC-30JUN23-0d625-C` meaning strike `0.625`.
- *CCXT's carve:* CCXT-JS 4.5.65 represents live rows such as
  `AVAX_USDC-22JUN26-5d5-C` as `AVAX/USDC:USDC-260622-5.5-C`.
- *Our carve + rationale:* `:option_ddmmmyy` now has the matching linear branch:
  `BASE/USDC:USDC-YYMMDD-STRIKE-C/P` encodes to
  `BASE_USDC-DMMMYY-STRIKE_WITH_D-C/P`, and the reverse path decodes `d` back to a decimal
  point. The `markets.patterns.option.anomalies` bucket is empty because those 849 d-decimal
  ids are now modelled rather than parked.
- *Implementation:* 287.

**C25 — Deribit linear USDC perpetuals settle in USDC. Outcome: CONFIRM VENUE + CCXT COMPAT.**

- *Exchange semantics (non-CCXT — live Deribit testnet `public/get_instruments`, 2026-07-17):*
  `1000BONK_USDC-PERPETUAL` reports `instrument_type: "linear"`,
  `base_currency: "1000BONK"`, `quote_currency: "USDC"`,
  `settlement_currency: "USDC"`, and `settlement_period: "perpetual"`. In contrast,
  `BTC-PERPETUAL` reports `instrument_type: "reversed"`, `quote_currency: "USD"`, and
  `settlement_currency: "BTC"`.
- *CCXT's carve:* CCXT-JS 4.5.65 represents the former as `1000BONK/USDC:USDC` and the latter
  as `BTC/USD:BTC`.
- *Our carve + rationale:* a swap id is base-settled only when its quote is USD. Explicit USDC
  quote ids keep USDC as their unified settle currency, so the symbol executor round-trips both
  the linear `BASE_USDC-PERPETUAL` and inverse `BASE-PERPETUAL` grammars. The rule lives on the
  shared swap reverse path (`swap_settle/3`), not a Deribit branch, so it applies to all 33
  venues whose swap pattern is `:implicit` / `:suffix_perpetual` / `:suffix_swap` — verified
  offline to also correct hyperliquid `BTCUSDC`, okx `BTC-USDC-SWAP`, bybit `BTCUSDC`, and
  binanceusdm `BTCUSDC`, each of which previously reversed to `BTC/USDC:BTC`. Derive's
  `:suffix_perp` family keeps its own USDC-settled-with-USD-quote clause and is unaffected.
  The rule assumes no venue lists a base-settled USDC-quoted perp (inverse perps are USD-quoted
  everywhere observed); such an instrument would need its own pattern, not a settle tweak.
- *Implementation:* 300.

> **Carve-id allocation (task 314 supersedes hand-numbering).** Existing `B*`/`C*` ids are
> append-only historical: never renumber or reuse a landed entry, since roadmap tasks and
> completion records point back at these ids. A historical gap is not an
> invitation to backfill it. **New** carves use the task-scoped form `C-T<task-id>` (or
> `C-T<task-id>a` / `b` / … when one task registers several) and name that same task in the
> heading — see § Divergence register **Carve-id allocation**. New hand-numbered bare `B*`/`C*`
> ids (outside the frozen legacy allowlist) are rejected by the dispatch gate; do not allocate
> the next unused numeric id.
>
> When two *historical* parallel landings collided on one bare number, both entries stay — one
> keeps the bare id and the other takes a stable lowercase suffix (`C15a`, `C17a`). Landing order
> does **not** decide which: pick whichever assignment leaves the most existing citations still
> pointing at their real subject, because the cost being minimized is broken references, not
> chronology. (Both suffixed entries here in fact landed *first*; the bare id stayed with the
> more-cited subject.) Whichever way it falls, the collision is only resolved once both halves
> are labelled:
>
> - the suffixed entry records a `Formerly cited as` line naming the bare id it gave up, so prose
>   written before the split still resolves;
> - the bare-id entry records a `Contested id` line pointing at its suffixed sibling, since that is
>   where a reader grepping the bare number lands first and would otherwise stop at the wrong carve.
>
> An unlabelled suffix is worse than the duplicate it replaced: the duplicate is at least visible,
> whereas a silent renumber resolves an old citation to an unrelated carve. The
> manifest-consistency test (`test/bourse/carve_register_consistency_test.exs`, in the
> `mix check.dispatch` stack) verifies id uniqueness, every divergence-contract / CHANGELOG /
> register prose reference, task-scoped id derivation, and rejects new hand-numbered legacy ids;
> the Contested/Formerly labels above are the part it cannot check, so they are on the author.
>
> Task 273's historical `C17` reference is corrected to C15a's *Known gaps* entry above; it must
> not be made to resolve to an unrelated later carve.

<!-- carve-evidence-status
{"carve_id":"C-T380a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T380a and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T380a and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T380a and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T380b","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T380b and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T430","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T430 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T430 and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T344","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T344 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T344 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T344 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C2","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C2 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C2 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C2 and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C3","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C3 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C3 and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C16","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C16 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C16 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C16 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C17","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C17 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C17 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C17 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C27","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C27 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C27 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C27 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C23","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C23 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C23 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C23 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C24","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C24 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C24 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C24 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C25","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C25 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C25 and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

## 2026-08-12 — rate-unit confrontation (Task 594)

**C-T594g — Deribit's authored rate-like slots name their venue units (task 594).
Outcome: CONFIRM provider units.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.funding_rate.field_map.fundingRate`, `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate`, `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction for current/history funding; absent for null interest, next-rate, and previous-rate slots | Deribit defines the payment as funding rate × position size × time fraction and works `0.05%` as `0.0005`; `result`/`interest_8h` and history `interest_1h` therefore remain decimal fractions. [Funding specifications](https://support.deribit.com/hc/en-us/articles/31424939178397-Funding-Specifications) [Funding history](https://docs.deribit.com/api-reference/market-data/public-get_funding_rate_history) |
| `normalization.field_maps.market.field_map.maker`, `normalization.field_maps.market.field_map.taker`, `normalization.field_maps.trading_fee.field_map.maker`, `normalization.field_maps.trading_fee.field_map.taker` | fraction | Deribit applies fee percentages multiplicatively in worked examples (`0.035% = 0.00035`); instrument commission fields and account fee rates retain that fraction. [Fees](https://support.deribit.com/hc/en-us/articles/25944746248989-Fees) [Instruments](https://docs.deribit.com/api-reference/market-data/public-get_instruments) |
| `normalization.field_maps.market.field_map.percentage` | absent boolean; no numeric unit | The market fee-mode flag is null; maker/taker rates are separate. [Instruments](https://docs.deribit.com/api-reference/market-data/public-get_instruments) |
| `normalization.field_maps.option.field_map.percentage` | percent points | Deribit documents `price_change` as the 24-hour price-change percentage and returns examples already in percent points; the authored mapping passes it through. [Ticker](https://docs.deribit.com/api-reference/market-data/public-ticker) |
| `normalization.field_maps.position.field_map.initialMarginPercentage`, `normalization.field_maps.position.field_map.maintenanceMarginPercentage` | percent points | The authored arithmetic divides provider margin by `size_currency` and multiplies by 100, so `10` represents 10%. The position contract supplies those same-unit amounts. [Positions](https://docs.deribit.com/api-reference/account-management/private-get_positions) |
| `normalization.field_maps.position.field_map.percentage` | percent points | The authored `pnl_percentage` operation computes floating PnL divided by initial margin and emits ×100 percent points. [Positions](https://docs.deribit.com/api-reference/account-management/private-get_positions) |
| `normalization.field_maps.ticker.field_map.percentage` | absent; no emitted percentage or unit | The general ticker slot is null; option percentage is mapped on the option-specific surface. [Ticker](https://docs.deribit.com/api-reference/market-data/public-ticker) |
| `normalization.field_maps.trading_fee.field_map.percentage` | boolean, not a numeric rate | The authored `true` declares that maker/taker charges are percentage-based; the numeric rates remain fractions. [Fees](https://support.deribit.com/hc/en-us/articles/25944746248989-Fees) |

<!-- carve-evidence-status
{"carve_id":"C-T594g","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Deribit funding, fee, instrument, ticker, and position contracts linked in C-T594g"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/deribit/fetch_funding_rate.json and fetch_funding_rate_history.json"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Registered funding responses establish the funding values, but the complete position and fee-rate set is documentation/arithmetic anchored rather than covered by populated registered rows"}
-->

**C-T600f — Deribit percent-point IV and margin sources normalize to unified fractions
(task 600). Outcome: DIVERGE from the prior pass-through and ×100 margin rules.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.funding_rate.field_map.fundingRate`, `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction | Deribit funding arithmetic applies decimal fractions. [Funding specifications](https://support.deribit.com/hc/en-us/articles/31424939178397-Funding-Specifications) |
| `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate` | absent | These authored slots are null. [Funding history](https://docs.deribit.com/api-reference/market-data/public-get_funding_rate_history) |
| `normalization.field_maps.greeks.field_map.askImpliedVolatility`, `normalization.field_maps.greeks.field_map.bidImpliedVolatility`, `normalization.field_maps.greeks.field_map.markImpliedVolatility` | fraction | Deribit prices `advanced=implv` in percentages (`100` means 100%); ticker `ask_iv`, `bid_iv`, and `mark_iv` use that percent-point convention. Authored `scale: 0.01` emits fractions. [Order price semantics](https://docs.deribit.com/api-reference/trading/private-buy) [Ticker](https://docs.deribit.com/api-reference/market-data/public-ticker) |
| `normalization.field_maps.option.field_map.impliedVolatility` | absent | The option-instrument row has no authored IV; Greeks carry ticker IV. [Ticker](https://docs.deribit.com/api-reference/market-data/public-ticker) |
| `normalization.field_maps.position.field_map.initialMarginPercentage`, `normalization.field_maps.position.field_map.maintenanceMarginPercentage` | fraction | Margin divided by same-currency `size_currency` is already a fraction; removing ×100 makes `0.1` represent 10%. [Positions](https://docs.deribit.com/api-reference/account-management/private-get_positions) |

- *Live evidence (2026-08-12T08:57:33Z):* testnet `public/ticker` returned
  `BTC-13AUG26-58000-C` with `mark_iv 59.44`, `bid_iv 0.0`, and `ask_iv 343.95`.
  The unified values are `0.5944`, `0.0`, and `3.4395`.

<!-- carve-evidence-status
{"carve_id":"C-T600f","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Deribit order implied-volatility, ticker, positions, and funding contracts linked in C-T600f"},"observed_evidence":{"kind":"live_venue","reference":"2026-08-12T08:57:33Z test.deribit.com public/ticker BTC-13AUG26-58000-C mark_iv 59.44 bid_iv 0.0 ask_iv 343.95; parser goldens in deribit_authored_spec_test.exs"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The live IV row is pinned in parser expectations but is not a manifest-registered response fixture"}
-->

**C-T603f — Deribit margin ratios are restricted to inverse instruments (task 603).
Outcome: DIVERGE from the same-currency claim for linear settlement.**

<!-- rate-unit path="normalization.field_maps.greeks.field_map.askImpliedVolatility" unit="fraction" source-unit="percent_points" --> Deribit ticker IV is in percent points and `scale: 0.01` emits a fraction. [Ticker](https://docs.deribit.com/api-reference/market-data/public-ticker)
<!-- rate-unit path="normalization.field_maps.greeks.field_map.bidImpliedVolatility" unit="fraction" source-unit="percent_points" --> Deribit ticker IV is in percent points and `scale: 0.01` emits a fraction. [Ticker](https://docs.deribit.com/api-reference/market-data/public-ticker)
<!-- rate-unit path="normalization.field_maps.greeks.field_map.markImpliedVolatility" unit="fraction" source-unit="percent_points" --> Deribit ticker IV is in percent points and `scale: 0.01` emits a fraction. [Ticker](https://docs.deribit.com/api-reference/market-data/public-ticker)
<!-- rate-unit path="normalization.field_maps.position.field_map.initialMarginPercentage" unit="fraction" --> On inverse rows, `initial_margin / size_currency` divides same-currency BTC amounts. The provider's `BTC-PERPETUAL` example gives `0.000197283 / 0.006687487`. Linear rows settle margin in USDC/USDT while `size_currency` is base size, so that invalid price-scaled quotient is not emitted. [Positions](https://docs.deribit.com/api-reference/account-management/private-get_positions)
<!-- rate-unit path="normalization.field_maps.position.field_map.maintenanceMarginPercentage" unit="fraction" --> The inverse-only maintenance ratio follows the same unit identity; linear rows emit no unsupported ratio. [Positions](https://docs.deribit.com/api-reference/account-management/private-get_positions)

- *Live reachability (2026-08-12):* authenticated testnet `private/get_positions` calls for
  `USDC` and `USDT` both returned empty lists. The missing populated linear row is tracked in
  the production-verification ledger rather than replaced by a synthetic semantic claim.

<!-- carve-evidence-status
{"carve_id":"C-T603f","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Deribit private/get_positions contract and inverse example linked in C-T603f"},"observed_evidence":{"kind":"live_venue","reference":"2026-08-12 test.deribit.com private/get_positions USDC and USDT both returned empty result lists; inverse provider example is pinned in deribit_authored_spec_test.exs"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"No populated linear testnet position was reachable to establish a provider-owned linear percentage identity"}
-->

## 2026-08-13 — list-read discriminator (Task 606)

**C-T606f — Deribit inverse margin ratios are gated on the payload instrument
(task 606). Outcome: DIVERGE from the request-context `market.inverse` gate.**

<!-- rate-unit path="normalization.field_maps.position.field_map.initialMarginPercentage" unit="fraction" --> Inverse vs linear is read from `instrument_name`: linear ids put settle in the first token (`ETH_USDC-PERPETUAL`); inverse ids do not (`BTC-PERPETUAL`). `fetchPositions` is currency-scoped and never carries a request symbol, so a market-context discriminator is absent on the list path. [Positions](https://docs.deribit.com/api-reference/account-management/private-get_positions)
<!-- rate-unit path="normalization.field_maps.position.field_map.maintenanceMarginPercentage" unit="fraction" --> The maintenance ratio uses the same payload instrument gate. [Positions](https://docs.deribit.com/api-reference/account-management/private-get_positions)

- *Live evidence (2026-08-13):* testnet `private/get_positions` on an open
  `BTC-PERPETUAL` row emitted the same-currency quotient (~0.0295). The
  request-context `market.inverse` gate had dropped that to nil on the list
  path. The Unified.call list-read golden pins the provider inverse example
  `0.000197283 / 0.006687487` and a linear `ETH_USDC-PERPETUAL` nil branch.

<!-- carve-evidence-status
{"carve_id":"C-T606f","date":"2026-08-13","semantic_source":{"kind":"provider_owned","reference":"Deribit private/get_positions instrument naming and same-currency inverse example linked in C-T606f"},"observed_evidence":{"kind":"live_venue","reference":"2026-08-13 test.deribit.com private/get_positions BTC-PERPETUAL open inverse row emitted the same-currency quotient; Unified.call list-read goldens in deribit_authored_spec_test.exs"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The populated inverse list-read is pinned as a parser golden; no populated linear testnet position is registered"}
-->

## 2026-08-14 — symbol-less trade cost (Task 608)

**C-T608a — Deribit trade `cost` is gated on the payload instrument, and option
rows are excluded from the inverse identity (task 608). Outcome: DIVERGE from
the request-context `market.inverse` gate; CONFIRM `amount / price` for reversed
contracts only.**

`fetchMyTrades` without a symbol routes to `private/get_user_trades_by_currency`,
which is currency-scoped and carries no request-context market — so the
`inverse_op` selection silently took the linear `amount * price` branch on every
reversed fill. The provider documents the unit split directly: "For perpetual and
inverse futures the amount is in USD units. For options and linear futures it is
the underlying base currency coin."
([get_user_trades_by_currency](https://docs.deribit.com/api-reference/trading/private-get_user_trades_by_currency))
Reversed contracts therefore settle at `amount / price`; options and linear
futures at `amount * price`.

The payload gate reads `exchange.markets` first and degrades to the instrument-id
shape only for a row whose market is not loaded. The degradation path excludes
the `-C` / `-P` option suffix on purpose: the venue emits `instrument_type` for
futures only, so a loaded option market reads `inverse: false`, and an id-only
classifier that called options inverse would emit `amount / price` against the
documented base-coin amount.

- *Live evidence (2026-08-14):* testnet `private/get_user_trades_by_currency`
  through the symbol-less unified read pinned `cost == amount / price` on a
  `BTC-PERPETUAL` fill, with `load_markets` confirming `BTC-PERPETUAL`
  `inverse: true` and `ETH_USDC-PERPETUAL` `inverse: false`
  (`deribit_authored_integration_test.exs`). The frozen provider row
  (10 USD at 50000) and the option / future-spread degradation branches are
  pinned as parser goldens in `deribit_authored_spec_test.exs`.

<!-- carve-evidence-status
{"carve_id":"C-T608a","date":"2026-08-14","semantic_source":{"kind":"provider_owned","reference":"Deribit private/get_user_trades_by_currency amount and price unit split linked in C-T608a"},"observed_evidence":{"kind":"live_venue","reference":"2026-08-14 test.deribit.com symbol-less fetch_my_trades pinned cost == amount / price on a BTC-PERPETUAL fill; load_markets pinned BTC-PERPETUAL inverse and ETH_USDC-PERPETUAL linear in deribit_authored_integration_test.exs"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"No populated option fill is reachable on the testnet account; the option base-coin cost branch is pinned as a parser golden against the provider-documented amount unit"}
-->

## 2026-08-14 — future position value axes (Task 610)

**C-T610f — Deribit futures expose quote `size`, base `size_currency`, and a
market-owned quote contract size. Outcome: CONFIRMED provider semantics and
DIVERGE from the prior field map (task 610).**

Deribit's [private/get_positions](https://docs.deribit.com/api-reference/account-management/private-get_positions.md)
contract states that future `size` is in quote currency and future-only
`size_currency` is in base currency. Its own BTC-PERPETUAL example reports
`size = 50` USD and `size_currency = 0.006687487` BTC. The unified position now
maps those values to quote `notional` and `base_quantity`, respectively.

[public/get_instruments](https://docs.deribit.com/api-reference/market-data/public-get_instruments)
supplies `contract_size`; BTC-PERPETUAL reports 10 USD. Loaded market metadata
therefore reconciles the example as 5 contracts × 10 USD = 50 USD. No symbol
constant is embedded in the position parser.

- *Live evidence (2026-08-13):* a small BTC-PERPETUAL testnet position exposed
  `size = 10` while the old field map emitted its `size_currency = 0.000157394`
  BTC as notional. The tagged integration test compares all four unified values
  with the raw position and loaded instrument on every run.
- *Named gap `G-T610-options`:* the provider documents option `size` in base
  currency and omits `size_currency`. Option contract-size normalization is
  outside this future-only carve, so option `notional` remains absent rather
  than assigning an unsupported quote meaning.

<!-- carve-evidence-status
{"carve_id":"C-T610f","date":"2026-08-14","semantic_source":{"kind":"provider_owned","reference":"Deribit private/get_positions future size and size_currency contract plus public/get_instruments contract_size"},"observed_evidence":{"kind":"live_venue","reference":"2026-08-13 test.deribit.com BTC-PERPETUAL size 10 and size_currency 0.000157394; tagged reconciliation in deribit_authored_integration_test.exs"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The live position is pinned by a tagged integration assertion but is not yet a manifest-registered populated response fixture"}
-->
