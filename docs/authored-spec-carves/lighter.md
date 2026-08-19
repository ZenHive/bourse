# Lighter carve register

Append-only schema confrontations for Lighter. Follow the allocation and evidence rules in
`docs/authored-specs.md`; this file records decisions and does not define doctrine.

**Canonical for Lighter's complete authored REST surface.** The provider-owned REST contract and
testnet observations decide correctness. The frozen CCXT 4.5.57 reference is compatibility input
only. Provider artifacts are pinned by the
[venue authority manifest](../../priv/authority/lighter/manifest.json) (`priv/authority/lighter/manifest.json`,
artifact `rest-openapi`).

**C-T451a — Four public market-data methods are promoted from live testnet evidence (task 451). Outcome: DIVERGE from CCXT's larger claimed surface.**

- *Exchange semantics (non-CCXT):* Lighter's official OpenAPI defines `orderBookDetails`,
  `orderBookOrders`, and `candles`. Its market rows use numeric `market_id`, `market_type=perp`,
  USDC quote/settlement, decimal precision counts, and object order-book levels keyed by `price`
  and `remaining_base_amount`.
- *Our carve + rationale:* only `fetchMarkets`, `fetchTicker`, `fetchOrderBook`, and `fetchOHLCV`
  are supported. The live testnet returned three active perp markets and successful ticker,
  order-book, and candle payloads. Other public unified methods remain false unless separately
  observed and normalized.
- *Compatibility:* the frozen CCXT Lighter reference describes the same raw endpoints but is not
  correctness evidence.

**C-T451b — Private order reads use the supervised first-party helper (task 451). Outcome: DIVERGE from unsigned generated endpoint claims.**

- *Exchange semantics (non-CCXT):* `accountActiveOrders` and `accountInactiveOrders` require the
  SDK-generated `Authorization` token and an `account_index`. Lighter's API-key guide binds the
  signer to an account and API-key index.
- *Our carve + rationale:* only `fetchOpenOrders` and `fetchClosedOrders` are promoted as unified
  private reads. A valid helper-generated token returned HTTP/code 200; signing for a mismatched
  account produced the real venue error code 29500 with `invalid signature`. The provider marks
  `side` for removal and requires `is_ask`; when `side` is absent, the unified parser derives it
  from that authoritative boolean.
- *Safety:* every helper is terminated by test cleanup so the secret-owning OS process does not
  survive the test.

**C-T451c — Trading is limited to one signed create/fetch/cancel lifecycle (task 451). Outcome: DIVERGE from CCXT's broad mutation claims.**

- *Exchange semantics (non-CCXT):* the official SDK signs create and cancel transactions, then
  submits only `tx_type` and `tx_info` as form data to `POST /api/v1/sendTx`. A successful send
  response acknowledges transaction acceptance; order state is established by an authenticated
  order read.
- *Our carve + rationale:* `createOrder` and `cancelOrder` are the only supported write methods.
  Unified inputs are scaled through the live market precision, the official helper creates the
  transaction payload, and caller-supplied `tx_type`, `tx_info`, or signature values never reach
  transport. Sandbox transactions use Lighter chain 300 rather than mainnet chain 304. The tagged
  test uses a unique client order index and a post-only limit one percent below the live best bid,
  polls the exact order, cancels it, and confirms absence with cleanup in an `after` block.
- *Safety boundary:* that test-owned create/cancel pair is the sole valid mutation exception.
  `sendTxBatch`, withdrawals, transfers, account/API-key changes, margin changes, and all public
  broadcast calls remain unsupported and are never invoked with valid mutation parameters.

**C-T451d — WebSocket support is explicitly absent (task 451). Outcome: DIVERGE from reference subscription shapes. Superseded by C-T544b (task 544).**

- *Exchange semantics (non-CCXT):* Lighter publishes WebSocket channels, but no channel was live
  subscribed and adjudicated by this task.
- *Our carve + rationale:* every owned WebSocket slot is marked `supported=false`; no WebSocket
  capability is advertised from generated/reference plumbing.
- *History:* C-T544b supersedes the absence claim. Public transport is now authored and
  live-verified; unified watch templates stay unresolved because the provider requires a
  numeric market index.

