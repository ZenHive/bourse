# Prod-Verification Ledger — deferred tier-1 confirmations

Deferred live confirmations that our current keys/hosts **cannot falsify**: the slice is
landed and green at tier 2 (a pinned third-party extraction / provider docs), but the tier-1 confrontation against the
real venue needs production keys or real market state we don't have yet. When such keys/state
become available, work this file top-to-bottom; move closed entries to the "Closed" section
with the observed evidence.

**Append rule (reviewers & orchestrator):** any reviewer concern of the class "not reachable
with our keys / needs prod / needs real position" gets an entry here — in the review's
worktree, riding the deliverable — instead of a vague concern that dies with the run record.
Never write key material or secrets into this file.

Entry template:

```
### <venue> — <method(s)> (task <id>, filed YYYY-MM-DD)
- Authored slices: `<venue>:<canonical slot path>` (omit only when the entry is not about an authored field-map, sign-recipe, error-map, or symbol-pattern slot)
- Blocked by: <what's missing: prod key with X perms / funded position / …>
- The open question: <the semantic fact only the live call can falsify>
- Exact call: <copy-paste eval, minus creds>
- Expected evidence: <what the live response must show to CONFIRM>
```

## Open

### eleven venues — sandbox-unhosted REST-read product surfaces (task 667, filed 2026-08-23)

- Authored slices: runtime `fetch*` branches whose provider operation is not on the venue's
  testnet/demo product (`papi`, `sapi`, `eapi*`, `fapi*`/`dapi*` on the spot module, and the
  inverse of that on USD-M / COIN-M)
- Blocked by: the provisioned sandbox hosts do not publish those API sections (`No base URL
  for section … (sandbox)` live, or they require production keys)
- What the live contract lane covers: the venue-native prefixes in
  `priv/venues/<venue>/authority/rest_read_contract.json` (`provider_operation_prefixes`)
- The open question: production-host semantics for the omitted sections
- Exact call: construct the venue on its production host with production-authorized
  credentials, then run the omitted provider operations
- Expected evidence: accepted production responses whose meaning matches the provider docs

> **OKX routing:** all remaining OKX probes use the international entity
> (`www.okx.com`) and `OKX_INTL_*` credentials. References to `my.okx.com` below are
> historical negative evidence only, never the target for a new probe.

### binance family — production-only SAPI/EAPI reads (task 570, filed 2026-08-19)

- Authored slices: `binance:capabilities.verification.fetchMyDustTrades`,
  `fetchIsolatedBorrowRates`, `fetchOptionPositions`; the same three paths in
  `binanceusdm`
- Blocked by: the Spot testnet and USD-M demo hosts do not serve the production SAPI and
  EAPI account surfaces. The provisioned keys therefore cannot confront these six reads.
- The open question: the production response envelopes and whether the incomplete authored
  mappings normalize every returned variant.
- Exact call: construct `binance` and `binanceusdm` exchanges with production hosts and
  production-authorized credentials, then call each of `fetch_my_dust_trades/1`,
  `fetch_isolated_borrow_rates/1`, and `fetch_option_positions/1`.
- Expected evidence: accepted production responses registered against all six methods, with
  populated rows where the account has relevant history or positions.

### binance — cross-product position joins (task 570, filed 2026-08-19)

- Authored slices: `binance:capabilities.verification.fetchAccountPositions`,
  `fetchPositionsRisk`
- Blocked by: the available product accounts do not carry a populated cross-product position
  that can prove the required account/position and leverage-response join.
- The open question: the joined normalized result across populated Spot/Portfolio/Futures
  account state.
- Exact call: on an account with a populated cross-product position, call
  `Bourse.fetch_account_positions/1` and `Bourse.fetch_positions_risk/1`.
- Expected evidence: registered responses for both source routes and a normalized result whose
  position and leverage members reconcile to those responses.

### okx — deposit and withdrawal record reads (task 570, filed 2026-08-19)

- Authored slices: `okx:capabilities.verification.fetchDeposit`, `fetchWithdrawal`
- Blocked by: the international demo account has no deposit or withdrawal history, so it
  cannot supply the required transaction identifier.
- The open question: the populated response envelope and complete normalized record mapping.
- Exact call: on an account with matching history, call `Bourse.fetch_deposit/2` with a deposit
  identifier and `Bourse.fetch_withdrawal/2` with a withdrawal identifier.
- Expected evidence: accepted populated responses registered for both methods, retaining the
  provider identifier and status semantics.

### deribit — account-wide and position-moving mutations (task 558, filed 2026-08-14)

- Authored slices: none — this entry is about raw provider operations, not an authored field-map slot
- Operations: `private/cancel_all`, `private/cancel_all_by_currency`, `private/cancel_all_by_currency_pair`,
  `private/cancel_all_by_instrument`, `private/cancel_all_by_kind_or_type`, `private/cancel_quotes`,
  `private/cancel_all_block_rfq_quotes`, `private/close_position`, `private/move_positions`, `private/mass_quote`
- Blocked by: a testnet account nobody else is using. Bulk cancellation reaches resting orders this session did
  not place, and the provider offers no operation that restores a cancelled order or a closed position.
- What is already known: the provider's own description for each of these lives in the pinned `api-openapi`
  revision recorded in `priv/venues/deribit/authority/manifest.json`, and the per-order lifecycle
  (`private/buy` → `private/cancel`) is verified live.
- The open question: the accepted request shape and the response body each bulk form returns, which only a live
  call on an isolated account can show.
- Exact call: none — these stay `evidence=unverified`, `reachability=unsafe` until an isolated testnet account
  exists. They are never sent for coverage on the shared key.
- Expected evidence: a registered lifecycle capture on an isolated account whose setup created every order the
  bulk form is allowed to reach.

### deribit — value-moving wallet and transfer mutations (task 558, filed 2026-08-14)

- Authored slices: none — raw provider operations
- Operations: `private/withdraw`, `private/cancel_withdrawal`, `private/submit_transfer_to_user`,
  `private/submit_transfer_to_subaccount`, `private/submit_transfer_between_subaccounts`,
  `private/cancel_transfer_by_id`
- Blocked by: nothing technical — this is a standing refusal. Value movement is never sent for coverage, on
  testnet or anywhere else, and the cancel forms only become reachable after creating the transfer they cancel.
- What is already known: the provider's own descriptions, in the pinned `api-openapi` revision recorded in
  `priv/venues/deribit/authority/manifest.json`.
- The open question: unanswerable without moving funds; it stays open by decision, not by blocker.
- Exact call: none.
- Expected evidence: none will be produced. These remain `evidence=unverified`, `reachability=unsafe`
  permanently unless a venue-provided dry-run form appears.

### deribit — API-key credential mutations (task 558, filed 2026-08-14)

- Authored slices: none — raw provider operations
- Operations: `private/create_api_key`, `private/remove_api_key`, `private/reset_api_key`,
  `private/enable_api_key`, `private/disable_api_key`, `private/edit_api_key`, `private/change_api_key_name`,
  `private/change_scope_in_api_key`
- Blocked by: a disposable testnet account. These mutate the credential the whole suite authenticates with, and
  `private/create_api_key` returns a live secret in its response body, which must never be committed.
- What is already known: the provider documents the effect of each form; `private/remove_api_key` is documented
  as not undoable.
- The open question: the response shape of each form, and whether the secret-bearing fields can be redacted
  without destroying the semantic evidence.
- Exact call: none on the shared key.
- Expected evidence: captures taken on a throwaway testnet account whose key is rotated afterwards, with the
  secret-bearing members masked before anything is written down.

### deribit — persistent account, subaccount and member mutations (task 558, filed 2026-08-14)

- Authored slices: none — raw provider operations
- Operations: `private/create_subaccount`, `private/remove_subaccount`, `private/change_subaccount_name`,
  `private/set_email_for_subaccount`, `private/toggle_subaccount_login`,
  `private/toggle_notifications_from_subaccount`, `private/set_disabled_trading_products`,
  `private/change_margin_model`, `private/enable_affiliate_program`, `private/set_email_language`,
  `private/set_member`, `private/delete_member`, `private/set_clearance_originator`,
  `private/set_announcement_as_read`, `private/set_self_trading_config`, `private/set_mmp_config`,
  `private/reset_mmp`, `private/create_combo`
- Blocked by: an account whose configuration nothing else depends on. Each change outlives the session, several
  have no scoped inverse (`set_announcement_as_read` cannot be undone; `create_combo` publishes a venue-wide
  instrument), and `set_email_for_subaccount` sends mail to a real address.
- What is already known: the provider's description of each form, recorded in the adjudication register.
- The open question: the accepted parameter set and response body of each configuration form.
- Exact call: none on the shared key.
- Expected evidence: captures on a disposable testnet account, each paired with the read that shows the prior
  configuration restored.

