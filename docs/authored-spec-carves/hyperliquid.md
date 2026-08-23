# Hyperliquid carve register

Provider authority: [`priv/authority/hyperliquid/manifest.json`](../../priv/authority/hyperliquid/manifest.json).
Machine-read register: `test/bourse/authored_rate_unit_confrontation_test.exs`
parses the `rate-unit` markers and unit tables below against the public structs.
## 2026-07-19 — fetchCurrencies public default (Task 378)
  [pinned authority manifest](../../priv/authority/hyperliquid/manifest.json), artifact
**C-T370 — Hyperliquid unified READ slices (markets / currencies / tickers / funding rates /
ledger / order book / unknownOid). Outcome: CONFIRMED-against-HL docs with two deliberate
divergences (task 370).**

- *Scope:* the per-decision confrontations are recorded as `C-T370-1` … `C-T370-7` below.
- *Divergences:* currency `id = name` (C-T370-3) and bare `fetch_markets` excluding HIP-3
  (C-T370-2). Everything else confirms the venue `/info` semantics.

### C-T370-1 — market field map + metaAndAssetCtxs expand. Outcome: CONFIRMED-against-HL docs.

- *Exchange carve:* perps come from `meta` / `metaAndAssetCtxs` as
  `[{universe: [...]}, assetCtxs[]]` (or bare `{universe}`); spot from
  `spotMetaAndAssetCtxs` as `[{tokens, universe}, ctxs]`. Rows do not carry
  `type`/`quote`/`settle`/`active` on the wire.
- *CCXT reference:* `parseMarket` forces swap flags + USDC quote/settle; spot
  resolves base/quote from the tokens table; price precision is computed from
  mark/mid + `szDecimals`.
- *Our carve:* annotate expands both pair-list shapes into one row per market
  before the field map, injecting `_bourse_type`/`_bourse_*` flags, quote/settle,
  fees, contract_size, active (`!isDelisted`), baseId, and price tick. Field map
  reads those synthetics. Spot fee defaults 7/4 bps; swap 4.5/1.5 bps (venue
  docs + `fees.spot`/`fees.swap` in describe).
- *Evidence:* live testnet 2026-07-18 — `fetch_markets` → 1462 rows
  (1252 spot + 210 swap) with type/flags/quote/settle/precision populated;
  `fetch_spot_markets` / `fetch_swap_markets` no longer FunctionClauseError.

### C-T370-2 — fetch_markets param fan-out (spot + swap). Outcome: ALIGNED-to-ccxt (minus hip3).

- *CCXT carve:* `options.fetchMarkets.types = ['spot','swap','hip3']` Promise.all.
- *Our carve:* bare `fetch_markets` fans out `metaAndAssetCtxs` +
  `spotMetaAndAssetCtxs` only. HIP-3 remains a sibling surface (out of scope for
  370; see task 371 carve).
- *Compatibility cost:* HIP-3 markets absent from bare `fetch_markets` until the
  sibling lands — deliberate.

### C-T370-3 — currency field map from spotMeta.tokens. Outcome: DIVERGE (id = name).

- *Exchange carve:* `spotMeta.tokens[]` rows carry `name`, `index`, `weiDecimals`.
- *CCXT reference:* `id = index`, `code = name`.
- *Our carve:* `id = name` (and `numeric_id = index`) because
  `ReadParse.build_currency_map/2` keys the map by `currency_code(struct.id)` —
  using the index would key currencies as `"0"`, `"1"`, …. Precision is
  `10^(-weiDecimals)` via `decimalPlacesToTickSize`. Missing currency slice fails
  loud (task 319 convention), not silent field loss.
- *Evidence:* live testnet 2026-07-18 — `fetch_currencies` → 1641 codes including
  USDC/PURR with precision populated.

### C-T370-4 — tickers / funding_rates from metaAndAssetCtxs. Outcome: CONFIRMED.

- *Exchange carve:* same `[meta, ctxs]` pair list; ctxs hold mark/mid/funding/
  impactPxs; universe holds name.
- *CCXT reference:* zip → parseTicker / parseFundingRate → symbol-keyed dict;
  funding interval hard-coded `1h` (HL hourly).
- *Our carve:* annotate expands the pair list for ticker + funding_rate parse
  types; native symbol backfill reads `info.name` (not only `coin`); interval
  authored fallback `"1h"` carries this carve as its evidence reference. Bid/ask from `impactPxs` injected as synthetics
  (dotted list indices are not supported by Safe nested-path reads).
