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

**C-T451d — WebSocket support is explicitly absent (task 451). Outcome: DIVERGE from reference subscription shapes.**

- *Exchange semantics (non-CCXT):* Lighter publishes WebSocket channels, but no channel was live
  subscribed and adjudicated by this task.
- *Our carve + rationale:* every owned WebSocket slot is marked `supported=false`; no WebSocket
  capability is advertised from generated/reference plumbing.

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
methods use the venue-owned history endpoints (task 546). Outcome: CONFIRM provider contract.**

- *Exchange semantics:* `GET /api/v1/account` returns account `assets` and `positions` in one
  response. The provider OpenAPI defines the account-scoped trade, deposit, withdrawal, transfer,
  and liquidation history responses under their corresponding endpoints.
- *Our carve:* `fetchBalance` parses `accounts[0].assets`, while `fetchPositions` parses
  `accounts[0].positions`. The five account histories map to their matching provider operations.
  All account-scoped reads derive the account index from the exchange credentials. Deposit and
  withdrawal transaction timestamps are parsed as milliseconds: the live deposit response carried
  13-digit millisecond values despite the shorter example value in the provider schema.
- *Funding distinction:* `fetchFundingRateHistory` maps to `GET /api/v1/fundings`, Lighter's own
  market funding history. `GET /api/v1/funding-rates` is a cross-exchange reference feed and is
  deliberately not a unified funding source.
- *Verification:* committed recordings under `test/fixtures/responses/lighter/` cover each of the
  eight newly mapped methods. The tagged integration test repeats all eight unified calls against
  `testnet.zklighter.elliot.ai` and requires real credentials rather than skipping.

<!-- carve-evidence-status
{"carve_id":"C-T546","date":"2026-08-11","semantic_source":{"kind":"provider_owned","reference":"priv/authority/lighter/manifest.json artifact rest-openapi; account, trades, deposit/history, withdraw/history, transfer/history, liquidations, fundings and funding-rates operations"},"observed_evidence":{"kind":"live_venue","reference":"testnet HTTP/code 200 recordings for fetch_balance, fetch_positions, fetch_my_trades, fetch_deposits, fetch_withdrawals, fetch_transfers, fetch_my_liquidations and fetch_funding_rate_history under test/fixtures/responses/lighter; pinned by test/bourse/lighter_promotion_integration_test.exs"},"compatibility_reference":null,"resolved_tier":1}
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