### deribit — persistent wallet address-book mutations (task 558, filed 2026-08-14)

- Authored slices: none — raw provider operations
- Operations: `private/add_to_address_book`, `private/remove_from_address_book`,
  `private/update_in_address_book`, `private/save_address_beneficiary`, `private/delete_address_beneficiary`,
  `private/create_deposit_address`
- Blocked by: a disposable account. Address-book state is the allow-list a withdrawal draws from, so writing to
  it for coverage is withdrawal-adjacent even though no funds move.
- What is already known: the provider documents these as the compliance surface behind `private/withdraw`.
- The open question: the accepted address and beneficiary shapes, and what a deposit address response contains.
- Exact call: none on the shared key.
- Expected evidence: captures on a disposable account, with address and beneficiary members masked.

### deribit — Block RFQ and block-trade counterparty mutations (task 558, filed 2026-08-14)

- Authored slices: none — raw provider operations
- Operations: `private/create_block_rfq`, `private/add_block_rfq_quote`, `private/edit_block_rfq_quote`,
  `private/cancel_block_rfq`, `private/cancel_block_rfq_quote`, `private/cancel_block_rfq_trigger`,
  `private/accept_block_rfq`, `private/verify_block_trade`, `private/execute_block_trade`,
  `private/approve_block_trade`, `private/reject_block_trade`, `private/invalidate_block_trade_signature`
- Blocked by: a second, cooperating testnet account. These operations are visible to counterparties on the shared
  testnet venue and can be filled or acted on by another party before any cleanup runs.
- What is already known: the provider documents the two-party workflow and which role each form belongs to.
- The open question: the accepted request and response of each half of the maker/taker workflow.
- Exact call: none on a single key.
- Expected evidence: paired captures from two coordinated testnet accounts covering one full RFQ or block-trade
  workflow including its cancellation.

### deribit — REST-unreachable WebSocket-session mutations (task 558, filed 2026-08-14)

- Authored slices: none — raw provider operations
- Operations: the ten operations the OpenAPI tags `WebSocket Only`, plus `private/enable_cancel_on_disconnect`
  and `private/disable_cancel_on_disconnect`, which the provider's prose declares WebSocket-only *without*
  carrying the tag
- Blocked by: transport. These configure or address a WebSocket connection, and a REST request has none.
- What is already known: the provider states the restriction in its own description; the tag set (10) and the
  prose-declared set disagree — the register substantiates two operations (`private/enable_cancel_on_disconnect`,
  `private/disable_cancel_on_disconnect`) that the prose declares WebSocket-only without carrying the tag — so the
  OpenAPI tag alone under-reports which current-REST paths are unreachable.
- The open question: nothing reachable over REST. They stay in the 182-operation current-REST denominator as
  `reachability=unreachable` rather than being deleted from it.
- Exact call: none over REST.
- Expected evidence: WebSocket-transport evidence, owned by the WebSocket contract surface, not by current REST.

### deribit — session credential issuance (task 558, filed 2026-08-14)

- Authored slices: none — raw provider operations
- Operations: `public/auth`, `public/exchange_token`, `public/fork_token`
- Blocked by: nothing technical — this is a redaction refusal. Each response body *is* a bearer token, so a
  committed capture would commit credential material.
- What is already known: the provider documents all three as token-issuing forms.
- The open question: whether a redaction that masks the token members leaves enough for the capture to still be
  semantic evidence, or whether it degrades to reachability-only.
- Exact call: none until that redaction question is answered.
- Expected evidence: a capture whose token members are masked and whose remaining members still carry the
  scope/expiry semantics the operation is being verified for.

### binance — populated margin-adjustment history row (task 568, filed 2026-08-09)
- Authored slices: `binance:normalization.field_maps.margin_modification` (intentionally
  absent while the task-550 coverage cell remains open).
- Blocked by: the provisioned USD-M demo account returned `[]` for
  `fapi/v1/positionMargin/history` across BTC, ETH, SOL, XRP, BNB, ADA, and DOGE. Producing a
  row requires an isolated position plus an add/reduce-margin mutation.
- The open question: does a populated demo row preserve the documented amount, currency,
  add/reduce type, and millisecond event time through the unified parser?
- Exact call: after an operator-approved isolated-position margin adjustment, call
  `Bourse.fetch_margin_adjustment_history(ex, "BTC/USDT:USDT", limit: 10)` on
  `demo-fapi.binance.com`.
- Expected evidence: freeze and register a populated response; assert the parsed amount,
  currency, type, symbol, and timestamp against the same raw row; author the map and remove
  only the Binance margin-adjustment task-550 coverage cell.

### hyperliquid — populated funding history on testnet (task 568, filed 2026-08-09)
- Authored slices: `hyperliquid:normalization.field_maps.funding_history` (intentionally absent
  while the task-550 coverage cell remains open).
- Blocked by: `info:userFunding` returned `[]` for the provisioned testnet wallet even with
  `startTime: 0`. Producing a row requires holding a perpetual position across an hourly
  funding event.
- The open question: do those fields retain the documented meanings on a populated testnet
  row and normalize to the correct unified symbol and USDC amount?
- Exact call: after a testnet position survives a funding boundary, call
  `Bourse.fetch_funding_history(ex, since: 0)`.
- Expected evidence: freeze and register the populated testnet body; assert its exact id,
  amount, rate, symbol, and timestamp; author the map and remove only the Hyperliquid funding
  task-550 coverage cell.

### okx — populated margin-adjustment bill row (task 568, filed 2026-08-09)
- Authored slices: `okx:normalization.field_maps.margin_modification` (intentionally absent
  while the task-550 coverage cell remains open).
- Blocked by: the international demo account returned no type-6 rows from either the recent or
  archive bills endpoint. Producing one requires an isolated position plus a margin mutation.
- The open question: what signs and resulting position-margin totals do populated subtype
  160/161 demo rows carry?
- Exact call: after an operator-approved isolated-position add/reduce, call
  `Bourse.fetch_margin_adjustment_history(ex, type: "add")` and the matching `"reduce"` read.
- Expected evidence: freeze and register both populated bill rows; assert subtype, signed
  `posBalChg`, resulting `posBal`, currency, margin mode, and timestamp; author the map and
  remove only the OKX margin-adjustment task-550 coverage cell.

### binanceusdm — conversion and currency read field maps on sandbox (task 567, filed 2026-08-08)
- Authored slices: `binanceusdm:normalization.field_maps.conversion` and
  `binanceusdm:normalization.field_maps.currency` (intentionally absent while the five
  task-550 coverage cells remain open).
- Blocked by: the authored `sapi` routes used by `fetchConvertQuote`, `fetchConvertTrade`,
  `fetchConvertTradeHistory`, `fetchConvertCurrencies`, and `fetchCurrencies` have no USD-M
  sandbox base URL. The first, fourth, and fifth stop with the explicit no-base error; the two
  history/status reads currently stop earlier on ambiguous multi-endpoint selection. Direct
  probes of USD-M's native `fapi/v1/convert/exchangeInfo` and `convert/getQuote` returned
  Binance `-1000` / HTTP 500 on both `demo-fapi.binance.com` and the legacy
  `testnet.binancefuture.com` host.
- What live production already proved: the production `sapi` host returned 600 Convert asset
  rows and 729 Wallet currency rows; Convert history returned a successful empty envelope and
  an invalid status id returned Binance's `-1102` parameter error. Those calls establish
  production reachability but cannot supply the sandbox-success observations task 567 requires.
- The open question: which sandbox-supported provider operations supply the five declared
  reads, and do their populated rows retain the production field meanings?
- Exact call: with the provisioned `BINANCE_FUTURES_TEST_*` key, first call
  `Bourse.Binanceusdm.fapiPublic_get_convert_exchangeinfo(ex)` and the non-executing
  `fapiPrivate_post_convert_getquote/2`; after the provider returns success, exercise all five
  unified reads with sandbox mode enabled. Do not accept the quote.
- Expected evidence: successful sandbox bodies for each declared read, including a populated
  conversion history/status row and concrete currency rows; freeze and register each response,
  author both maps from Binance's own contracts, assert the observed domain values, and remove
  only the five Binance USD-M task-550 coverage cells.

### binanceusdm — INSURANCE_CLEAR income row: settlement or liquidation (task 605, filed 2026-08-13)
- Authored slices: `binanceusdm:normalization.field_maps.ledger_entry` (and the shared binance
  family income vocabulary)
- Blocked by: the provider enumerates the `INSURANCE_CLEAR` literal but defines no semantics
  for it, and no such row exists in any account we control. Producing one requires an actual
  forced liquidation on the USD-M demo account — a deliberate loss event outside the standing
  mutation policy for routine probes.
- The open question: is a real `INSURANCE_CLEAR` row the insurance-fund residual after a
  liquidation (→ `settlement` stands) or the liquidation cashflow itself (→ the label must
  diverge to `liquidation`, restoring the cross-venue class with OKX type `5`)?
