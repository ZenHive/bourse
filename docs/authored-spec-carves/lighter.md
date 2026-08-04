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