**C-T451e — Every remaining unified method is explicitly unsupported (task 451). Outcome: DIVERGE from generated and CCXT claims.**

- *Exchange semantics (non-CCXT):* the pinned provider OpenAPI inventory and official trading/API
  key guides were confronted with the runtime method inventory.
- *Our carve + rationale:* all 110 reference method keys remain present in `capabilities.has` and
  `endpoints.unified`; exactly eight have routes and every other method is `false` with an empty
  route. This includes withdrawals, transfers, key/account changes, leverage/margin writes,
  funding aggregates, and unverified account/position reads.
- *Compatibility:* the repository contains no vendored Lighter request/response JSON in CCXT's
  static fixture corpus. The frozen CCXT 4.5.57 spec and existing signer/unit fixtures remain
  tier-2 references; the diff-scoped fixture gate records that absence without upgrading it to
  reality evidence.

**C-T451f — Lighter publishes no error-code enumeration; its authored codes are live-observed (task 451). Outcome: DIVERGE from the pinned-enumeration contract every other first-class venue meets.**

- *Exchange semantics (non-CCXT):* the pinned `rest-openapi` artifact defines only the
  `{code, message}` result envelope — it lists no code values — and no `apidocs.lighter.xyz` /
  `docs.lighter.xyz` page enumerates them (probed 2026-07-23, all 404). Lighter therefore has no
  provider-published enumeration to grade authored mappings against.
- *Our carve + rationale:* Lighter is exempt from the `error_enumeration` corpus contract via a
  governed entry in `Mix.Tasks.Ccxt.AuthorityCorpus.error_enumeration_exemptions/0`. In exchange,
  both authored exact codes are pinned by live testnet observation rather than by a document:
  `20001` → `BadRequest` (public `orderBookOrders` with no params) and `29500` →
  `AuthenticationError` (`invalid signature` for a mismatched account index). The exemption is
  asserted to hold exactly one venue, to carry a reason, and to name test files that actually
  contain each authored code — so it cannot grow silently or outlive the evidence.
- *Safety:* an exempt venue may not also ship an `errors.json`; a future published Lighter
  enumeration retires the exemption rather than layering on top of it.

## Evidence status