- Exact call: open an oversized leveraged position on `demo-fapi.binance.com`, let it liquidate,
  then `Bourse.fetch_ledger(ex, limit: 100)` and filter `info["incomeType"] == "INSURANCE_CLEAR"`.
- Expected evidence: one frozen income row plus the surrounding `REALIZED_PNL`/`COMMISSION`
  rows of the same liquidation, confronted in a dated carve amendment to C-T605a.

### binance — documented pending and match-expiry order statuses (task 538, C-T538b, filed 2026-08-04)
- Authored slices: `binance:normalization.field_maps.order.field_map.status`
- Blocked by: the provisioned Spot Testnet history has no registered row carrying
  `PENDING_NEW`, `PENDING_CANCEL`, or `EXPIRED_IN_MATCH`; manufacturing these states requires
  venue-specific matching or cancel-race conditions.
- The open question: do live order-history rows preserve these exact spellings and terminality?
- Exact call: `Bourse.fetch_orders(exchange, "BTC/USDT")` after the account naturally records
  one of the three statuses.
- Expected evidence: raw status spelling plus unified `open` for the pending states and
  `canceled` for `EXPIRED_IN_MATCH`.

### binanceusdm — documented match-expiry order status (task 538, C-T538c, filed 2026-08-04)
- Authored slices: `binanceusdm:normalization.field_maps.order.field_map.status`
- Blocked by: the provisioned demo-fapi history has no registered `EXPIRED_IN_MATCH` row;
  manufacturing one requires a matching-engine expiry condition.
- The open question: does a live history row preserve the spelling and terminal semantics?
- Exact call: `Bourse.fetch_orders(exchange, "BTC/USDT:USDT")` after such a row exists.
- Expected evidence: raw `EXPIRED_IN_MATCH` parses as unified `canceled`.

### derive — documented expired order status (task 538, C-T538d, filed 2026-08-04)
- Authored slices: `derive:normalization.field_maps.order.field_map.status`
- Blocked by: no observed demo history row carries `expired`; producing one requires
  leaving an accepted order active through its expiry boundary.
- The open question: does a live order row use that exact terminal status?
- Exact call: `Bourse.fetch_open_orders(exchange)` after an accepted order expires.
- Expected evidence: raw `expired` parses as unified `canceled`.

### okx — documented MMP-canceled order status (task 538, C-T538e, filed 2026-08-04)
- Authored slices: `okx:normalization.field_maps.order.field_map.status`
- Blocked by: no observed international-demo history row carries `mmp_canceled`;
  producing one requires an account and option flow that trigger market-maker protection.
- The open question: does a live order-history row preserve the spelling and terminal semantics?
- Exact call: `Bourse.fetch_orders(exchange)` after MMP cancels a demo order.
- Expected evidence: raw `mmp_canceled` parses as unified `canceled`.

### okx — Optimism unified network code (task 441, C-T421, filed 2026-07-20)
- Authored slices: `okx:normalization.field_maps.currency`
- Blocked by: the EEA demo host (`my.okx.com`, `sandbox: true`) does not serve
  `GET /api/v5/asset/currencies` at all — attested live 2026-07-20 on the landed base, the venue
  answers business error `50038` "This feature is unavailable in demo trading". The provisioned
  demo keys 401 (`50101`) against the live host, so no reachable host returns okx's own chain
  naming for Optimism with current credentials.
- The open question: does OKX itself name the chain `OP` (venue-code shape, matching the sibling
  aliases `ARBONE` / `MATIC` / `ETH` / `BASE` / `LINEA` already in the same authored table), or
  `OPTIMISM`? The carve currently rests on two okx.com help-centre URLs that the task-441
  reviewer could NOT fetch from its environment, plus an in-repo alias-table consistency
  argument. Neither is tier-1: one is an unverified citation, the other is our own convention.
