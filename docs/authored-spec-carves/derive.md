# Derive carve register

Append-only schema confrontations for Derive. Follow the allocation and evidence rules in
`docs/authored-specs.md`; this file records decisions and does not define doctrine.

**Canonical for this venue.** Historical narrative may still appear in `docs/authored-specs.md`; this file is the complete carve record (task 466).

## 2026-08-10 — capability endpoint confrontation (Task 549)

**C-T549a — `fetchLiquidations` remains false despite the public and private liquidation-history
endpoints (task 549). Outcome: DIVERGE; reality tier 2.**

- *Exchange semantics:* Derive's
  [public liquidation-history reference](https://docs.derive.xyz/reference/post_public-get-liquidation-history.md)
  describes portfolio auctions and their bids. An auction identifies a subaccount, time range, type,
  transaction hash, and liquidated amounts; it does not identify one instrument liquidation with a
  price, side, contracts, or contract size.
- *Live evidence (2026-08-10):* `public_post_get_liquidation_history`,
  `private_post_get_liquidation_history`, and `private_post_get_liquidator_history` each returned a
  successful response from `api-demo.lyra.finance`; the observed account/history collections were
  empty.
- *Our carve:* neither `private_post_get_liquidation_history` nor
  `private_post_get_liquidator_history` can produce the instrument-scoped `%Bourse.Liquidation{}`
  contract without inventing a symbol and trade attributes. `fetchLiquidations` remains explicitly
  false.

<!-- carve-evidence-status
{"carve_id":"C-T549a","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"Derive public/get_liquidation_history operation schema"},"observed_evidence":{"kind":"live_venue","reference":"api-demo.lyra.finance public/private liquidation-history operations returned successful empty collections on 2026-08-10"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Live reachability was observed, but no manifest-registered populated auction can establish an instrument-scoped Liquidation mapping"}
-->

**C-T549b — `fetchTransfers` maps to `private_post_get_erc20_transfer_history`.
Outcome: CONFIRM (task 549); reality tier 2.**

- *Exchange semantics:* Derive's
  [ERC-20 transfer-history reference](https://docs.derive.xyz/reference/post_private-get-erc20-transfer-history.md)
  defines transfer rows with asset, amount, timestamp, transaction hash, source subaccount,
  counterparty subaccount, and an outgoing-direction flag.
- *Live evidence (2026-08-10):* the authenticated operation returned HTTP 200 with
  `result.events=[]` for demo subaccount 144422. This proves the enabled route and request contract;
  the official schema supplies the row mapping because the account had no transfer row.
- *Our carve:* `tx_hash` becomes the transfer id; `asset`, `amount`, and `timestamp` retain their
  provider values; `is_outgoing` selects the source and destination subaccount identifiers.

<!-- carve-evidence-status
{"carve_id":"C-T549b","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"Derive private/get_erc20_transfer_history operation schema"},"observed_evidence":{"kind":"live_venue","reference":"api-demo.lyra.finance private/get_erc20_transfer_history returned HTTP 200 for subaccount 144422 on 2026-08-10"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The successful live collection was empty; provider-documented rows are pinned by the offline parser test"}
-->

**C-T549c — `fetchBorrowInterest` remains false despite
`private_post_get_interest_history` (task 549). Outcome: DIVERGE; reality tier 2.**

- *Exchange semantics:* Derive's
  [interest-history reference](https://docs.derive.xyz/reference/post_private-get-interest-history.md)
  defines signed dollar interest paid or received by a subaccount. It does not expose a borrowed
  currency, principal, interest rate, margin mode, or market symbol.
- *Live evidence (2026-08-10):* the authenticated endpoint returned HTTP 200 with an empty events
  collection for demo subaccount 144422.
- *Our carve:* a two-sided subaccount interest ledger is not the accrued-interest-on-a-borrow
  contract represented by `%Bourse.BorrowInterest{}`. Mapping it would fabricate the absent borrow
  position, so `fetchBorrowInterest` remains explicitly false.

<!-- carve-evidence-status
{"carve_id":"C-T549c","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"Derive private/get_interest_history operation schema"},"observed_evidence":{"kind":"live_venue","reference":"api-demo.lyra.finance private/get_interest_history returned HTTP 200 for subaccount 144422 on 2026-08-10"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The endpoint describes subaccount cash interest rather than a borrow-position record"}
-->

**C-T549d — `fetchSettlementHistory` remains false despite the option-settlement-history
endpoints (task 549). Outcome: DELIBERATE IMPLEMENTATION CARVE; reality tier 2.**

- *Exchange semantics:* Derive's
  [public option-settlement-history reference](https://docs.derive.xyz/reference/post_public-get-option-settlement-history.md)
  defines option settlement rows with instrument, expiry, amount, settlement price, and settlement
  PnL. The endpoint therefore supplies venue settlement history.
- *Live evidence (2026-08-10):* both public and authenticated demo operations returned HTTP 200;
  the public response contained settlement rows.
- *Our carve:* Bourse has no typed settlement-history struct or parser contract; the repository's
  return-type inventory records `fetchSettlementHistory` as a pending net-new type. Enabling the
  route would return a raw transport map rather than the task's required typed structs. The
  capability remains explicitly false until that unified return contract exists.

<!-- carve-evidence-status
{"carve_id":"C-T549d","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"Derive public/get_option_settlement_history operation schema"},"observed_evidence":{"kind":"live_venue","reference":"api-demo.lyra.finance public and private option-settlement-history operations returned HTTP 200, with public settlement rows, on 2026-08-10"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The client has no typed settlement-history return contract; enabling this route would expose raw transport data"}
-->

## 2026-08-05 — ticker 24h statistics (Task 560)

**C-T560d — Derive's `public/get_ticker` publishes no 24h statistics object, so unified `high`,
`low`, `change` and `percentage` have no source on this venue (task 560). Outcome: DIVERGE from the
inherited carve; reality tier 1.**

- *Exchange semantics:* [`public/get_ticker`](https://docs.derive.xyz/reference/post_public-get-ticker)
  documents a result object of instrument identity, book top, index/mark pricing, fee rates, option
  and perp detail blocks, and a timestamp. It documents no 24h-statistics section, and no `stats`
  member at any nesting level.
- *Live evidence (2026-08-05, both hosts):* `BTC-PERP` returned **36 result keys and no `stats`
  member** on `api.lyra.finance` (mainnet) and on `api-demo.lyra.finance` (demo). The two key sets
  are identical, which rules out a demo-only omission. The only statistics-shaped keys present are
  `five_percent_ask_depth` / `five_percent_bid_depth`, which are book-depth measures, not 24h
  aggregates.
- *Our carve:* the four unified fields are recorded as `null` in the ticker field map. Their prior
  sources — `stats.high`, `stats.low`, and `stats.percent_change` (twice, once scaled by 100) —
  resolved on no host and made the map advertise coverage the venue does not publish. The absence is
  a venue characteristic, not a parse gap.
- *Compatibility reference:* the `stats` shape survives only in the CCXT-derived descriptor's
  embedded sample under `endpoints.descriptors.fetchTicker.source`, whose sample timestamp is
  `1736140984000` (January 2025). The carve was adopted from that sample and never confronted; this
  entry is the confrontation.
- *Related non-defect, recorded so it is not re-filed:* `last` is also `null` and that is **correct**
  — neither the live response nor the reference documents a last-traded-price field on this endpoint.
  Populating it would mean emulating from `public/get_trade_history`, which is a design decision
  rather than a repair.

<!-- carve-evidence-status
{"carve_id":"C-T560d","date":"2026-08-05","semantic_source":{"kind":"provider_owned","reference":"Derive public/get_ticker result schema"},"observed_evidence":{"kind":"live_venue","reference":"api.lyra.finance and api-demo.lyra.finance public/get_ticker BTC-PERP 36 keys without stats, observed 2026-08-05"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT-derived fetchTicker descriptor sample timestamp 1736140984000 carries stats"},"resolved_tier":1}
-->

## 2026-08-04 — documented order-status coverage (Task 538)

**C-T538d — Derive order statuses cover the provider's published open-order vocabulary
(task 538). Outcome: CONFIRM venue; documentation-anchored, live-unverified.** Derive's official
[Get Open Orders reference](https://docs.derive.xyz/reference/private-get_open_orders) lists
`expired` alongside `open`, `filled`, `cancelled`, and `untriggered`. An expired order is terminal
and maps to unified `canceled`. The runtime-wide provider-status coverage test pins the complete
list.

<!-- carve-evidence-status
{"carve_id":"C-T538d","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"Derive Get Open Orders status enum"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"No live order-history row carrying expired is registered"}
-->

**C-T398d — Derive option Greeks live under nested `option_pricing` on get_ticker (task 398).
Outcome: CONFIRM venue; DIVERGE from prior no-greeks capability; reality tier 1.**

- *Exchange semantics:* [`public/get_ticker`](https://docs.derive.xyz/reference/public-get_ticker)
  returns `option_pricing` for option instruments with delta, gamma, vega, theta, rho, bid/ask/mark
  IV, and mark price. CCXT JS does not expose a unified `fetchGreeks` for Derive.
- *Our carve:* author `fetchGreeks` → `publicPostGetTicker` with field map keys under
  `option_pricing.*` (plus top-level bid/ask and timestamp). All five Greeks are supported.
  `has.fetchGreeks` and `has.option` are true. The surface joins market identity by canonical
  symbol and keeps source timestamp vs local `observed_at` distinct.
- *Live evidence (2026-07-23, api-demo.lyra.finance):* active ZEC options returned nested
  pricing; unified `fetch_greeks` and `OptionSurface.instrument_greeks` populated all five
  Greeks with call/put delta sign/range correct.

<!-- carve-evidence-status
{"carve_id":"C-T398d","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Derive public/get_ticker option_pricing schema"},"observed_evidence":{"kind":"live_venue","reference":"api-demo.lyra.finance OptionSurface + fetch_greeks on ZEC options 2026-07-23"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT JS has no Derive fetchGreeks"},"resolved_tier":1}
-->

**C-T397d — Derive option `amount` and `amount_step` are base-asset quantities (task 397).
Outcome: CONFIRMED against provider docs and live demo; reality tier 1.**

- *Exchange semantics:* Derive's
  [`private/order_quote`](https://docs.derive.xyz/reference/private-order_quote) defines
  `amount` in units of the base asset. Instrument rows publish `amount_step`,
  `minimum_amount`, base/quote currencies, and option identity.
- *Live evidence (2026-07-23):* `ZEC-20260925-800-P` reported `amount_step=0.1`,
  `minimum_amount=1`, base ZEC, settlement USDC, expiry, strike 800, and put type. Demo
  accepted/read/canceled a unified base amount of 2. A separately signed raw amount `1.05`
  returned provider code `11012`, `Amount must be a multiple of 0.1`.
- *Our carve:* canonical base exposure passes through unchanged to native `amount`; no contract
  multiplier is invented. The provider step and minimum retain their distinct meanings.

<!-- carve-evidence-status
{"carve_id":"C-T397d","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Derive private/order_quote and instrument documentation cited in C-T397d"},"observed_evidence":{"kind":"live_venue","reference":"Derive demo amount success and amount_step provider error observed 2026-07-23"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T506d — Derive option position `amount` is base exposure and `instrument_type=option`
selects option identity (task 506). Outcome: CONFIRM venue; reality tier 1.**

- *Exchange semantics:* [Get Positions](https://docs.derive.xyz/reference/private-get_positions.md)
  returns `instrument_name`, `instrument_type`, and signed position `amount`; C-T397d establishes
  the venue's option amount unit as base exposure.
- *Observed evidence:* the active api-demo position observed for C-T316a on 2026-07-17 carried
  the provider position fields, while the frozen Derive position shape and task 397 live option
  order prove the same `amount` unit. Task 407 could not create a fresh option position because
  the demo book had zero two-sided instruments; no contrary position-unit signal exists.
- *Our carve:* `instrument_type=option` selects option symbol construction and `amount` passes
  through unchanged. The shared position conversion therefore changes OKX contract-unit rows
  while preserving Derive, Deribit, and Bybit base-unit rows.

<!-- carve-evidence-status
{"carve_id":"C-T506d","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Derive private/get_positions instrument identity and amount fields plus C-T397d base-unit semantics"},"observed_evidence":{"kind":"recorded_venue","reference":"Derive api-demo active position observed 2026-07-17 for C-T316a and live option amount lifecycle observed 2026-07-23 for C-T397d"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-07-22 — response 4.5.65 position adjudication (Task 442)

**C-T442e — Position percentage is unrealized PnL divided by initial margin (task 442).
Outcome: CONFIRM venue and align with the unified position contract.**

Derive's [Get Subaccount](https://docs.derive.xyz/reference/private-get_subaccount) schema defines
each position's `unrealized_pnl` as unrealized trading profit or loss and `initial_margin` as its
USD initial-margin requirement. The recorded `fetchPositions #245` raw row carries both values.
The authored position map now applies the existing `pnl_percentage` operation to those provider
fields, truncating the ratio to four decimal places before multiplying by 100. The fixture becomes
green without importing any new CCXT mechanism.

## Historical confrontations (moved from authored-specs.md, task 466)

**C-T316a — Derive position accounting and entry price. Outcome: DIVERGE from CCXT (task 316).**

- *CCXT's carve:* Derive `parsePosition` copies `unrealized_pnl`, but leaves
  `realizedPnl` and `entryPrice` null and drops `cumulative_funding`,
  `pending_funding`, `total_fees`, and `net_settlements`. The static
  `fetchPositions` fixture records all six raw values while its CCXT golden has
  `realizedPnl: null` and `entryPrice: null`.
- *Exchange semantics (non-CCXT):* Derive's [Get Subaccount reference](https://docs.derive.xyz/reference/private-get_subaccount)
  defines `realized_pnl` as realized position PnL, `average_price` as whole-position
  average price, `cumulative_funding` and `pending_funding` as perpetual funding,
  `total_fees` as fees paid for changing the position, and `net_settlements` as
  settlement cash flow. The task-303 reviewer observed those fields on an active
  `api-demo.lyra.finance` position on 2026-07-17. A task-316 credentialed live
  `fetch_positions(subaccount_id: 144422)` call on 2026-07-17 authenticated but
  returned no active rows, so it cannot replace that recorded live row observation.
- *Our carve + rationale:* carry all six values as numeric `%Bourse.Position{}`
  fields. They are explicit, position-scoped venue accounting values rather than
  market-derived metadata; preserving them keeps the unified row answerable to
  the API. `average_price` maps to `entry_price`.
- *Compatibility cost:* Derive positions now expose six additional values where
  CCXT exposes nil or no field. The C-T316a expected-diff contracts pin both the
  CCXT absence and each fixture value, so regressing to CCXT's drop fails loudly.
- *Tier-1 oracle:* the fixture's raw `httpResponse` (the venue's own JSON, not CCXT's
  interpretation) carries all six values; the Derive reference above supplies the
  non-CCXT semantics. The CCXT `parsedResponse` is only the tier-2 compatibility
  oracle — it is what this carve deliberately diverges from.
- *Reviewer verification (task 316 gate, 2026-07-17):* fetched the Get Subaccount
  reference and confirmed the quoted semantics verbatim — `average_price` is
  "Average price of whole position" (so CCXT's null `entryPrice` is a CCXT bug),
  `total_fees` is "Total fees paid for opening and changing the position",
  `net_settlements` is settlement USD that "is subtracted from the portfolio value
  for margin calculations purposes". Independently re-ran the credentialed live
  `fetch_positions(subaccount_id: 144422)` against `api-demo.lyra.finance`: it
  authenticates and returns 0 rows, reproducing the implementer's caveat — the
  demo subaccount holds no open position, so a live row cannot be re-observed
  without opening one (out of scope per the sweep mutation policy).
- *Implementation:* 316.

## Later confrontations

**C-T372a — Derive spot and option unified identities. Outcome: CONFIRM venue + CCXT compat (task 372).**

- *Exchange semantics:* `public/get_all_instruments` classifies instruments as `erc20`, `perp`,
  or `option`; its rows carry base/quote currencies, and option rows carry expiry, strike, and
  option type under `option_details`.
- *Confrontation:* an `erc20` is a spot asset, so `WEETH-USDC` is `WEETH/USDC` with no settlement
  suffix. An option's native `ZEC-20261225-900-P` identity retains the contract terms as
  `ZEC/USDC:USDC-261225-900-P`.
- *Decision:* map type and nested option metadata from the venue response, with Derive's USDC
  contract settlement; do not preserve the raw option id or append a spot settlement suffix.

**C-T372b — Derive notifications endpoint spelling. Outcome: DIVERGE from CCXT (task 372).**

- *Exchange semantics:* Derive documents the private method as `get_notifications`.
- *Confrontation:* CCXT's generated path is `get_notificationsv`; both clients receive 404 for
  that route.
- *Decision:* register `get_notifications` as the authored-spec correction candidate; the stale
  CCXT path is not an authority for this endpoint.

**C-T416 — Derive private `subaccount_id` default. Outcome: CONFIRM venue + CCXT compat (task 416).**

- *Exchange semantics:* private endpoints such as `private/get_positions`, `private/get_orders`,
  and `private/get_trade_history` require a numeric `subaccount_id` on the body
  ([Derive private reference](https://docs.derive.xyz/reference/private-get_positions.md),
  [pinned authority manifest](../../priv/authority/derive/manifest.json), artifact
  `docs-index`). The smart-contract wallet (`X-LyraWallet` /
  credentials.api_key) authenticates the session; it is not a substitute for the subaccount id.
- *Confrontation:* CCXT JS `handleDeriveSubaccountId` resolves from per-call
  `params.subaccount_id` first, else `exchange.options["subaccount_id"]`, else
  `ArgumentsRequired`. `options.deriveWalletAddress` is a separate identity (wallet header), not
  the subaccount. Our prior request-shape entries were pure `identifier_reference` and raised
  unless every call passed the param.
- *Decision:* accept construction-time `options: %{"subaccount_id" => id}` (atom key also ok);
  request shaping injects it with `put_new` only for methods whose shape lists `subaccount_id`.
  Explicit per-call `subaccount_id` still wins. Missing both still fails loud naming the param.

**C-T528a — Missing private-read identifiers use the unified error contract. Outcome: CONFIRM venue (task 528).**

- *Exchange semantics:* Derive's private order, trade-history, and position endpoints require
  `subaccount_id`; the [Get Subaccount](https://docs.derive.xyz/reference/private-get_subaccount)
  contract likewise declares it as a required integer.
- *Observed behavior:* on 2026-07-29, constructor
  `options: %{"subaccount_id" => 144422}` produced successful live
  `fetch_open_orders`, `fetch_my_trades`, and `fetch_positions` calls against
  `api-demo.lyra.finance`. An explicit unknown id produced provider error `14001`,
  `Subaccount not found`.
- *Decision:* retain the construction-time default from C-T416. When any authored
  `identifier_reference` remains unresolved after venue shaping, the non-bang unified API
  returns `%Bourse.Error{type: :invalid_parameters}` naming the missing parameter and the
  `parameter: value` call-option form; it never leaks the request-shaper exception.

**C-T528b — SM collateral free/used values are undefined. Outcome: DIVERGE from synthesized balance accounting (task 528).**

- *Exchange semantics:* Derive's
  [Get Subaccount](https://docs.derive.xyz/reference/private-get_subaccount) and
  [Get All Portfolios](https://docs.derive.xyz/reference/private-get_all_portfolios)
  response contracts define each collateral's `amount` in asset units. Their margin fields are
  USD-valued credits or requirements: `initial_margin`, `maintenance_margin`, and
  `open_orders_margin`. Neither response defines an available/free asset amount or a locked/used
  asset amount for SM subaccounts.
- *Observed behavior:* the live SM subaccount `144422` response on 2026-07-29 carried ETH
  `amount: "0.02"` and the documented USD margin fields. The unified balance therefore returned
  `total["ETH"] == 0.02`, with `free["ETH"]` and `used["ETH"]` nil.
- *Decision:* map `total` from the provider collateral `amount` and deliberately leave `free`
  and `used` null. Deriving either from a USD margin field would mix currency units and invent a
  provider meaning.

**C-T445 — Derive editOrder is create-plus-order_id_to_cancel. Outcome: CONFIRM venue (task 445).**

- *Exchange semantics:* `POST /private/replace` takes the same signed order body as
  `POST /private/order` plus `order_id_to_cancel` (or `nonce_to_cancel`). See
  docs.derive.xyz replace reference.
- *Confrontation:* the pre-445 generic identifier_reference shape rebound
  `direction` / `limit_price` / `nonce` to the instrument name (same wholesale
  mapping failure task 379 fixed for createOrder). CCXT-JS editOrder is create
  envelope + cancel id; no separate edit signer.
- *Decision:* `RequestShape.Derive.build/4` routes `editOrder` through the shared
  create-order envelope (`build_create_order/3`) and adds `order_id_to_cancel`
  from unified `id`. Unified `clientOrderId` maps to venue `label`. Live tier-1
  on api-demo.lyra.finance: place far limit → edit price → venue open-orders
  echo → cancel; zero resting before/after.

**C-T444 — Derive option instrument identity on read paths. Outcome: CONFIRM venue, DIVERGE from generic expiry encoding (task 444).**

- *Exchange semantics:* `api-demo.lyra.finance` returned option order instrument ids as
  `BASE-YYYYMMDD-STRIKE-C/P`; a live ZEC order on 2026-07-20 read back as
  `ZEC-20260925-800-P`. Derive exposes option orders, positions, and trades, but no unified
  greeks method.
- *Confrontation:* the unified contract keeps a short `YYMMDD` expiry and explicit USDC quote
  and settlement (`ZEC/USDC:USDC-260925-800-P`). The prior write-only request alias shortened
  the venue id after generic denormalization and left read rows carrying the native id.
- *Decision:* author the full-date option pattern bidirectionally in `Bourse.Symbol`. Unified
  writes expand `YYMMDD` to the venue's `YYYYMMDD`; native read rows contract it back to
  `YYMMDD`. Order, position, and trade backfills share that carve; the request-shape alias is
  removed so there is one date mapping.
- *Spec change:* the option pattern's `id_structure` moves from `opaque` to
  `base_expiry_strike_type`. That value is load-bearing, not descriptive:
  `Bourse.Symbol.classify_pattern/2` returns `nil` for `opaque`, which left
  `symbol_patterns[:option]` unset and made both conversion directions identity. The venue's
  ids are mechanically carvable, so `opaque` was the wrong classification.

**C-T473 — Derive createOrder accepts the unified client identifier as `label`. Outcome: CONFIRM venue (task 473).**

- *Exchange semantics:* [`POST /private/order`](https://docs.derive.xyz/reference/post_private-order)
  documents `label` as an optional user-defined string on the create body, with no length or
  character-set constraint. The page does not document the response echo — that half is
  established by live observation below, not by the schema.
- *Confrontation:* on 2026-07-22, api-demo.lyra.finance created far-limit BTC-PERP order
  `48aff9bc-3c8b-4c3c-a53c-8c6d54c8bd21` with label `task473-1784684768712`.
  `fetch_open_orders` returned the identical label, and the order was then canceled.
  Re-attested independently during review the same day: the labeled create/read/cancel
  lifecycle in `test/bourse/derive_authored_integration_test.exs` passed live against
  api-demo.lyra.finance, asserting `info: %{"label" => ...}` on the read-back order. That
  test is the durable evidence — a create path that drops the label reddens it.
- *Decision:* map unified `clientOrderId` to native `label` for both `createOrder` and
  `editOrder`, preserve an explicit native `label`, and remove `clientOrderId` before building
  the wire body.

**C-T379a — Derive order amount comes from the venue's `amount` field, not CCXT's
`desired_amount` lookup (task 379). Outcome: DIVERGE from CCXT; CONFIRM venue.**

- *Exchange semantics:* Derive's order responses publish `amount`; the provider's order schema
  assigns that field the order-size meaning. `desired_amount` is not a response field.
- *Observed behavior:* live create/fetch/cancel lifecycles on ETH-PERP and a ZEC option returned
  `amount` on 2026-07-20; the vendored raw Derive responses likewise contain no
  `desired_amount` field.
- *Compatibility cost:* CCXT `parseOrder` reads `desired_amount`, so its parsed fixtures retain
  nil order amounts.
- *Retired compatibility-baseline inventory:* five deliberate divergences were tied to this
  carve: `cancelOrder #232`, `createOrder #233`, `createOrder #234`, `editOrder #235`, and
  `fetchOrders #244`. Their provider-backed rationale remains this register entry.

## Evidence status records

<!-- carve-evidence-status
{"carve_id":"C-T442e","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Derive Get Subaccount defines position unrealized_pnl and initial_margin"},"observed_evidence":{"kind":"recorded_venue","reference":"Recorded Derive fetchPositions #245 carries both populated operands"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT 4.5.65 safePosition publishes the resulting percentage"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T316a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Derive Get Subaccount field reference cited in C-T316a"},"observed_evidence":{"kind":"recorded_venue","reference":"Raw api-demo position response carries all six values; task-303 observed the active row on 2026-07-17"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT parsedResponse drops or nils the six values"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T379a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Derive order response schema assigns order size to amount"},"observed_evidence":{"kind":"live_venue","reference":"ETH-PERP and ZEC option create/fetch/cancel responses returned amount on 2026-07-20"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT parseOrder reads nonexistent desired_amount and produces nil"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T372a","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T372a and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T372b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T372b and its register context"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T372b and its register context"},"resolved_tier":2,"known_gap_reason":"Provider-owned semantics are recorded, but no independent live or recorded venue observation establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T416","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T416 and its register context"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T416 and its register context"},"resolved_tier":2,"known_gap_reason":"Provider-owned semantics are recorded, but no independent live or recorded venue observation establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T528a","date":"2026-07-29","semantic_source":{"kind":"provider_owned","reference":"Derive Get Subaccount declares subaccount_id required"},"observed_evidence":{"kind":"live_venue","reference":"api-demo private-read successes with subaccount 144422 and error 14001 for unknown subaccount observed 2026-07-29"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T528b","date":"2026-07-29","semantic_source":{"kind":"provider_owned","reference":"Derive Get Subaccount and Get All Portfolios define collateral amount in asset units and margin fields in USD, with no free/used asset fields"},"observed_evidence":{"kind":"live_venue","reference":"api-demo SM subaccount 144422 returned ETH amount 0.02 and no provider free/used asset fields on 2026-07-29"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T445","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T445 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T445 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T445 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T444","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T444 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T444 and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T473","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T473 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T473 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T473 and its register context"},"resolved_tier":1}
-->

## 2026-08-04 — canceled-order response envelope (Task 539)

**C-T539d — `fetchCanceledOrders` reads `result.orders` (task 539). Outcome: CONFIRM venue.**

- *Exchange semantics:* `private/get_orders` returns a JSON-RPC response whose result contains an
  `orders` collection alongside pagination and subaccount metadata.
- *Our carve:* extract `result.orders` before applying the order field map. The JSON-RPC envelope
  is transport metadata, not an order row.
- *Live evidence:* the manifest-registered api-demo recording contains 56 canceled orders under
  `result.orders`; replay preserves all 56 typed rows.

<!-- carve-evidence-status
{"carve_id":"C-T539d","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"priv/authority/derive/manifest.json artifact docs-index; private/get_orders response contract"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/derive/fetch_canceled_orders.json"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-04 — public trade-history window (Task 540)

**C-T540e — Derive trade history uses `from_timestamp`, `to_timestamp`, and `page_size`
(task 540). Outcome: CONFIRM venue.**

- *Exchange semantics:* `public/get_trade_history` documents those fields as its time bounds and
  result-size parameter.
- *Our carve:* `fetchTrades` maps unified `since`, `until`, and `limit` to the provider names and
  removes the unified source names.
- *Live evidence:* `api.lyra.finance` accepted the shaped request at HTTP 200. The registered
  replay is `test/fixtures/public_accepted_requests/derive/fetch_trades--public_post_get_trade_history.json`.

<!-- carve-evidence-status
{"carve_id":"C-T540e","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"Derive public/get_trade_history parameter reference in the pinned docs-index authority artifact"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/public_accepted_requests/derive/fetch_trades--public_post_get_trade_history.json"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-12 — rate-unit confrontation (Task 594)

**C-T594h — Derive's authored rate-like slots name their venue units, and private funding history
is corrected from rate to cashflow (task 594). Outcome: DIVERGE from the prior funding-history map.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.funding_history.field_map.rate` | absent; no emitted rate or unit | `private/get_funding_history` defines `funding` as dollar funding paid or received, not a rate. The authored rate slot is now null. [Private funding history](https://docs.derive.xyz/reference/private-get_funding_history) |
| `normalization.field_maps.funding_history.field_map.amount` | cash amount in quote dollars, not a rate | The same provider contract assigns the signed `funding` cashflow to unified `amount`; the regression test pins `-1.25` as amount and leaves rate null. [Private funding history](https://docs.derive.xyz/reference/private-get_funding_history) |
| `normalization.field_maps.funding_rate.field_map.fundingRate`, `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate`, `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction for current/history funding; absent for null interest, next-rate, and previous-rate slots | Derive publishes `PERP_STATIC_RATE = 0.0000125` as `0.00125%`, explicitly establishing a fraction, and defines funding payment as size × rate × spot × hours. The authored `funding_rate` values pass through. [Asset parameters](https://docs.derive.xyz/docs/asset-parameters-1) [Supported products](https://docs.derive.xyz/docs/supported-products-1) |
| `normalization.field_maps.market.field_map.maker`, `normalization.field_maps.market.field_map.taker` | fraction | The instrument contract identifies the fields as fee rates applied to spot price; registered venue rows carry values such as `0.0001` and `0.0003`, which are retained as fractions. [Get all instruments](https://docs.derive.xyz/reference/public-get_all_instruments) |
| `normalization.field_maps.market.field_map.percentage` | absent boolean; no numeric unit | The market fee-mode flag is null; maker/taker rates are represented separately. [Get all instruments](https://docs.derive.xyz/reference/public-get_all_instruments) |
| `normalization.field_maps.order.field_map.fee.sub_field_map.rate`, `normalization.field_maps.trade.field_map.fee.sub_field_map.rate` | absent; no emitted per-fill rate or unit | Derive order/trade rows expose fee cash amounts, but these nested unified rate slots are null rather than assuming a rate from an amount. [Trade history](https://docs.derive.xyz/reference/public-get_trade_history) |
| `normalization.field_maps.position.field_map.initialMarginPercentage`, `normalization.field_maps.position.field_map.maintenanceMarginPercentage` | absent; no emitted percentage or unit | Both margin-percentage slots are null; the position row preserves margin amounts without inventing ratios. [Get subaccount](https://docs.derive.xyz/reference/private-get_subaccount) |
| `normalization.field_maps.position.field_map.percentage` | percent points | The authored arithmetic is `unrealized_pnl / initial_margin × 100`; both operands are provider-defined dollar amounts. [Get subaccount](https://docs.derive.xyz/reference/private-get_subaccount) |
| `normalization.field_maps.ticker.field_map.percentage` | absent; no emitted percentage or unit | C-T560d establishes that the provider ticker has no 24-hour percentage-change source, so the slot remains null. [Get ticker](https://docs.derive.xyz/reference/post_public-get-ticker) |

<!-- carve-evidence-status
{"carve_id":"C-T594h","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Derive private funding-history, funding parameters/payment, instrument, trade, subaccount, and ticker contracts linked in C-T594h"},"observed_evidence":{"kind":"recorded_venue","reference":"Registered Derive funding-rate accepted requests and fetch_markets response; provider-shaped private funding-history parser regression"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"No populated private funding-history response is manifest-registered; the cashflow correction is provider-schema anchored and pinned with a provider-shaped offline row"}
-->