- *Evidence:* live testnet 2026-07-18 — both return 210 symbol-keyed entries with
  last/funding_rate/mark_price populated.

### C-T370-5 — ledger_entry from userNonFundingLedgerUpdates. Outcome: CONFIRMED.

- *Exchange carve:* `[{time, hash, delta: {type, usdc, fee?, user?}}]`.
- *CCXT reference:* amount from `delta.usdc`, type enum-map for transfers, fee
  cost from `delta.fee` in USDC; direction left undefined.
- *Our carve:* field map keys `delta.usdc` / `delta.type` / `delta.fee`;
  currency default USDC; status default `"ok"` (no status on wire); direction
  stays nil (same as CCXT).
- *Evidence:* live testnet 2026-07-18 — entries carry amount/currency/type/status.

### C-T370-6 — order book symbol. Outcome: CONFIRMED (already correct).

- *Exchange carve:* l2Book body has `coin`/`levels`/`time`, not a unified symbol.
- *Our carve:* `do_parse("order_book", ...)` stamps `params["symbol"]` on the
  struct (pre-370). Live testnet confirms symbol is the requested unified
  symbol with bids/asks populated. No change.

### C-T370-7 — unknownOid → :order_not_found. Outcome: CONFIRMED-against-CCXT handleErrors.

- *Exchange carve:* bare body `{"status":"unknownOid"}` on orderStatus for a
  missing oid (HTTP 200).
- *CCXT reference:* `handleErrors` throws `OrderNotFound` on
  `status === 'unknownOid'`; `exceptions.exact` is empty in describe — the
  branch is code, not the exact table.
- *Our carve:* keep status sentinel (`=== unknownOid`) and author
  `exceptions.exact.unknownOid = OrderNotFound` into both
  `errors.handle_errors.exceptions.exact` and `raw.describe.exceptions.exact`
  so `error_codes` resolves the sentinel to `:order_not_found`. Also author
  `fetchOrder` request `oid` from unified `id` with integer transform (venue
  rejects string oid with deserialize error).
- *Evidence:* unit plug body + live `fetch_order(..., symbol: "BTC/USDC:USDC")`
  with bogus oid both return `%Bourse.Error{type: :order_not_found}`.

## Task 417 — signer-owned action natives are not request-shape slots (2026-07-19)