- Exact call: with a live-entitled okx key, `Bourse.fetch_currencies(exchange)` and read the `ETH`
  entry's `networks` keys; equivalently `GET /api/v5/asset/currencies` and read the `chain`
  field for the Optimism row (okx returns `chain` as `"ETH-Optimism"`-style strings — the
  question is which short code the venue's own docs/UI bind to it).
- Expected evidence: okx's own response or documentation showing the chain short code. If it
  reads `OP`, the carve is confirmed and the citation is replaced with the observed source. If it
  reads `OPTIMISM`, our table was right and the CCXT 4.5.65 compatibility note must be re-annotated
  `deliberate_divergence: true` — i.e. task 441's change should be reverted.

### Binance COIN-M — fetchPositions value axes (task 334, filed 2026-07-19)
- Authored slices: `binance:normalization.field_maps.position`
- Blocked by: the provisioned `BINANCE_FUTURES_TEST_*` key can read the COIN-M dapi
  position-risk endpoint (`[]`), but its COIN-M account endpoint returns Binance business error
  `-2015` / HTTP 401 (invalid API-key, IP, or permissions). It cannot fund or open a COIN-M
  testnet position.
- The open question: on a funded COIN-M testnet or production account, whether a live inverse
  position's loaded market contract size, absolute `notionalValue`, initial/maintenance margin,
  and collateral absence/presence retain the authored meanings through an open/read/close cycle.
- Exact call: construct `Bourse.Exchange.new!("binance", credentials: creds, sandbox: true)`, load
  dapi markets, place and immediately reduce-only-close one minimal BTC/USD or ETH/USD contract,
  then call `Bourse.fetch_positions(exchange, type: "inverse")` and the same call with an invalid
  symbol.
- Expected evidence: one nonzero inverse row whose `contract_size` equals its loaded market,
  `notional == abs(info["notionalValue"])`, margins remain separate, cleanup leaves no nonzero
  position, and the invalid-symbol call reaches Binance's relevant business error. Until then
  this family remains tier-2-labelled.

### derive (testnet) — option ATM fill + settlement semantics (task 403, filed 2026-07-19)
- Authored slices: `derive:normalization.field_maps.trade`
- Blocked by: every nearest-ATM ETH option book (32 instruments across 8 expiries) was
  `bid 0x0 / ask 0x0` and ETH-PERP one-sided at attestation time — no fill is possible on
  this demo market state.
- The open question: a real fill (trade row, fee semantics, position row) plus hedge where
  collateral allows, and full unwind.
- Exact call: task-403 protocol via the hand-signed `sign_order/2` path (unified write path
  is task 379) when the testnet books show two-sided ATM liquidity.
- Expected evidence: filled order id + trade history row, position row, then 0 open orders /
  0 positions after unwind.
- Re-attested 2026-07-23 (task 407 convergence audit): book still empty — 52 option
  instruments discovered, 0 two-sided (`observed_at 1784812661779`). The order lifecycle is
  now proven through the **unified** write path (no hand-signing needed): `Bourse.create_order`
  buy 2 @ 0.1 on `ZEC/USDC:USDC-260925-800-P` → order `9f2afe87-c2c4-46ea-affd-8ae5183e251f`
  `open`, read back via `fetch_open_orders` (`fetch_order` is `:not_supported` on derive),
  cancel → `canceled`, 0 open orders after. Entry stays open solely for the fill/hedge/unwind
  confirmation; task 407 converged derive via this ledger deferral.
- Expected evidence extended (task 506 review, 2026-07-23): when the fill lands, also freeze
  the **populated** `fetch_positions` payload (with market_context) so the
  `instrument_type=option` position carve and derive contracts-unit semantics (C-T506d,
  currently deferred on a shape-only empty body) are pinned by a populated live row — assert
  the unified option symbol and contracts against the observed amount.

### deribit — populated linear position margin units (task 603, C-T603f, filed 2026-08-12)
- Authored slices: `deribit:normalization.field_maps.position.field_map.initialMarginPercentage`
  and `maintenanceMarginPercentage`
- Blocked by: authenticated testnet `private/get_positions` calls for both `USDC` and `USDT`
  returned empty lists. Producing a populated row requires opening a linear position.
- The open question: which provider fields establish initial- and maintenance-margin fractions
  for a populated USDC/USDT linear position, where margin is quote-denominated and
  `size_currency` is base size?
- Exact call: with a reversible linear testnet position open, run
  `Bourse.fetch_positions(ex, code: "USDC")` and preserve the raw row plus its loaded market.
- Expected evidence: register the populated response and assert each emitted margin percentage
  against a provider-owned same-unit identity. If the response exposes no such identity, both
  unified percentage fields remain nil for linear instruments.

### deribit — fetchTradingFees populated schedule (task 380, filed 2026-07-19)
- Authored slices: `deribit:normalization.field_maps.trading_fees`
- Blocked by (re-confronted 2026-07-22, task 468): the signed testnet route is reachable, but
  this account has no fee discount. A fresh
  `private/get_account_summary?currency=BTC&extended=true` call returned `currency=BTC` and
  omitted both `fee_group` and the optional `fees` field. Deribit's current endpoint
  documentation says `fees` is available only when `extended=true` **and the user has
  discounts**. `DERIBIT_CLIENT_ID` resolves to the same provisioned testnet key, and no separate
  production or discounted credential is available. The 2026-07-21 UTC capture of that
  no-discount body went away with the replay lane; the parse it exercised returned an
  empty map instead of inventing a schedule.
- What tier-1 already proved: signed routing, `currency=BTC`, `extended=true`, the JSON-RPC
  result envelope, and the no-discount/field-absent branch were all observed on a real body.
- Provider-contract confrontation (2026-07-22): Deribit's schema version `2.1.1`, identified by
  `priv/venues/deribit/authority/manifest.json`, defines `fees` as
  `index_name -> instrument_type -> default.{type,maker,taker}` plus optional `block_trade`.
  This DIVERGES from C-T380a's authored legacy `fees[]` / `instrument_type` / `maker_fee` /
  `taker_fee` carrier; CCXT 4.5.65 still expects that legacy list and is only a compatibility
  cross-check. The slice therefore remains explicitly **tier 2 / authored**.
- The open question: does a current discounted account return the documented nested value, and
  how should each index/instrument/default object map to the applicable loaded markets and to
  `%Bourse.TradingFee{maker, taker, percentage, tier_based, info}`? A populated live body remains
  necessary before changing the parser.
- Exact call: on a discounted testnet or production account,
  `Bourse.fetch_trading_fees(ex)` after `Bourse.load_markets(ex)`; retain the raw extended account
  summary and compare the same fee carriers to every parsed `%Bourse.TradingFee{}`.
- Expected evidence: retain a populated raw `fees` value, then compare **every** parsed
  `%Bourse.TradingFee{}` field-by-field against its exact index/instrument/default source:
  symbol-to-market applicability, maker, taker, fee type/percentage semantics, tier-based flag,
  and raw `info`. The parsed map must contain no symbol whose fee cannot be traced to that same
  body.

### okx — populated funding-account asset-bills row (task 601, filed 2026-08-12)
- Authored slices: `okx:normalization.field_maps.ledger_entry.route_field_maps.asset/bills`
- Blocked by: the provisioned international demo account returned `code: "0", data: []` from
  the signed funding-account call. Producing a row requires a real demo deposit, withdrawal, or
  account transfer not authorized by this task.
- The open question: whether a populated international-demo asset bill preserves those documented
  type meanings and the signed balance change through the unified parser.
- Exact call: `Bourse.Unified.raw_call(ex, :fetch_ledger, %{"type" => "funding", "limit" => 100})`
  with an OKX international demo exchange (`sandbox: true`). This exact call returned the empty
  success on 2026-08-12.
- Expected evidence: freeze one populated `/api/v5/asset/bills` response and compare its `type`,
  `billId`, `ccy`, `balChg`, and `ts` directly with the parsed `%Bourse.LedgerEntry{}`.

### okx — populated trading-account ledger row (task 365, filed 2026-07-19)
- Authored slices: `okx:normalization.field_maps.ledger_entry`
- Blocked by: the provisioned EEA demo account may return an empty
  `GET /api/v5/account/bills` list. Creating a trade merely to manufacture a bill is outside
  the mutation policy; a production or demo account with an existing completed account-bill is
  required.
- What the live call DID confirm (tier 1, 2026-07-19): EEA demo accepts the signed account-bills
  request and returns a successful list envelope; `fetchAccounts` returns a populated account
  configuration row, and `fetchTransfers` returns populated internal-transfer bill rows.
- The open question: whether a current populated **trading-account** bill still uses `bal` as
  the post-change balance and `fee` in the `ccy` currency under this account mode.
- Exact call: `Bourse.fetch_ledger(ex, "USDT", limit: 1)` against an account with a recent
  completed spot trade or account-bill.
- Expected evidence: one nonempty ledger entry where `before + amount == after`, `currency ==
  info["ccy"]`, and `fee.currency == info["ccy"]`. Until then the populated-row branch remains
  tier-2-labelled.

### okx — fetchDepositAddress / fetchDepositAddressesByNetwork (task 389, filed 2026-07-19)
- Authored slices: `okx:normalization.field_maps.deposit_address`
- Blocked by: **the endpoint does not exist in demo trading.** EEA demo (`my.okx.com`,
  `sandbox: true`) answers every `GET /api/v5/asset/deposit-address` with
  `50038 "This feature is unavailable in demo trading"` — an empty `data: []`, not a
  populated row. A production key with *read* permission on the funding account is
  required; no funded state or withdrawal permission is needed.
- What the live call DID confirm (tier 1, 2026-07-19): the signed request is accepted and
  routed — OKX answers with a *business* error (50038), not `401`/`50111` (bad signature),
  so auth, host, and the `x-simulated-trading` header are correct. Pinned in
  `test/live/okx/okx_demo_integration_test.exs`.
- The open question: whether native `ccy` is accepted with code 0 on this endpoint (C-T484a),
  plus the **field semantics of a populated row** — specifically (a) that `addrEx.comment`
  is the memo carrier for TON-family currencies and that `tag`/`pmtId`/`memo` take precedence
  over it, and (b) that a currency whose chain is absent from the authored alias table really
  does surface with `network: nil` (carve C-T389c) rather than some other OKX-side code. These
  remain authored from OKX's documented schema plus CCXT compatibility evidence, i.e. tier 2.
- Exact call (production key, funding-account read scope):
  ```elixir
  creds = Bourse.Credentials.new!(api_key: ..., secret: ..., password: ...)
  {:ok, ex} = Bourse.Exchange.new("okx", credentials: creds)
  Bourse.Okx.private_get_asset_deposit_address(ex, %{"ccy" => "USDT"})
  Bourse.fetch_deposit_addresses_by_network(ex, "USDT")
  Bourse.fetch_deposit_address(ex, "TON")   # the addrEx.comment carrier
  ```
- Expected evidence: code 0 with the requested `ccy`, and a populated `data` array with at least two rows sharing one `chain`
  and differing `selected` flags (proves the stale-row filter matters on real data), and a
  TON row carrying `addrEx.comment` with no top-level `tag`/`pmtId`/`memo` (proves the
  fallback order). Until then the slice stays **tier-2-labelled**.

### alpaca, coinbaseexchange, okx — zero-param signed JSON POST body (task 374, filed 2026-07-19)
- Blocked by: the question is only decidable on a host that accepts a signed
  zero-param private POST. okx answered it live — `{}` is required and a bodyless
  request is rejected — which is the reverse of the original fear; alpaca and
  coinbaseexchange have no reachable signed zero-param read to repeat it on.
- The open question: does a signed zero-param private POST accept `{}`, or reject
  it before business validation? We always send and sign `{}`.
- Exact call: issue the same authenticated zero-param private POST twice — once
  bodyless (signing without the body) and once with `{}` (signing with it) — and
  compare. Pick a POST whose required params are absent so validation fails
  harmlessly; zero params cannot create an order.
- Expected evidence: both HTTP statuses and exchange responses. Only a body-shape
  rejection of `{}` that a bodyless request avoids would justify an authored
  `json_when_present` contract value.

### okx — populated funding-payment history and status error surface (task 388, filed 2026-07-19)
- Authored slices: `okx:normalization.field_maps.funding_history`
- Blocked by: the provisioned EEA demo key has no funding-payment bill rows. Its signed
  `fetchFundingHistory(BTC/USDT:USDT)` call succeeds with `[]`; creating a funding event needs an
  open perpetual position across a funding settlement and is outside the standing no-mutation
  policy. The zero-argument public system-status endpoint has no parameter whose invalid value can
  produce a venue business error without changing an exchange-wide state.
- The open question: does a current populated funding bill still use `balChg` as the payment amount
  and `ts` as the event time, and does the status endpoint emit a nonzero business envelope during
  a real maintenance/degradation event?
- Exact call: against a production or demo account with a settled perpetual funding payment,
  `Bourse.fetch_funding_history(ex, "BTC/USDT:USDT", limit: 1)`; during an official OKX status
  incident, `Bourse.fetch_status(ex)` and retain the returned body.
- Expected evidence: one nonempty `FundingHistory` row whose id/amount/currency/timestamp equal
  `billId`/`balChg`/`ccy`/`ts` in the same raw row; a nonzero status code remains a typed error and
  never becomes `%{status: "ok"}`.
- Also unreachable — a **populated status maintenance window**. OKX only emits `data` rows during a
  scheduled or ongoing maintenance event, which cannot be summoned on demand, and the CCXT static
  the normal empty-data envelope carries `data: []`. The per-row branch (C-T388d: `ongoing` → `maintenance`, other
  states → `ok`, `eta` from `end`, `url` from `href`) is therefore authored from the OKX schema and
  pinned by offline unit tests only. Close this entry by capturing `Bourse.fetch_status(ex)` during
  the next announced OKX maintenance window and confirming the row fields and resolved status.

### okx — place/cancel order lifecycle on a trade-enabled host (task 363, C-T363, filed 2026-07-18)
- Authored slices: `okx:normalization.field_maps.order`
- Blocked by: an OKX key/host outside the EEA local-compliance restriction. EEA demo
  (`my.okx.com`) accepts the signed, shaped `POST /api/v5/trade/order` request but returns its
  per-operation error row with `sCode: 51155` before an order can rest (observed 2026-07-18).
- The open question: does a current successful place acknowledgement remain sparse, and does its
  subsequent order-details row preserve `cTime`, `uTime`, `fillTime`, `state`, `sz`, and
  `accFillSz` with the documented meanings?
- Exact call: place a far-from-market post-only `BTC-USDT` demo/prod order through
  `Bourse.create_order(ex, "BTC/USDT", "limit", "buy", amount, price: far_price, postOnly: true)`,
  fetch it with `Bourse.fetch_order(ex, id, symbol: "BTC/USDT")`, then always
  `Bourse.cancel_order(ex, id, symbol: "BTC/USDT")` in `after` cleanup.
- Expected evidence: place acknowledgement has `ordId`/`clOrdId`/`sCode`/`sMsg` without invented
  order fields; fetch returns a populated live row; cancel succeeds (or a typed order-not-found
  error if the order filled before cleanup).
- Re-confirmed 2026-07-19 (task 385 review): with the singular `trade/order` routing and authored
  body in place, both `BTC/USDT` (spot) and `BTC/USDT:USDT` (swap) far-from-market limit creates
  reach `sCode: 51155` — the venue parses the body and rejects on compliance policy, so the
  malformed-body `50002` is gone. A *successful* place (code 0 + `ordId`) stays unreachable on
  this key, so the create/amend slices remain tier-2-labeled until this entry closes.

### okx — fetchCurrencies fee/precision rollup on `/api/v5/asset/currencies` (task 311, C-T311, filed 2026-07-18)
- Authored slices: `okx:normalization.field_maps.currency`
- Blocked by: prod okx key (read suffices) — the endpoint is demo-unavailable: live EEA demo (`my.okx.com`) returns "This feature is unavailable in demo trading" (typed exchange_error, observed 2026-07-18; carve register C17a).
- The open question: does a *current* live payload still carry `canWd: false` rows with lower `fee` than any withdrawable route (i.e. does the divergence stay material), and is `wdTickSz` still the withdrawal precision source?
- Exact call: `Bourse.fetch_currencies(ex)` against `www.okx.com`; slice BTC: per-chain `canWd`/`fee`/`wdTickSz` vs unified `fee`/`precision`.
- Expected evidence: unified `fee == min(fee over canWd: true rows)` recomputed from the same live payload; `networks` map retains every chain row.

### bybit — fetchTransfers `coin=` / fetchConvertTrade `quoteTxId=` semantics (task 313, filed 2026-07-17; extended for task 347 / C-T347, 2026-07-18)
- Blocked by: a populated transfer row plus enough convertible balance for a real quote. The
  write-enabled production key was confirmed live on 2026-07-23; `coin=USDT` returned `retCode
  0` with an empty list, while a non-executing 1 USDT → USDC quote reached balance validation
  and returned "Available Balance is insufficient". No conversion was executed.
- The open question: does Bybit prod actually accept and *filter by* `coin=USDT` on `/v5/asset/transfer/query-inter-transfer-list`, echo `quoteTxId` on convert-trade lookup — and does `POST /v5/asset/exchange/convert-execute` accept a real (fresh, unexpired) `quoteTxId` as its only body field?
- Exact call: `Bourse.fetch_transfers(ex, code: "USDT", params: %{"limit" => 5})`, `Bourse.fetch_convert_trade(ex, "<real quoteTxId>")`, and `Bourse.fetch_convert_quote(ex, "USDT", "BTC", 10)` → `Bourse.create_convert_trade(ex, quote.id, "USDT", "BTC", 10)` against `api.bybit.com` (tiny amount; convert is a swap, not an order — venue-final).
- Expected evidence: `retCode 0`; transfer rows all `coin == "USDT"`; convert lookup echoes the requested `quoteTxId`; convert-execute returns `retCode 0` with the same `quoteTxId` echoed (or a quote-expired business error — either proves the binding is read by the venue).
- Update (2026-08-24, superseding the same-day 10024 note): the convert-execute half is
  answered on testnet — `POST /v5/asset/exchange/convert-execute` with `quoteTxId` as the
  only body field returned `retCode 0` (`exchangeStatus: processing`) and the executed row
  appeared in convert history with the same id. The earlier 10024 on that endpoint was
  transient provisioning lag on the fresh AI sub-account. Residual open question: the
  `fetchTransfers` `coin=` filter semantics against a populated production transfer row.

### binance — capital deposit/withdraw transaction histories and apply acknowledgement (task 335, filed 2026-07-18)
- Authored slices: `binance:normalization.field_maps.transaction`
- Blocked by: a populated production history row and an explicitly approved withdrawal target.
  The production key reached both history endpoints on 2026-07-23, but both returned empty lists;
  withdrawals remain disabled on the key and no apply mutation was attempted.
- The open question: do current production rows retain the documented status vocabulary, `insertTime`/`applyTime` meanings, `transactionFee` ownership, and sparse `{id}` apply acknowledgement shape?
- Exact call: `Bourse.fetch_deposits(ex, code: "USDT")`, `Bourse.fetch_withdrawals(ex, code: "USDT")`, then an operator-approved minimal `Bourse.withdraw(ex, "USDT", amount, address, tag: tag, network: "TRC20")` against `api.binance.com`.
- Expected evidence: a non-empty history row proves every mapped field against one live payload; a deliberately invalid signed read or apply request produces a typed Binance error; a successful apply acknowledgement supplies only `id` until its history row becomes available.

### binance — `asset/dust` single-field execution confirmation (task 349, C-T349, filed 2026-07-23)
- Authored slices: `binance:auth.sign_recipe.sapi`
- Blocked by: explicit approval for a venue-final dust conversion plus Spot & Margin Trading
  permission on the production key. The key reported that permission disabled on 2026-07-23.
- What provider authority proved: Binance's current Dust Transfer contract defines one string
  field and uses `asset=BTC,USDT`; offline signing and full Dispatch tests pin the exact
  `/asset/dust` dialect without changing ordinary JSON-array queries.
- What live traffic proved: signed `/asset/dust-btc` preview returned eligible ADA and EUR
  rows. No `/asset/dust` mutation was sent.
- The open question: does production accept the URL-encoded single field
  `asset=ADA%2CEUR` under a trade-enabled key and return the documented `tranId` envelope?
- Exact call: preview again, choose only operator-approved assets, then call
  `Bourse.Binance.sapi_post_asset_dust(ex, %{"asset" => ["ADA", "EUR"]})` once and compare the
  returned `transferResult` with post-call dust history. There is no amount cap.
- Expected evidence: HTTP 200, one `tranId`, and result rows only for the named assets; the
  request carries one decoded `asset` field, never repeated keys or a JSON array.

### binance — borrow-interest requests/responses and Convert quote response (tasks 323/452, filed 2026-07-21)
- Authored slices: `binance:normalization.field_maps.borrow_interest`, `binance:normalization.field_maps.conversion`
- Blocked by: populated margin-interest state plus a production key authorized for Portfolio
  Margin and Convert. On 2026-07-23 the production cross-margin call was accepted but empty;
  isolated margin reached the venue and returned "Isolated margin account does not exist";
  Portfolio Margin and the non-executing Convert quote were rejected for missing permission.
- What live traffic DID confirm (tier 1, 2026-07-21): public EAPI `GET /eapi/v1/mark` returned
  current option rows and the unified call normalized them into symbol-keyed Greeks. The Task
  452 single-symbol request sent `symbol=BNB-260722-515-C` and was accepted; the same shaped
  path with `BTC-991231-999999-C` returned Binance `-1121`. This closes C-T323b/C-T452a but
  supplies no signed evidence for the authenticated families.
- The open question: do current populated production interest rows retain the documented
  `principal`/`interest`/`interestRate` semantics, and does a funded Convert quote preserve
  `ratio` as the forward quote rate while omitting the two asset codes from its response?
- Exact call: with a read-capable production key, call all three request shapes:
  `Bourse.fetch_borrow_interest(ex, code: "USDT", limit: 1)`,
  `Bourse.fetch_borrow_interest(ex, code: "USDT", symbol: "BTC/USDT", limit: 1)`, and
  `Bourse.fetch_borrow_interest(ex, code: "USDT", limit: 1, portfolioMargin: true)`. With an
  operator-approved small quote window, call `Bourse.fetch_convert_quote(ex, "USDC", "USDT", 5)`
  without accepting it.
- Expected evidence: one `%Bourse.BorrowInterest{margin_mode: "cross"}` whose amounts and clock
  equal the same raw row, plus one `%Bourse.Conversion{from_currency: "USDC", to_currency:
  "USDT"}` whose `price` equals the raw `ratio` and whose amount ratio agrees within the
  venue's published precision. A quote
  request is non-executing; do not call `acceptQuote`.

### derive — position accounting fields on a live row (task 316, filed 2026-07-17)
- Authored slices: `derive:normalization.field_maps.position`
- Blocked by: safely unwindable demo liquidity. On 2026-07-23 subaccount 144422 had 0 positions,
  0 open orders, 0.02 ETH and no USDC; ETH-PERP exposed a bid but no ask. Opening a position
  could not be guaranteed to unwind, so no mutation was attempted.
- The open question: on a *live* open position, are `realized_pnl`, `cumulative_funding`, `pending_funding`, `total_fees`, `net_settlements`, `average_price` populated with the documented semantics (esp. `average_price` non-null where CCXT parses null `entryPrice`)?
- Exact call: open a far-from-market limit order → filled position not required for most fields; then `Bourse.fetch_positions(ex, params: %{"subaccount_id" => 144422})` against `api-demo.lyra.finance`; close/cancel in the same session.
- Expected evidence: the six fields non-null on the live row; `average_price` populated while CCXT-JS `parsePosition` yields null `entryPrice` (confirming the DIVERGE).

### binanceusdm — conditional order types on `/fapi/v1/batchOrders` (task 332, C-T332, filed 2026-07-17)
- Blocked by: prod binanceusdm key with trade perms. Testnet refuses the whole conditional family on this endpoint, so it cannot confirm *or* falsify the authored element shapes — there is no host we can reach that accepts them.
- The open question: does **prod** `batchOrders` accept STOP / TAKE_PROFIT / STOP_MARKET / TAKE_PROFIT_MARKET / TRAILING_STOP_MARKET at all, or has Binance moved conditional orders to the Algo Order API for batch as well? Observed live 2026-07-17 on `testnet.binancefuture.com` with a valid `LTCUSDT` element: every one returns `-4120` "Order type not supported for this endpoint. Please use the Algo Order API endpoints instead.", while LIMIT/MARKET in the same shape reach `-4164`. If prod agrees, the authored conditional shapes are dead code and `createOrders` should route those types to the Algo Order API (or reject them client-side with a pointer) rather than emit an element the venue always refuses.
- Exact call: `Bourse.Unified.call(ex, :create_orders, "createOrders", %{"orders" => [%{"symbol" => "LTC/USDT:USDT", "type" => "stop_market", "side" => "buy", "amount" => 0.1, "stopPrice" => 5000}]}, [])` against `fapi.binance.com` (buy stop far above market — non-triggering; cancel if it rests).
- Expected evidence: prod returns a *business* error (notional/precision/balance) or a resting order id → the shape is confirmed and the testnet `-4120` is a sandbox limitation. A prod `-4120` → the conditional family is genuinely unsupported on `batchOrders`; file the routing/reject follow-up and drop the shapes.

### okx — closePosition `posSide` mapping + fetchConvertTrade `clTReqId` binding (task 362, filed 2026-07-18)
- Blocked by: prod okx key outside EEA compliance scope — the EEA demo account (`my.okx.com`) returns 51155 "local compliance restrictions" on `/api/v5/trade/close-position` for every derivative pair (linear and inverse, observed 2026-07-18), which fires *before* posSide validation; convert endpoints return a stable 50026 "System error" on demo (two calls, same code — demo-unavailable class, same as C17a's asset-currencies).
- The open question: does OKX read `posSide` from our close-position body (expect 51169 no-position / 51000 posSide error on a long/short-mode account with no position), and does convert-trade lookup echo `clTReqId`?
- Exact call: `Bourse.Unified.call(ex, :close_position, "closePosition", %{"symbol" => "ETH/USDT:USDT", "side" => "buy", "mgnMode" => "cross"}, [])` and `Bourse.fetch_convert_trade(ex, "<real clTReqId>")` against `www.okx.com`.
- Expected evidence: close-position answers a posSide/position business error (not a params-shape error); convert lookup echoes the requested `clTReqId`.

### binance + binanceusdm — sapi/eapi request identifier bindings (task 341, C-T341a/C-T341b, filed 2026-07-18)
- Blocked by: a production Binance key with margin / wallet / gift-card / convert permissions. The provisioned testnet keys cannot reach these bases at all: CCXT's own `urls.test` map (vendored, `test/reference_slice/binance.json`) publishes only `public`/`private`/`v1` (spot `api/v3`) and the `fapi*`/`dapi*` futures bases — no `sapi` and no `eapi` — and binance.ts states it outright: *"sandbox/testnet does not support sapi endpoints"*.
- Task 386 (2026-07-19): `fetchConvertQuote` now shapes unified `from_code`/`to_code`/`amount` as Binance Convert's mandatory `fromAsset`/`toAsset` and optional `fromAmount`; an attempted signed sandbox call still stops locally at `No base URL for section sapi on binance (sandbox)`, before transport. Production Convert host/key evidence remains required.
- The open question: do the native request names still hold on prod for the families testnet cannot serve — `asset`/`amount` on `/sapi/v1/margin/borrow-repay`, `asset` on `/sapi/v1/margin/interestRateHistory`, `asset`/`amount` on `/sapi/v1/asset/transfer`, `token`/`amount` on `/sapi/v1/giftcard/createCode`, `recordId`/`currency` on the eapi bill endpoint, and `dualSidePosition` as a `"true"`/`"false"` string on `/fapi/v1/positionSide/dual`?
- Exact call: against `api.binance.com` with a read-scoped prod key, the non-mutating members first — `Bourse.fetch_cross_borrow_rate(ex, "USDT")`, `Bourse.fetch_borrow_rate_history(ex, "USDT", limit: 1)`, `Bourse.fetch_ledger_entry(ex, "<real recordId>", "USDT")`; then, only under an operator-approved window, a minimal `Bourse.transfer(...)` and `Bourse.set_position_mode(ex, false)`. Mutating members stay deferred — task 341 deliberately sent no valid mutating request.
- Expected evidence: each read returns a populated row proving the venue accepted the mapped identifier, and a deliberately invalid identifier on the same endpoint returns a typed Binance business error (not a params-shape error) naming the mapped key.

### hyperliquid — vaultTransfer `usd` units on a live non-zero transfer (task 384, C-T384b, filed 2026-07-19)
- Authored slices: `hyperliquid:normalization.field_maps.transfer`
- Blocked by: a real vault the testnet wallet leads or is a depositor in, **plus** an operator-approved window to move funds. Every reachable falsification requires a *successful* transfer: a withdraw from a vault we are not in short-circuits on `"Vault not registered"` before the venue ever reads `usd`, and a deposit large enough to clear the vault minimum under the bare-USD reading would actually move money. There is no error path that echoes the interpreted amount.
- What is already proved: **semantics tier-1, non-CCXT** — the official Python SDK's own examples pass `5_000_000` for *"Transfer 5 usd"* (`examples/basic_vault_transfer.py`) and `1_000_000` for *"Transfer 1 USD"* on the identically-shaped `subAccountTransfer` (`examples/basic_sub_account.py`); the Rust SDK types the field `u64` (bare dollars could not express a cent). CCXT is self-inconsistent — it scales `subAccountTransfer` by 1e6 and leaves `vaultTransfer` bare. Live 2026-07-19: the branch reaches the venue as a signed `vaultTransfer` (venue answered its own vault error, not the bridge-withdraw error).
- The open question: does the venue credit `usd: 5_000_000` as $5.00 (confirming 1e6) rather than $5,000,000? i.e. is our DIVERGE from CCXT's bare value correct on the wire, not just in the SDK docs?
- Exact call: with a wallet that is a depositor in a testnet vault, `Bourse.withdraw(ex, "USDC", 5, "<vault>", vaultAddress: "<vault>")` (→ `usd: 5_000_000`), then read the vault equity / account balance delta before and after.
- Expected evidence: balance moves by **$5.00**, not $5,000,000 (rejected as insufficient) and not $0.000005. A $5,000,000-scale rejection or a micro-cent credit falsifies C-T384b and would restore CCXT's bare reading.

### derive — populated private funding-history row (task 594, C-T594h, filed 2026-08-12)
- Authored slices: `derive:normalization.field_maps.funding_history` (corrected 2026-08-12: venue `funding` is a signed dollar cashflow → unified `amount`; `rate` authored null because the response schema carries no rate field).
- Blocked by: the demo subaccount holds no perpetual position, so `private/get_funding_history` returns an empty `events` list. Producing a row requires holding a perp position across a funding boundary — outside the standing no-mutation policy.
- The open question: does a populated `events` row normalize to the correct signed USDC `amount`, symbol and ms timestamp — i.e. does the documented cashflow meaning hold on real settlement data?
- Exact call: with a demo subaccount that survived a funding boundary in a perp position, `Bourse.fetch_funding_history(ex, nil, params: %{"subaccount_id" => id}, limit: 10)`.
- Expected evidence: freeze and register the populated body; assert the parsed `amount` equals the raw `funding` string as a signed number, `rate` is nil, and the timestamp matches the raw ms value; upgrade C-T594h from resolved_tier 2 to 1.

### lighter — populated withdrawal and liquidation history rows (task 595, C-T546, filed 2026-08-14)
- Authored slices: `lighter:normalization.field_maps.transaction` (the withdrawal half only — the
  deposit half is populated and tier-1) and `lighter:normalization.field_maps.liquidation`
- Blocked by: neither row can be produced reversibly on the provisioned testnet account. A
  withdrawal moves funds off L2 with no authorized redeposit path, and a liquidation requires
  driving a funded account through a real margin call. Task 595's evidence discipline —
  IOC fill closed in cleanup, USDC transfer round-tripped back — has no counterpart here.
- What is already proved: the endpoints, auth scope and empty-envelope parse are tier-1. The
  2026-08-14 observations are fresh and real (`withdraw_history` → `{"code":200,"withdraws":[]}`,
  `liquidations` → `{"code":200,"liquidations":[],"next_cursor":""}`), reached through the runtime
  request builder. Field meanings rest on the pinned provider OpenAPI
  (`priv/venues/lighter/authority/manifest.json` artifact `rest-openapi`, revision `6957dd8a`) —
  `WithdrawHistoryItem` required `id amount timestamp status type l1_tx_hash asset_id`,
  `Liquidation` required `id market_id type trade info executed_at`.
- The open question: does a real withdrawal row's `status`/`type` pair normalize to the unified
  transaction status and `"withdrawal"` type, and does a real liquidation row's nested `trade`
  (`price`/`size`/`taker_fee`/`maker_fee`) plus `executed_at` normalize to the unified
  liquidation slice — including the market-id symbol resolution that only the populated row can
  exercise? `executed_at`'s unit is itself part of the question: the provider types it bare
  `int64` with no unit doc, the authored map assumes seconds, and this venue demonstrably mixes
  units (`Trade.timestamp` ms, `transaction_time` µs; trade and transfer were both corrected
  s → ms after live 13-digit values), so the authored `format: "s"` must be confirmed or
  corrected against the first populated row.
- Exact call: with an operator-approved withdrawal window (or an account that has been liquidated),
  `Bourse.fetch_withdrawals(ex)` and `Bourse.fetch_my_liquidations(ex)` against
  `testnet.zklighter.elliot.ai` with `sandbox: true`.
- Expected evidence: reach both operations live with a populated body, assert the parsed symbol
  is `BTC/USDC:USDC` rather than the raw market id, and amend C-T546's
  verification status from shape-only to populated for the two methods.

### lighter — trade fee value scale (ARC wave-2, C-T546i, filed 2026-08-14)
- Unverifiable claim: the unit/scale of `Trade.taker_fee`/`maker_fee`. The pinned OpenAPI types
  both as optional `int32` while every other Trade money field (`size`, `price`, `usd_amount`)
  and both `LiqTrade` fee fields are strings — on this venue an integer money field is a scaled
  unit (our signed write path submits `usdc_fee` at 1e6 per USDC). The authored parse passes the
  raw value through as `fee.cost`, which is an unconfirmed reading.
- Blocked by: every observed fill on the provisioned testnet account omits both keys (zero-fee
  testnet fills — re-confirmed by the 2026-08-14 `fetch_my_trades` observation), so no live call
  can currently discriminate raw-decimal from 1e6-scaled.
- What is already proved: parse plumbing only — the offline stub pins that a present integer
  passes through untouched, labelled in-line as a plumbing pin, not USDC semantics (C-T546i).
- Exact call: one fee-bearing fill (a market/account combination with nonzero maker/taker fee —
  possibly mainnet, or a testnet market with fees enabled), then `Bourse.fetch_my_trades(ex)` and
  a cross-check of the returned integer against the account's USDC balance delta; alternatively a
  provider statement of the field's unit.
- Expected evidence: a live `fetch_my_trades` response carrying populated `maker_fee`/`taker_fee`,
  the authored map given an explicit confirmed scale (or confirmed raw), and C-T546i amended to
  tier 1.

### bybit — spot-category order rows are unexercised while the cases pin `category=linear` (task 671, filed 2026-08-24)

- Authored slices: bybit order-identity cases `fetchClosedOrder:0`, `fetchOpenOrder:0`,
  `fetchOrder:0/1`, `fetchOrderClassic:0`, `fetchOrderTrades:0` — inventoried and green
  under `category=linear` since 2026-08-24.
- Blocked by: a coverage pin, not the venue. In the first hours after the AI sub-account
  was provisioned, every spot create and `convert-execute` answered business error 10024
  ("regulatory restrictions") while linear creates succeeded — that differential drove the
  linear re-pin. The block was transient provisioning lag: later the same day a spot limit
  sell was accepted (`retCode 0`, order id `2288579161532754176`, cancelled clean) and a
  tiny convert executed. Spot state is creatable now; the cases simply do not ask for it.
- The open question: whether spot-category order rows carry the same field meanings the
  linear rows prove.
- Exact call: a small spot round-trip on testnet, then either re-pin one order-identity
  case to `category=spot` or add spot branches, then
  `mix bourse.verify_rest_read_contracts --venue bybit`.
- Expected evidence: `retCode 0` spot order/execution rows asserted against the same
  success meanings the linear branches prove.

### bybit — delivery/settlement records need a contract held through expiry (task 671, filed 2026-08-24)

- Authored slices: bybit case `fetchMySettlementHistory:0` (`privateGetV5AssetDeliveryRecord`)
- Blocked by: `/v5/asset/delivery-record` answers `retCode 0` with an empty list in all
  three categories (`inverse`, `linear`, `option`) on 2026-08-24. The nearest inverse dated
  future (`BTCUSDU26`) delivers at 1790323200000 (2026-09-25); the nearest linear delivery
  is 2026-08-28. No delivery record can be manufactured in-session.
- The open question: delivery-record semantics against a real settled row.
- Exact call: hold a dated future or an option through its expiry on testnet, then
  `mix bourse.verify_rest_read_contracts --venue bybit`.
- Expected evidence: a raw payload carrying `deliveryPrice` and `deliveryRpl`.
- Update (2026-08-24): state is seeded — the testnet main account holds 60
  `DOGEUSDT-28AUG26` (market-filled, `avgPrice 0.09205`), deliberately left open through
  delivery on 2026-08-28. Re-run the venue lane after that date; this is the venue's last
  red case (77/78 green on 2026-08-24).

### bybit — fetchOpenOrder / fetchOrder realtime branch need a currently-open order (task 671, filed 2026-08-28)

- Authored slices: bybit cases `fetchOpenOrder:0` and `fetchOrder:1` — sourced from
  `fetchOpenOrders` since 2026-08-28 (previously sourced from `fetchClosedOrders`, which
  the entry above records as green on 2026-08-24 off the sole `DOGEUSDT-28AUG26` market
  fill). By 2026-08-28, four days later, that same fill answered `order_not_found`
  against `GET /v5/order/realtime` even though `GET /v5/order/history` still serves it —
  the id had aged out of realtime's cache.
- Blocked by: the account holds no currently open/unfilled linear order. Bybit's own docs
  cap `/v5/order/realtime`'s closed-order lookup at the 500 most recent rows per category
  and note the cache is cleared on service restarts, so a closed order is not a durable id
  source for this endpoint. The fix couples each realtime-branch case's id to what the
  endpoint actually guarantees — a live open order via `fetchOpenOrders` — instead of a
  closed one that may or may not still be cached; that is a correct, structurally-fixed
  coupling, but it can only be exercised once the account holds a resting order.
- The open question: whether `fetchOpenOrder` and `fetchOrder`'s realtime branch parse the
  same required/any fields once a real open order exists.
- Exact call: place (or wait for) a resting linear limit order on the testnet main-account
  key, then `mix bourse.verify_rest_read_contracts --venue bybit`.
- Expected evidence: `fetchOpenOrder:0` and `fetchOrder:1` both green against a real open
  order id sourced from `fetchOpenOrders`.

### okx — funding-account and savings surfaces are disabled in demo trading (task 671, filed 2026-08-23)

- Authored slices: okx cases `fetchCurrencies:0`, `fetchDepositWithdrawFees:0`,
  `fetchDepositAddress:0`, `fetchDepositAddressesByNetwork:0`, `fetchBorrowRateHistory:0`,
  `fetchBorrowRateHistories:0`
- Blocked by: OKX demo trading answers `{"code":"50038","msg":"This feature is unavailable in
  demo trading"}` on `asset/currencies`, `asset/deposit-address` and
  `finance/savings/lending-rate-history` (signed live probes, 2026-08-23; the savings read
  answers code 0 only without `x-simulated-trading`, i.e. on production). Provider authority:
  https://www.okx.com/docs-v5/en/ § "Demo Trading Services" — deposit/withdraw/purchase-
  redemption functions are excluded from demo.
- The open question: the funding-account and savings envelopes on production.
- Exact call: production OKX key (demo keys answer 50101 on live), then
  `mix bourse.verify_rest_read_contracts --venue okx`.
- Expected evidence: code 0 bodies parsed against the six cases' success meanings.

### okx — deposit/withdrawal history rows cannot exist on a demo account (task 671, filed 2026-08-23)

- Authored slices: okx cases `fetchDeposit:0`, `fetchWithdrawal:0`
- Blocked by: the history endpoints answer code 0 with `data: []` on demo, and deposits/
  withdrawals are exactly the functions demo excludes — the account can never accumulate a row.
- The open question: single-record lookup semantics (`txId`/`wdId` filters) against real rows.
- Exact call: production account with at least one deposit and one withdrawal on record.
- Expected evidence: the resource strategy resolves a real id and the lookup returns its row.

### okx — no read-only source of a transId for transfer-state (task 671, filed 2026-08-23)

- Authored slices: okx case `fetchTransfer:0:privateGetAssetTransferState`
- Blocked by: OKX issues `transId` only from `POST /api/v5/asset/transfer`; every read surface
  (`asset/bills`, `account/bills`) exposes `billId`, and `transfer-state` rejects a billId with
  `58129 "transId is incorrect or transId does not match with 'type'"` (live probe 2026-08-23).
- The open question: transfer-state semantics for a genuine transId.
- Exact call: perform one funding→trading transfer (a write), capture its transId, then call
  `fetch_transfer(ex, transId)`.
- Expected evidence: code 0 with the transfer's state row matching the authored map.
- Update (2026-08-23, task 671): a real transfer now exists (transId 327514023, 30 USDT
  trading→funding, since reversed via 327514025) and `Bourse.fetch_transfer(ex, "327514023")`
  returned the correct `%Bourse.TransferEntry{}` — the state semantics are live-verified. What
  remains unreachable is only the contract case's resource strategy: no read surface
  (`asset/bills`, `account/bills`, `account/bills-archive`) exposes a `transId` (rows carry
  `billId` only, re-probed live), so `source_method: fetchTransfers` can never resolve one.
- Update (2026-08-28): the `fetchTransfers:0` branch of this same lane was independently
  zeroing itself (both `account/bills-archive` calls carried a stray `instType: "SPOT"`
  literal; type-1 transfer bills carry an empty `instType`/`instId`, live-confirmed:
  `fetch_transfers(ex)` → 7 rows, `fetch_transfers(ex, instType: "SPOT")` → `[]`). Removing
  that literal from both the `fetchTransfers` and `fetchTransfer` branches (the latter's copy
  was leaking into `fetchTransfer:0`'s resource-strategy lookup and forcing the same `[]`) makes
  the resource strategy resolve a real `billId` again. `fetchTransfer:0` now fails with the exact
  documented reason instead of a misleading `provider account state has no id from
  fetchTransfers`: `[okx] exchange_error: transId is incorrect or transId does not match with
  'type'` (live, 2026-08-28) — the same 58129 confirmed above, now reached honestly rather than
  masked by an unrelated filtering bug. The transId/billId gap itself is unchanged.

### hyperliquid — deposit-history rows require a real bridge/CCTP transaction (task 671, filed 2026-08-23)

- Authored slices: hyperliquid case `fetchDeposits:0:publicPostInfo`
- Blocked by: `info:userNonFundingLedgerUpdates`-backed deposit history holds zero rows for the
  provisioned testnet wallet even though it carries drip-funded USDC — the official drip does not
  register as a deposit event. A row exists only after a genuine Arbitrum-bridge or CCTP
  transaction credits the wallet (provider onboarding docs:
  https://hyperliquid.gitbook.io/hyperliquid-docs/onboarding/how-to-start-trading), which no
  Bourse REST call can produce.
- The open question: do populated deposit rows carry the documented amount/currency/timestamp
  through the unified parser?
- Exact call: after a real bridge deposit to the testnet (or production) wallet, call
  `Bourse.fetch_deposits(ex)`.
- Expected evidence: a populated row whose amount, currency and timestamp match the bridge
  transaction.

### hyperliquid — withdrawal-history rows are policy-blocked (task 671, filed 2026-08-23)

- Authored slices: hyperliquid case `fetchWithdrawals:0:publicPostInfo`
- Blocked by: the wallet has zero withdrawal rows (verified live 2026-08-23), and creating one
  means executing a real withdrawal — forbidden by the standing no-withdrawals policy for
  provisioned credentials.
- The open question: withdrawal-row semantics (id, amount, fee, status, timestamp) through the
  unified parser.
- Exact call: after an operator-approved withdrawal from the testnet wallet, call
  `Bourse.fetch_withdrawals(ex)`.
- Expected evidence: a populated row matching the withdrawal's id, currency, amount and status.

### lighter — authenticated order stream (task 681, filed 2026-08-28)

- Authored slices: omit — this is a live journey stream leg, not an authored field-map
- Blocked by: the configured Lighter testnet account is not recognized, so the
  documented `account_all_orders/{ACCOUNT_ID}` channel cannot observe a placed
  order. Live 2026-08-28 against `testnet.zklighter.elliot.ai` /
  `wss://testnet.zklighter.elliot.ai/stream`: `publicGetAccount` → code 29404
  `"not found"`; signed `sendTx` create → code 21100 `"account not found"`;
  private REST reads → code 20013 `"invalid auth: couldnt find account"`;
  `Bourse.WS.connect(ex, :private)` → `:no_url_configured` (authored
  `websocket.urls.private` is null; Lighter serves account channels on the
  public stream); public subscribe without `auth` → code 20001 `"auth field is
  required"`; subscribe with a helper-minted auth token → code 20013 `"invalid
  auth: couldnt find account"`. The REST trader journey stays in
  `test/live/journeys/trader/lighter_test.exs` and fails loudly on 29404 until
  credentials are refreshed.
- The open question: does a resting zk-signed limit order's `client_order_index`
  appear in an `update/account_all_orders` frame before cancel, and disappear
  from the live open-order read after cancel?
- Exact call: refresh `LIGHTER_TESTNET_API_KEY_INDEX`, `LIGHTER_TESTNET_ACCOUNT_INDEX`,
  and `LIGHTER_TESTNET_API_PRIVATE_KEY`, then run
  `mix test.json --quiet --include dangerous test/live/journeys/trader/lighter_test.exs`
  and subscribe on the public stream to `account_all_orders/{ACCOUNT_ID}` with
  the signed `auth` token required by https://apidocs.lighter.xyz/docs/websocket-reference
- Expected evidence: the resting order's `client_order_index` appears in an
  `update/account_all_orders` frame before cancellation; the same order disappears
  from the live open-order read after cancellation.

### alpaca — private trade_updates stream (task 674, filed 2026-08-28)

- Authored slices: omit — this is a live journey stream leg, not an authored field-map
- Blocked by: the private WebSocket URL is not authored, so the paper account's
  order events cannot be observed through `Bourse.WS`. Live 2026-08-28 against
  `paper-api.alpaca.markets`: `Bourse.WS.connect(ex, :private)` →
  `:no_url_configured` (authored `websocket.urls.private` and `sandbox_private`
  are null). Alpaca serves account events on
  `wss://paper-api.alpaca.markets/stream` after an `authenticate` handshake and
  a `listen` for `trade_updates`
  (https://docs.alpaca.markets/us/docs/websocket-streaming). The REST trader
  journey stays in `test/live/journeys/trader/alpaca_test.exs`.
- The open question: does a resting paper crypto limit order's id appear in a
  `trade_updates` frame (`event` `new` / `pending_new`) before cancel, and a
  `canceled` event after cancel?
- Exact call: author `websocket.urls.sandbox_private` to
  `wss://paper-api.alpaca.markets/stream`, wire the authenticate/listen dialect,
  then run
  `mix test.json --quiet --include dangerous test/live/journeys/trader/alpaca_test.exs`
  and subscribe to `trade_updates` on that paper stream.
- Expected evidence: the resting order's id appears in a `trade_updates` frame
  before cancellation; a `canceled` event arrives after `DELETE /v2/orders/{id}`.