<!-- carve-evidence-status
{"carve_id":"C-T451a","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Lighter REST OpenAPI at lighter-python commit 6957dd8a and official API reference"},"observed_evidence":{"kind":"live_venue","reference":"Lighter testnet HTTP/code 200 for fetchMarkets, fetchTicker, fetchOrderBook and fetchOHLCV; pinned by lighter_promotion_integration_test.exs"},"compatibility_reference":{"kind":"ccxt","reference":"frozen Lighter CCXT 4.5.57 spec"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T451b","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Lighter accountActiveOrders/accountInactiveOrders OpenAPI and API-key guide"},"observed_evidence":{"kind":"live_venue","reference":"first-party helper token returned HTTP/code 200; mismatched signed account returned code 29500 invalid signature"},"compatibility_reference":{"kind":"ccxt","reference":"frozen Lighter CCXT 4.5.57 spec"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T451c","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"official lighter-python SignerClient create_order/cancel_order and sendTx OpenAPI"},"observed_evidence":{"kind":"live_venue","reference":"safe testnet create/fetch/cancel lifecycle in lighter_promotion_integration_test.exs"},"compatibility_reference":{"kind":"ccxt","reference":"frozen Lighter CCXT 4.5.57 spec"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T451d","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"Lighter WebSocket reference"},"observed_evidence":{"kind":"live_venue","reference":"no live subscription evidence was produced; owned WebSocket slots explicitly advertise supported=false"},"compatibility_reference":{"kind":"ccxt","reference":"frozen Lighter CCXT 4.5.57 WebSocket shapes rejected as support proof"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T451f","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"pinned Lighter rest-openapi result envelope; apidocs.lighter.xyz and docs.lighter.xyz error-code pages probed and absent (404)"},"observed_evidence":{"kind":"live_venue","reference":"testnet code 20001 invalid param and code 29500 invalid signature, pinned by lighter_promotion_integration_test.exs and lighter_signing_integration_test.exs"},"compatibility_reference":{"kind":"ccxt","reference":"frozen Lighter CCXT 4.5.57 spec"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T451e","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"pinned Lighter OpenAPI operation inventory plus official trading and API-key guides"},"observed_evidence":{"kind":"live_venue","reference":"live promotion probes observed only the eight promoted boundaries; all other runtime methods retain explicit false/empty declarations"},"compatibility_reference":{"kind":"ccxt","reference":"frozen Lighter CCXT 4.5.57 spec; no Lighter cases exist in the vendored static request/response fixture corpus"},"resolved_tier":1}
-->

## 2026-08-04 — candle window inputs (Task 540)

**C-T540f — Lighter candles use computed `start_timestamp` and `end_timestamp` bounds
(task 540). Outcome: CONFIRM provider contract.**

- *Exchange semantics:* the provider OpenAPI defines `start_timestamp`, `end_timestamp`, and
  `count_back` for `GET /api/v1/candles`.
- *Our carve:* `fetchOHLCV` computes the native millisecond window from unified `since`,
  `timeframe`, and `limit`, then removes the consumed unified `since` and `limit` keys.
- *Verification:* the ten-venue request-shape sweep pins both the native start field and absence
  of the consumed source keys.

<!-- carve-evidence-status
{"carve_id":"C-T540f","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"priv/authority/lighter/manifest.json artifact rest-openapi; GET /api/v1/candles parameters"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Provider-owned semantics and offline request shape are pinned; no task-specific live window recording is registered"}
-->

## 2026-08-10 — optional private-order market scope (Task 541)

**C-T541a — Private order reads omit `market_id` when no symbol is supplied and resolve it when a symbol is supplied (task 541). Outcome: CONFIRM provider contract.**

- *Exchange semantics:* the pinned provider OpenAPI marks `market_id` optional on both
  `accountActiveOrders` and `accountInactiveOrders`; the active-orders endpoint explicitly says
  omission returns orders for all markets. The inactive-orders endpoint documents no omission
  semantics — provider acceptance is verified, but cross-market coverage of the symbol-less
  closed-orders read is unverified (the testnet account had no closed orders in two markets to
  distinguish "all markets" from a narrower default). Both endpoints still require `account_index`.
- *Our carve:* the two authored request bindings mark `market_id` as optional dynamic
  construction. Symbol-less unified reads omit it, while symbol-scoped reads resolve and send the
  selected market's numeric id. Account identification remains unchanged.
- *Verification:* live testnet calls returned HTTP/code 200 for both endpoints with `market_id`
  omitted and with market `0` supplied. The tagged integration test exercises the same four
  unified calls against `testnet.zklighter.elliot.ai`.

<!-- carve-evidence-status
{"carve_id":"C-T541a","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"priv/authority/lighter/manifest.json artifact rest-openapi; GET /api/v1/accountActiveOrders and /api/v1/accountInactiveOrders parameters"},"observed_evidence":{"kind":"live_venue","reference":"testnet HTTP/code 200 for unified fetch_open_orders and fetch_closed_orders with omitted and symbol-resolved market_id; pinned by lighter_signing_integration_test.exs"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-10 — order status vocabulary (Task 552)

**C-T552 — Lighter's closed order-status vocabulary maps explicitly into unified order state
(task 552). Outcome: DIVERGE from provider-native passthrough.**

- *Exchange semantics:* the pinned provider OpenAPI defines 17 order statuses. `in-progress`,
  `pending`, and `open` are non-terminal; `filled` is complete; `canceled` and the twelve
  `canceled-*` reasons are canceled terminal states.
- *Our carve:* map the three non-terminal states to unified `open`, `filled` to `closed`, and
  every cancellation state to `canceled`. This makes `Bourse.Order.open?/1`, `closed?/1`, and
  `canceled?/1` truthful while retaining fail-loud behavior for any provider value outside the
  documented enum. The previous `enum_passthrough` silently bypassed those predicates.
- *Live evidence:* the first authenticated Lighter testnet reads returned successful empty open
  and closed collections. The repository's sole permitted mutation probe then created a
  post-only order, observed provider status `open`, canceled it, and observed provider status
  `canceled`; cleanup completed successfully. The provider OpenAPI supplies the complete closed
  vocabulary that the live account cannot exercise safely in one session.
- *Compatibility:* consumers now receive only the documented unified order states instead of
  Lighter-native cancellation reasons in `Order.status`; the provider reason remains a transport
  concern rather than a fourth unified lifecycle state.

<!-- carve-evidence-status
{"carve_id":"C-T552","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"priv/authority/lighter/manifest.json artifact rest-openapi; Order.status enum at pinned lighter-python revision 6957dd8a"},"observed_evidence":{"kind":"live_venue","reference":"Lighter testnet create/fetch/cancel lifecycle on 2026-08-10 observed open then canceled; behavior pinned by test/bourse/lighter_promotion_integration_test.exs"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-11 — account and history response slices (Task 546)

**C-T546 — Lighter's account response supplies balance and positions, and unified history
methods use the venue-owned history endpoints (task 546; amended by task 595). Outcome: CONFIRM the
provider contract with three unified-carve DIVERGENCES.**

- *Exchange semantics:* `GET /api/v1/account` returns account `assets` and `positions` in one
  response. The provider OpenAPI defines the account-scoped trade, deposit, withdrawal, transfer,
  and liquidation history responses under their corresponding endpoints.
- *Our carve — DIVERGE, position symbol:* `AccountPosition.symbol` is the base asset (`BTC`),
  while the unified contract requires `BTC/USDC:USDC`. The parser resolves `market_id` through
  the loaded market table and retains the provider symbol in `info`; neither the required provider
  field nor a raw market-id string can become the unified symbol. The same market-id resolution is
  applied to trades and liquidations.
- *Our carve — DIVERGE, free balance:* USDC `free` is the account-level
  `available_balance`; `total` is collateral. It is not computed as asset balance plus
  `margin_balance` minus `locked_balance`: with a live 0.011 BTC position the venue reported
  `available_balance = 9964.544690`, `collateral = 10000.000000`, and
  `margin_balance = 10000.000000`, proving the subtraction carve overstates spendable funds.
- *Our carve — DIVERGE, transfer routes:* unified `from` and `to` carry
  `from_account_index` and `to_account_index`. The provider's independent `spot|perps`
  `from_route` and `to_route` remain in `info`; substituting routes for account identity loses the
  counterparty and can make both ends read `perps`. Recordings scrub account indexes, so the tagged
  live round-trip test proves the identities before scrubbing and the provider-shaped stub pins the
  offline mapping.
- *Trade semantics:* the reader compares `ask_account_id` and `bid_account_id` with the credential
  account index, then derives side, maker/taker role, matching order id, and the corresponding
  maker/taker fee. The provider `type` enum (`trade`, `liquidation`, `deleverage`,
  `market-settlement`) classifies the fill and is not a unified order type. The funded testnet
  account has zero fees, so its live rows omit the optional fee fields; fee selection remains
  provider-shape verified rather than live-value verified. The committed trade recording masks
  both account ids, so replaying it offline resolves no role and leaves side, maker/taker, order
  and fee null: those four slots are proved by the tagged live fill test against the unscrubbed
  response and pinned offline by the provider-shaped stub, never by the recording itself.
- *Flat positions:* provider `sign = 1` remains present on a zero-size row, so unified side is
  suppressed whenever signed size is zero rather than inferred from `sign` alone.
- *Request provenance:* private-history recordings persist the reproducible resolved caller
  parameters (`account_index`, `market_id`, and deposit `l1_address`). Only the time-varying
  `auth_deadline` is exempt from congruence replay.
- *Timestamp units:* deposit, withdrawal, transfer, and trade timestamps are parsed as
  milliseconds. Populated live deposit, transfer, and trade responses carried 13-digit values
  despite shorter example values in the provider schema.
- *Funding distinction:* `fetchFundingRateHistory` maps to `GET /api/v1/fundings`, Lighter's own
  market funding history. `GET /api/v1/funding-rates` is a cross-exchange reference feed and is
  deliberately not a unified funding source.
- *Verification status:* balance and position recordings contain a real open BTC position;
  deposits, trades, and transfers contain real rows. The transfer rows came from a reversible
  perps-to-spot-to-perps USDC round trip, and the fill probe closes its BTC position in cleanup.
  Withdrawal and liquidation recordings are fresh but empty and therefore prove only endpoint and
  empty-envelope shape; their populated slices remain unverified. Liquidating a funded account and
  withdrawing funds without an independently authorized redeposit path are not reversible evidence
  operations. The tagged integration tests require credentials and fail loudly when unavailable.

<!-- carve-evidence-status
{"carve_id":"C-T546","date":"2026-08-14","semantic_source":{"kind":"provider_owned","reference":"priv/authority/lighter/manifest.json artifact rest-openapi revision 6957dd8a; AccountPosition, Trade, DepositHistoryItem, TransferHistoryItem, WithdrawHistoryItem and Liquidation schemas"},"observed_evidence":{"kind":"live_venue","reference":"populated open-position fetch_balance/fetch_positions, fill fetch_my_trades, deposit fetch_deposits and reversible USDC fetch_transfers testnet recordings under test/fixtures/responses/lighter; fresh empty fetch_withdrawals/fetch_my_liquidations recordings are shape-only; live semantics pinned by test/bourse/lighter_promotion_integration_test.exs"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T546g — Lighter's funding `rate` is a PERCENT, so the unified fraction is `rate / 100`
(ARC follow-up to task 546). Outcome: DIVERGE from the verbatim-copy reading the original
task shipped.**

- *Exchange semantics:* the provider schema documents `Funding.rate` with no unit, but the
  venue's own cross-field arithmetic settles it: for every live market
  `value == mark_price × rate / 100` (funding value per one base unit). Observed on
  2026-08-11 against `testnet.zklighter.elliot.ai` across markets 0/1/2 — e.g. market 1
  (BTC): `rate 0.0012`, `value 0.76667760`, `value / rate × 100 = 63 890` against a live
  mark price of `64 068.6` from `orderBookDetails`; ETH and SOL reconcile the same way. A
  fraction reading would imply a $639 BTC, which the venue's own order book refutes.
- *Our carve:* the authored `fundingRate` rule scales by `0.01`, so a raw `"0.0012"` row
  parses to the unified fraction `1.2e-5` (0.0012 %/h). The original verbatim copy shipped
  values 100× too large and was ratified by a golden computed with the same assumption —
  the canonical golden-ratification failure mode.
- *Class note:* every authored rate-like slot needs a recorded unit confrontation; the
  cross-venue sweep is tracked in the workbench roadmap rather than patched per instance.

<!-- carve-evidence-status
{"carve_id":"C-T546g","date":"2026-08-11","semantic_source":{"kind":"provider_owned","reference":"priv/authority/lighter/manifest.json artifact rest-openapi; Funding schema, fundings and orderBookDetails operations"},"observed_evidence":{"kind":"live_venue","reference":"2026-08-11 cross-field identity value == mark_price × rate / 100 across markets 0/1/2 on testnet.zklighter.elliot.ai; pinned offline by test/bourse/lighter_authored_spec_test.exs funding expectation 1.2e-5"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T546h — `deposit/history` additionally requires the account's `l1_address`, which the
client requires from the caller (ARC follow-up to task 546). Outcome: CONFIRM provider
contract, with a loud client-side requirement.**

- *Exchange semantics:* the pinned OpenAPI marks BOTH `account_index` and `l1_address`
  `required=true` for `GET /api/v1/deposit/history`, while `withdraw/history` requires only
  `account_index` — the asymmetry is real and live-verified on 2026-08-11: with
  `account_index` alone the venue answers `20001 "invalid param"`; with both it returns
  HTTP 200 and populated deposit rows.
- *Our carve:* credentials do not carry the L1 wallet address, so the request-shape builder
  refuses `fetchDeposits` without a caller-supplied `l1_address` and raises an
  `ArgumentError` naming the parameter and where the venue publishes it
  (`public_get_account`), instead of shipping the venue's unspecific 20001. Automatic
  resolution via an extra account round-trip is deliberately not performed inside request
  building.

<!-- carve-evidence-status
{"carve_id":"C-T546h","date":"2026-08-11","semantic_source":{"kind":"provider_owned","reference":"priv/authority/lighter/manifest.json artifact rest-openapi; deposit/history and withdraw/history required parameter lists"},"observed_evidence":{"kind":"live_venue","reference":"2026-08-11 live probes: account_index alone → 20001 invalid param; account_index + l1_address → HTTP 200 with three deposit rows; builder refusal pinned by test/bourse/lighter_authored_spec_test.exs"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T592d — Lighter history required fields populate unified currency, transaction type, and
transfer fee (task 592). Outcome: CONFIRM provider contract.**

- *Exchange semantics:* `DepositHistoryItem.asset_id`, `WithdrawHistoryItem.asset_id`, and
  `TransferHistoryItem.asset_id`/`fee` are required. The asset operation uses that same numeric
  id space. `WithdrawHistoryItem.type` (`secure`/`fast`) describes withdrawal mode, not the
  unified deposit/withdrawal vocabulary.
- *Our carve:* transaction and transfer currency resolve `asset_id` through the authored venue
  currency catalog. Transaction type is the calling operation's `deposit`/`withdrawal` literal;
  transfer fee carries both the required cost and the resolved currency.
- *Verification:* the live-recorded 10,000 USDC deposit now parses with `currency: "USDC"` and
  `type: "deposit"`; provider-shaped withdrawal and transfer rows pin the other required slots.

<!-- carve-evidence-status
{"carve_id":"C-T592d","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"priv/authority/lighter/manifest.json artifact rest-openapi; DepositHistoryItem, WithdrawHistoryItem, TransferHistoryItem and Asset schemas"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/lighter/fetch_deposits.json plus provider-shaped withdrawal and transfer parser fixtures in test/bourse/lighter_authored_spec_test.exs"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T600i — Lighter's rate-like slots normalize to the cross-venue units (task 600).
Outcome: DIVERGE from pass-through margin; CONFIRM funding, fee, and ticker units.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction | C-T546g proves the provider `Funding.rate` is percent points from `value = mark_price × rate / 100`; `scale: 0.01` emits a fraction. [Lighter OpenAPI](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |
| `normalization.field_maps.market.field_map.maker`, `normalization.field_maps.market.field_map.taker` | fraction | The market's decimal maker/taker fee rates are multiplicative charges; the recorded zero rates remain fractions. [Lighter OpenAPI](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |
| `fees.maker`, `fees.taker` | fraction | The venue-level zero defaults are decimal fee fractions; authenticated market rows remain authoritative. [Lighter OpenAPI](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |
| `normalization.field_maps.market.field_map.percentage` | absent | The fee-mode flag is null. [Lighter OpenAPI](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |
| `normalization.field_maps.position.field_map.initialMarginPercentage` | fraction | The provider's `initial_margin_fraction` response is percent points (`"5.00"`); authored `scale: 0.01` emits `0.05`. The recorded position pins that conversion. [Lighter OpenAPI](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |
| `normalization.field_maps.position.field_map.maintenanceMarginPercentage`, `normalization.field_maps.position.field_map.percentage` | absent | Neither position field is authored. [Lighter OpenAPI](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |
| `normalization.field_maps.ticker.field_map.percentage` | percent points | The provider publishes `daily_price_change` as the daily percentage change; the recorded ticker raw `1.3548036637247152` emits 1.3548 percent points. [Lighter OpenAPI](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |

<!-- carve-evidence-status
{"carve_id":"C-T600i","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Pinned Lighter OpenAPI Funding, AccountPosition, OrderBookDetail and fee schemas"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/lighter/fetch_positions.json raw initial_margin_fraction 5.00; fetch_ticker.json raw daily_price_change 1.3548036637247152; C-T546g live funding arithmetic"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T603g — Lighter's scaled percentages declare their source units (task 603).
Outcome: CONFIRM percent-point-to-fraction conversion.**

<!-- rate-unit path="normalization.field_maps.funding_rate_history.field_map.fundingRate" unit="fraction" source-unit="percent_points" --> Lighter's funding row is percentage-valued; `scale: 0.01` emits the unified fraction. [API reference](https://apidocs.lighter.xyz/)
<!-- rate-unit path="normalization.field_maps.position.field_map.initialMarginPercentage" unit="fraction" source-unit="percent_points" --> `initial_margin_fraction` is percentage-valued; `scale: 0.01` emits the unified fraction. [API reference](https://apidocs.lighter.xyz/)

<!-- carve-evidence-status
{"carve_id":"C-T603g","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Pinned Lighter Funding and AccountPosition schemas"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/lighter/fetch_positions.json","fixture":"test/fixtures/responses/lighter/fetch_positions.json"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-14 — ARC wave-2 amendments (trade fee scale, transfer fee currency)

**C-T546i — the trade `fee.cost` slot is re-scoped OUT of C-T546's tier-1 claim:
the provider types `Trade.taker_fee`/`maker_fee` as `int32` while every other
Trade money field is a string, and no live row of our account has ever carried
the field (task 546). Outcome: value scale UNVERIFIED; the parse is a raw
pass-through.**

The pinned OpenAPI (revision 6957dd8a) declares `taker_fee`/`maker_fee` as
optional `integer/int32` on `Trade` — the same schema types `size`, `price`,
`usd_amount` and both `LiqTrade` fee fields as strings. Elsewhere this venue's
integer money fields are scaled units (our own write path submits `usdc_fee`
through `scaled_integer!` at 1e6 per USDC), so reading the raw integer as a
decimal USDC amount is an unconfirmed guess. The 2026-08-14 live re-recording
confirms the venue omits both keys on every returned fill (zero-fee testnet
fills), so no recording can currently discriminate. The offline stub pins the
pass-through as plumbing only and says so in-line; the scale question is
tracked in `docs/prod-verification-ledger.md` and closes with one fee-bearing
fill or a provider statement of the unit.

<!-- carve-evidence-status
{"carve_id":"C-T546i","date":"2026-08-14","semantic_source":{"kind":"provider_owned","reference":"priv/authority/lighter/manifest.json artifact rest-openapi revision 6957dd8a; Trade.taker_fee/maker_fee typed int32 vs string money siblings"},"observed_evidence":{"kind":"live_venue","reference":"2026-08-14 re-recorded test/fixtures/responses/lighter/fetch_my_trades.json — the venue omits maker_fee/taker_fee on every observed fill, so the field has zero populated evidence"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The fee value scale is unverifiable on our zero-fee testnet fills; ledger entry open until a fee-bearing row or provider unit statement exists"}
-->

**C-T546j — the transfer `fee.currency` is USDC by the venue's own contract,
not the transferred asset (task 546). Outcome: DIVERGE from the prior
asset-derived currency.**

The signed transfer payload names its fee field `usdc_fee`
(`Bourse.Signing.Lighter.Protocol` and `native/lighter_signer/csrc/helper.c`),
i.e. the transfer fee is USDC-denominated regardless of `asset_id`. The prior
map derived `fee.currency` from `asset_id`, which mislabels any non-USDC
transfer's fee; the authored slice now pins the constant `USDC` (same shape as
hyperliquid's USDC-fee treatment). The only live recording moves USDC
(`asset_id` 3) and cannot discriminate, so the divergence is authored from the
provider-owned payload contract.

<!-- carve-evidence-status
{"carve_id":"C-T546j","date":"2026-08-14","semantic_source":{"kind":"provider_owned","reference":"Lighter signed transfer payload field usdc_fee (Signing.Lighter.Protocol, lighter_signer helper.c); fee denominated in USDC independent of asset_id"},"observed_evidence":{"kind":"recorded_venue","reference":"test/fixtures/responses/lighter/fetch_transfers.json (USDC transfer, asset_id 3 — consistent but non-discriminating)"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"No non-USDC transfer observed; a populated non-USDC row would make the constant discriminating"}
-->

Two register notes without carve blocks:

- *Balance `free`/`used` layers:* lighter maps `free` from the account-level
  `available_balance` and `used` from the per-asset `locked_balance` — two
  accounting layers, diverging from the OKX treatment (`used = total − free`).
  On the committed recording 35.46 USDC of cross margin
  (`cross_initial_margin_requirement`) is encumbered while `used` reads 0.0.
  Known divergence, deliberately kept: the venue exposes no per-asset
  encumbrance that includes cross margin, and synthesizing `total − free`
  would mix layers the provider keeps separate. Consumers needing encumbrance
  read `info`.
- *`@provider_required_fields` in `lighter_authored_spec_test.exs` is a
  transcription* of the pinned OpenAPI required lists (verified byte-for-byte
  2026-08-14), not a derivation — the artifact is `storage: reference_only`,
  so `mix ccxt.authority_check --online` is the drift guard.

## 2026-08-18 — public WebSocket transport (Task 544)

**C-T544b — Lighter's public stream uses a type/channel subscription envelope with
numeric market indexes (task 544). Outcome: CONFIRM venue.**

- *Exchange semantics:* the provider WebSocket reference publishes mainnet and testnet
  `/stream` URLs and `{"type":"subscribe","channel":"market_stats/{MARKET_INDEX}"}`.
- *Our carve:* raw public subscriptions use the registered `:type_subscribe` pattern.
  Unified watch templates stay explicitly unresolved because the provider requires a
  numeric market index rather than a unified symbol.
- *Live evidence:* testnet returned `connected`, a `subscribed/market_stats` snapshot,
  and continuing `update/market_stats` frames for market 0. An unknown channel returned
  provider error 30005 `Invalid Channel`.

<!-- carve-evidence-status
{"carve_id":"C-T544b","date":"2026-08-18","semantic_source":{"kind":"provider_owned","reference":"https://apidocs.lighter.xyz/docs/websocket-reference"},"observed_evidence":{"kind":"live_venue","reference":"test/bourse/ws/canary_test.exs Lighter testnet success and invalid-channel probes"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-19 — subscribe snapshot is caller-visible (Task 638)

**C-T638 — Lighter's first `subscribed/*` frame is the snapshot, not a disposable
ack (task 638). Outcome: CONFIRMED venue.**

- *Exchange semantics:* the [provider WebSocket reference](https://apidocs.lighter.xyz/docs/websocket-reference)
  publishes `subscribed/{channel}` as the subscribe response carrying the current
  snapshot (candles document this explicitly: **Response Structure (Subscribe)** vs
  **Response Structure (Updates)**). Later frames are `update/{channel}`. An unknown
  channel is a provider error object (`code` 30005, `Invalid Channel`).
- *Our carve:* default `Bourse.WS.subscribe/3` (ack wait enabled) returns `:ok` and
  re-queues the `subscribed/*` snapshot so the caller mailbox still receives it.
  `update/*` stays data (`:not_ack`). An invalid channel stays
  `{:error, {:subscription_rejected, frame}}`.
- *Live evidence:* testnet `market_stats/0` on `wss://testnet.zklighter.elliot.ai/stream`
  accepts with a `subscribed/market_stats` snapshot after default subscribe; an
  unknown channel still returns 30005.

<!-- carve-evidence-status
{"carve_id":"C-T638","date":"2026-08-19","semantic_source":{"kind":"provider_owned","reference":"https://apidocs.lighter.xyz/docs/websocket-reference"},"observed_evidence":{"kind":"live_venue","reference":"test/bourse/ws/canary_test.exs Lighter testnet default-subscribe snapshot and invalid-channel probes"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-19 — unified account facts (Task 648)

**C-T648f — Lighter account class, account trading mode, and position margin mode remain independent facts (task 648). Outcome: CONFIRM venue.**

The account response owns `account_type`, `account_trading_mode`, and each position's
`margin_mode`. The unified read keeps the three provider classifications separate,
retains account/symbol identity on repeated rows, and preserves the full body in
`info`.

<!-- carve-evidence-status
{"carve_id":"C-T648f","date":"2026-08-19","semantic_source":{"kind":"provider_owned","reference":"Lighter GET /api/v1/account response schema: account_type, account_trading_mode, positions[].margin_mode"},"observed_evidence":{"kind":"live_venue","reference":"test/bourse/account_facts_integration_test.exs Lighter testnet account classification field pins 2026-08-19"},"compatibility_reference":null,"resolved_tier":1}
-->