## 2026-08-12 — rate-unit confrontation (Task 594)
**C-T594i — Hyperliquid's authored rate-like slots name their venue units (task 594).
Outcome: CONFIRM provider arithmetic.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.funding_rate.field_map.fundingRate`, `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate`, `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction for current/history funding; absent for null interest, next-rate, and previous-rate slots | Hyperliquid defines the payment as position size × oracle price × funding rate and states hourly interest as `0.00125%`; its formula constants are decimal fractions, so `funding` / `fundingRate` pass through. [Funding](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/funding) [Perpetuals API](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals) |
| `normalization.field_maps.market.field_map.maker`, `normalization.field_maps.market.field_map.taker`, `normalization.field_maps.trading_fee.field_map.maker`, `normalization.field_maps.trading_fee.field_map.taker`, `normalization.field_maps.trading_fees.field_map.maker`, `normalization.field_maps.trading_fees.field_map.taker` | fraction | Hyperliquid's provider example multiplies raw `makerRate` / `takerRate` by 100 only when formatting a displayed percentage; authored numeric fields retain the pre-display fractions. [Fees](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/fees) |
| `normalization.field_maps.market.field_map.percentage`, `normalization.field_maps.trading_fee.field_map.percentage`, `normalization.field_maps.trading_fees.field_map.percentage` | absent boolean; no numeric unit | These fee-mode flags are null; maker/taker numeric fields carry fractions independently. [Fees](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/fees) |
| `normalization.field_maps.position.field_map.initialMarginPercentage`, `normalization.field_maps.position.field_map.maintenanceMarginPercentage` | absent; no emitted percentage or unit | The authored position map does not emit either margin-percentage slot. [Clearinghouse state](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#retrieve-a-users-clearinghouse-state) |
| `normalization.field_maps.position.field_map.percentage` | percent points | The annotation computes absolute unrealized PnL ÷ margin used ×100 from provider clearinghouse amounts, so `10` represents 10%. [Clearinghouse state](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#retrieve-a-users-clearinghouse-state) |
| `normalization.field_maps.ticker.field_map.percentage` | absent; no emitted percentage or unit | The authored ticker percentage slot is null. [All mids](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#retrieve-mids-for-all-coins) |
| `normalization.field_maps.trade.field_map.fee.sub_field_map.rate` | absent; no emitted per-fill rate or unit | Fill rows expose the charged fee amount; the nested unified rate remains null rather than deriving a rate without its provider fee basis. [User fills](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#retrieve-a-users-fills) |
| `fees.spot.maker`, `fees.spot.taker`, `fees.swap.maker`, `fees.swap.taker` | fraction | The static schedules use decimal fractions; the provider's displayed fee percentages are the same values ×100. [Fees](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/fees) |

<!-- carve-evidence-status
{"carve_id":"C-T594i","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Hyperliquid funding, fees, clearinghouse, mids, and fills contracts linked in C-T594i"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"Dynamic user fee rates and a populated clearinghouse percentage row are not both covered by manifest-registered responses","note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
## 2026-08-12 — ledger type authority (Task 598)
**C-T600h — Hyperliquid funding fields conform to the cross-venue fraction contract
(task 600). Outcome: CONFIRM and delete the dead income-rate duplicate.**

<!-- rate-unit path="normalization.field_maps.funding_rate.field_map.fundingRate" unit="fraction" --> Hyperliquid applies the decimal funding rate to position notional. [Funding](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/funding)
<!-- rate-unit path="normalization.field_maps.funding_rate.field_map.interestRate" unit="absent" --> The authored slot is null. [Funding](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/funding)
<!-- rate-unit path="normalization.field_maps.funding_rate.field_map.nextFundingRate" unit="absent" --> The authored slot is null. [Funding](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/funding)
<!-- rate-unit path="normalization.field_maps.funding_rate.field_map.previousFundingRate" unit="absent" --> The authored slot is null. [Funding](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/funding)
<!-- rate-unit path="normalization.field_maps.funding_rate_history.field_map.fundingRate" unit="fraction" --> The provider `fundingRate` is the same decimal rate. [Perpetuals API](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals)

`normalization.field_maps.income` is null; its unwired extras entry duplicated the funding rate
without a live parse slot.

<!-- carve-evidence-status
{"carve_id":"C-T600h","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Hyperliquid funding and perpetuals contracts linked in C-T600h"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"The deleted income slice was unwired and had no independent response evidence","note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
**C-T603i — Hyperliquid position percentage preserves PnL sign (task 603).
Outcome: DIVERGE from the absolute-value normalization.**

<!-- rate-unit path="normalization.field_maps.position.field_map.percentage" unit="percent_points" --> Clearinghouse state publishes signed `unrealizedPnl` and signed `returnOnEquity`; a loss therefore remains negative when Bourse computes `unrealizedPnl / marginUsed × 100`. [Perpetuals API](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals)

<!-- carve-evidence-status
{"carve_id":"C-T603i","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Hyperliquid clearinghouseState contract linked in C-T603i"},"observed_evidence":{"kind":"provider_shaped","reference":"Provider example unrealizedPnl -0.0134 and marginUsed 4.967826 pinned in hyperliquid_authored_spec_test.exs"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The signed provider example is not a manifest-registered clearinghouse body"}
-->

**C-T598d — non-funding ledger delta types follow the provider's `WsLedgerUpdate` union (task 598).
Outcome: CONFIRM the 14-literal provider set; DIVERGE because venue-native literals occupy the
unified `type` field when no deliberate alias exists (amended by Task 601).**

- *Provider contract:* the WebSocket subscription schema names 12 union members; expanding
  `WsVaultDelta`'s `vaultCreate`, `vaultDeposit`, and `vaultDistribution` literals yields 14
  distinct `delta.type` values.
- *Our carve:* only deliberate transfer/withdrawal aliases remain explicit. Other documented
  types preserve the provider literal through `enum_passthrough: true`; the provider set is a
  superset guard rather than identity enum padding. This is an explicit unified-vocabulary
  divergence, so a new delta type remains observable instead of silently becoming `nil`.

<!-- carve-evidence-status
{"carve_id":"C-T598d","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Hyperliquid WebSocket subscriptions WsUserNonFundingLedgerUpdates / WsLedgerUpdate union"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Venue-native literals deliberately pass through the unified type field; no account can summon every ledger event on demand"}
-->
