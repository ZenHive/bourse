# Hyperliquid carve register

Append-only schema confrontations for Hyperliquid. Follow the allocation and evidence rules in
`docs/authored-specs.md`; this file records decisions and does not define doctrine.

**Canonical for this venue.** Historical narrative may still appear in `docs/authored-specs.md`;
this file is the complete Hyperliquid carve record.

## 2026-08-14 — remaining WsLedgerUpdate labels (Task 609)

**C-T609g — Every remaining `WsLedgerUpdate` literal with a registered class, or an obvious
venue-faithful snake_case label, stops emitting camelCase (task 609). Outcome: CONFIRM the
provider union members.** Hyperliquid's official
[`WsLedgerUpdate` union](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/websocket/subscriptions#wsusernonfundingledgerupdates)
names the six leftovers as follows.

| Provider literal | Unified result | Confrontation |
|---|---|---|
| `spotTransfer` | `transfer` | CONFIRMED by `WsSpotTransfer` (`token`, `amount`, `user`, `destination`, `fee`); a token transfer between addresses. |
| `vaultLeaderCommission` | `commission` | CONFIRMED by `WsVaultLeaderCommission` (`user`, `usdc`); commission paid to the vault leader. |
| `rewardsClaim` | `rewards_claim` | CONFIRMED by `WsRewardsClaim` (`amount`) and the official L1 schema's note that it combines builder and referrer fees. Those are different registered classes, so the mixed arm keeps the venue-faithful snake_case label. |
| `vaultCreate` | `vault_create` | CONFIRMED by the `WsVaultDelta` create variant; no registered class names vault creation, so the venue-faithful snake_case of the provider literal. |
| `vaultDistribution` | `vault_distribution` | CONFIRMED by the `WsVaultDelta` distribution variant; not a deposit or withdrawal (those are `vaultDeposit` / `vaultWithdraw`). |
| `spotGenesis` | `spot_genesis` | CONFIRMED by `WsSpotGenesis` (`token`, `amount`); token issuance, not an on-chain `deposit`. |

Funding payments stay off this vocabulary: `userNonFundingLedgerUpdates` excludes them, and
they live on `userFundings`. That exemption is named in the coverage suite rather than
silenced. The provider's
[L1 data schema](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/nodes/l1-data-schemas)
supplies the builder/referrer-fee semantics for `rewardsClaim`; the WebSocket union itself only
defines its shape.

<!-- carve-evidence-status
{"carve_id":"C-T609g","date":"2026-08-14","semantic_source":{"kind":"provider_owned","reference":"Hyperliquid WebSocket subscriptions WsUserNonFundingLedgerUpdates / WsLedgerUpdate union members WsSpotTransfer, WsVaultLeaderCommission, WsRewardsClaim, WsVaultDelta, WsSpotGenesis plus L1 data schemas RewardsClaim builder/referrer-fee note"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Classifications are provider-documentation-anchored; no manifest-registered non-funding ledger rows cover these six variants"}
-->

## 2026-08-13 — registered ledger label reconciliation (Task 607)

**C-T607b — Hyperliquid deposit and withdrawal deltas use the registered cross-venue classes
(task 607). Outcome: CONFIRM provider event identities; DIVERGE from the earlier withdrawal
label.** Hyperliquid's official
[`WsLedgerUpdate` union](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/websocket/subscriptions#wsusernonfundingledgerupdates)
defines direct `deposit` and `withdraw` members, a `WsVaultDelta` member whose variants include
`vaultDeposit`, and a `WsVaultWithdrawal` member whose type is `vaultWithdraw`.

| Provider literal | Unified result | Confrontation |
|---|---|---|
| `deposit` | `deposit` | CONFIRMED by `WsDeposit`; passthrough already emits the registered value. |
| `vaultDeposit` | `deposit` | CONFIRMED as the deposit variant of `WsVaultDelta`; DIVERGE from the mixed-case raw passthrough. |
| `withdraw` | `withdrawal` | CONFIRMED by `WsWithdraw`; DIVERGE from the one-character-short raw passthrough. |
| `vaultWithdraw` | `withdrawal` | CONFIRMED by `WsVaultWithdrawal`; DIVERGE from the earlier `withdraw` alias. |

The provider literals remain in `LedgerEntry.info`; the aliases change only the unified
cross-venue vocabulary.

<!-- carve-evidence-status
{"carve_id":"C-T607b","date":"2026-08-13","semantic_source":{"kind":"provider_owned","reference":"Hyperliquid WebSocket subscriptions WsUserNonFundingLedgerUpdates / WsLedgerUpdate union"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The classifications are provider-documentation-anchored; no manifest-registered non-funding ledger rows cover all four deposit and withdrawal variants"}
-->

**C-T538 — Hyperliquid order `status` covers the full provider-documented closed enum
(task 538). Outcome: CONFIRM venue; reality tier 1.**

- *Exchange semantics:* Hyperliquid's
  [orderStatus info endpoint](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#query-order-status-by-oid-or-cloid)
  documents a closed `<status>` vocabulary used on both single-order lookups and historical
  order rows: `open`, `filled`, `canceled`, `triggered`, `rejected`, `marginCanceled`,
  `vaultWithdrawalCanceled`, `openInterestCapCanceled`, `selfTradeCanceled`,
  `reduceOnlyCanceled`, `siblingFilledCanceled`, `delistedCanceled`, `liquidatedCanceled`,
  `scheduledCancel`, `tickRejected`, `minTradeNtlRejected`, `perpMarginRejected`,
  `reduceOnlyRejected`, `badAloPxRejected`, `iocCancelRejected`, `badTriggerPxRejected`,
  `marketOrderNoLiquidityRejected`, `positionIncreaseAtOpenInterestCapRejected`,
  `positionFlipAtOpenInterestCapRejected`, `tooAggressiveAtOpenInterestCapRejected`,
  `openInterestIncreaseRejected`, `insufficientSpotBalanceRejected`, `oracleRejected`,
  `perpMaxPositionRejected`. The abbreviated sample on `historicalOrders` is not the full
  set.
- *Our carve:* non-terminal `open`/`triggered` → unified `open`; `filled` → `closed`; every
  `*Canceled` / `canceled` / defensive `cancelled` alias → `canceled`; every `*Rejected` /
  `rejected` → `rejected`. The authored enum is complete against the provider list; an
  unknown raw value still fails loudly (`{:unmapped_order_status, …}`) — no silent
  default and no passthrough.
- *Live evidence (2026-08-04, testnet wallet):* `POST /info type=historicalOrders` returned
  229 rows with status frequencies `%{"canceled" => 42, "filled" => 71, "iocCancelRejected" => 1,
  "minTradeNtlRejected" => 2, "open" => 113}`. Sample min-notional rejection oid
  `56637337026` (BTC limit 0.0003 @ 32012.0, `status=minTradeNtlRejected`). Before the
  complete enum, `fetch_orders` / `fetch_closed_orders` / `fetch_canceled_orders` /
  `fetch_canceled_and_closed_orders` all raised
  `Unmapped authored order status … raw value "minTradeNtlRejected"`. After completing the
  map, all four methods return `{:ok, …}` on the same account; the two min-notional rows
  surface as unified `status: "rejected"`.
- *Shared invariant:* every runtime venue must cover its provider-documented order-status set
  in its authored `enum_map` or explicitly declare passthrough (see
  `test/bourse/authored_order_status_coverage_test.exs`).

<!-- carve-evidence-status
{"carve_id":"C-T538","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"Hyperliquid info-endpoint orderStatus status table (gitbook)"},"observed_evidence":{"kind":"live_venue","reference":"Hyperliquid testnet historicalOrders 2026-08-04: 2× minTradeNtlRejected (oids 56637337026, 56636671243), 1× iocCancelRejected; four unified order-read methods green after enum completion"},"compatibility_reference":null,"resolved_tier":1}
-->

## Historical unnumbered divergence — public trades vs wallet fills

| Slice | Our rule | CCXT does | Why | Substitute oracle |
|---|---|---|---|---|
| `fetch_trades` / `fetchTrades` | `:not_supported` — message points to `fetch_my_trades`; `has.fetchTrades=false`; no endpoint mapping | Maps `fetchTrades` → `/info` `userFills` / `userFillsByTime` (wallet fills via `handlePublicAddress`), duplicating `fetchMyTrades` | Transport-public (unauthenticated, address-parameterized `/info`) ≠ semantically public (market trade tape). Surfacing the caller's own fills through the public-trades method is a contract lie relative to other venues | Live testnet: `fetch_trades` errors `:not_supported`; `fetch_my_trades` returns fills. Offline: static request fixtures pin `userFills`; request-shape and dispatch tests pin the source-authored `userFillsByTime` + `startTime` branch |

**Authorship note (hyperliquid fills):** `fetchMyTrades` is authored from CCXT JS (`hyperliquid.ts`): body `type=userFills` (no `since`) or `type=userFillsByTime` + `startTime` (`since` present), plus credential-derived `user` via the generic `source: api_key` mechanism (task 216). The owned declaration is `endpoints.request.defaults.fetchMyTrades` in `priv/specs/json/output/authored/hyperliquid.json`.

## 2026-07-19 — fetchCurrencies public default (Task 378)

**C-T378g — Hyperliquid `fetchCurrencies` prefers public `/info` (task 378).** Outcome:
CONFIRMED. The dual private `exchange` + public `info` list previously relied on a
venue-local `configured_endpoint/3` clause (still present as a defense in depth). Authored
`endpoint_selection.fetchCurrencies.default = public_post_info` makes the no-arg default
spec-owned so the bare-hd audit stays green without runtime special cases alone.

## Task 384 — withdraw with vaultAddress → vaultTransfer (2026-07-19)

**C-T384 — vault withdraw is L1 `vaultTransfer`, not `withdraw3`. Outcome: ADOPT (task 384).**

- *Exchange carve ([official exchange-endpoint docs](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/exchange-endpoint.md),
  [pinned authority manifest](../../priv/authority/hyperliquid/manifest.json), artifact
  `docs-full` — "Deposit or withdraw from a vault"):* action
  `{"type":"vaultTransfer","vaultAddress":0x…42-char,"isDeposit":boolean,"usd":number}`.
  No destination / time / signatureChainId. L1-signed (`sign_l1_action`), not the
  user-signed `HyperliquidTransaction:Withdraw` bridge path. Direction is solely
  `isDeposit` (true = deposit into vault, false = withdraw from vault). Docs do
  **not** annotate `usd` as 1e6 micro-units (contrast `updateIsolatedMargin.ntli`,
  which explicitly says "6 decimals, e.g. 1000000 for 1 usd").
- *Official Python SDK:* `Exchange.vault_usd_transfer(vault_address, is_deposit, usd: int)`
  builds the same four-field action and signs with `sign_l1_action(..., vault_address=None)`
  — the vault lives *inside* the action, not as the envelope `vaultAddress` used for
  trading-on-behalf-of-vault. The SDK takes a raw `int` and does **not** run
  `float_to_usd_int` (that helper is reserved for `update_isolated_margin`); callers
  supply the integer the venue expects.
- *CCXT reference:* `withdraw(..., params.vaultAddress)` emits vaultTransfer with
  `isDeposit: false` and `usd: amount` — the **bare** human amount (fixture #1144
  shows amount 100 → `usd: 100`). Bridge withdraw without vaultAddress stays
  `withdraw3`.
- *Our carve:* **ADOPT the action shape / field order / direction field; DIVERGE on
  `usd` units.** Unified `withdraw` with `params.vaultAddress` (or `vault_address` /
  sub-account aliases) builds L1 `vaultTransfer` (`isDeposit: false`, 0x-prefixed
  vault in the action, no top-level envelope vaultAddress), with `usd` in **1e6
  micro-USD**. Without vaultAddress, build stays the task-371 user-signed
  `withdraw3`. `pack_l1_action!/1` packs type → vaultAddress → isDeposit → usd and
  raises on unknown fields.

**C-T384b — `usd` units. Outcome: DIVERGE from CCXT (task 384).**

- *The question:* the official GitBook types `usd` only as `"number"` and its example
  shows a bare `100`; CCXT emits the bare amount. Is `usd` bare USD or 1e6 micro-USD?
- *Decisive non-CCXT evidence (official Python SDK examples, fetched 2026-07-19):*
  - `examples/basic_vault_transfer.py` → `exchange.vault_usd_transfer(testnet_HLP_vault, True, 5_000_000)`
    commented *"Transfer 5 usd to the HLP Vault"* → **5_000_000 == $5**, i.e. 1e6.
  - `examples/basic_sub_account.py` → `exchange.sub_account_transfer(sub_account_user, True, 1_000_000)`
    commented *"Transfer 1 USD to the subaccount"* → same convention on the
    identically-shaped sibling action.
  - `hyperliquid/exchange.py::vault_usd_transfer` passes `usd` through with **no**
    scaling, so the caller must pre-multiply — the SDK's own examples show the
    caller multiplying by 1e6. (The earlier reading — "SDK takes a raw int, so
    bare" — mistook *unscaled-by-callee* for *bare*.)
  - Rust SDK types the field `usd: u64`. A bare-dollar unsigned integer could not
    express a cent; 1e6 is what makes the `u64` coherent.
- *CCXT self-inconsistency (why the fixture is wrong, not us):* CCXT's own
  `transfer()` → `subAccountTransfer` path scales
  (`parseToInt(Precise.stringMul(amount, '1000000'))`) for a wire schema identical
  to vaultTransfer's, while its `withdraw()` vault branch passes `amount` bare.
  CCXT is internally inconsistent on the same units; the SDK is not.
- *Consequence of adopting CCXT:* a `withdraw(…, vaultAddress: v)` of 100 would move
  `$0.0001` instead of `$100` — a 1,000,000× under-transfer.
- *Our carve:* `usd = amount * 1_000_000`, sharing `amount_to_micro_usd/1` with
  `subAccountTransfer` / `updateIsolatedMargin`. The retired reference case
  `withdraw from vault #1144` asserted CCXT's bare value. Do not "fix" it by
  reverting to bare units; see the ledger entry below for the live confirmation
  still owed.
- *Tier:* the units verdict rests on the official SDK + docs (non-CCXT semantic
  source) — tier 1 on *semantics*, but **not** yet confirmed by a live non-zero
  vault transfer (that moves real funds). Logged in
  `docs/prod-verification-ledger.md`.
- *Signature identifier:* authored request defaults already mark withdraw's
  `action`/`nonce`/`signature` as `kind: omit` — the custom signer injects the
  signature envelope. No unresolved `identifier_reference` remains on this method.
- *Evidence:* live testnet 2026-07-19 — a zero-amount vault withdraw with a bogus
  vaultAddress signed as `vaultTransfer` and reached Hyperliquid, which answered
  with its own vault error (`"Vault not registered: 0x000…0001"` /
  `"Vault may not perform this action"`), **not** the bridge-withdraw
  `"Withdrawal amount cannot be zero"` — proving the branch routes to the L1
  vaultTransfer action and the venue accepts the signed L1 envelope. Integration
  pin in `HyperliquidAuthoredIntegrationTest`.
- *Retired compatibility-baseline inventory:* one deliberate divergence was tied to this
  carve: `withdraw from vault #1144`. The retired fixture expected bare dollars; the
  provider-backed micro-USD decision remains registered here.

## Task 371 — unified write/margin actions and wrapper surface (2026-07-18)

**C-T371a — `fetchHip3Markets`. Outcome: DIVERGE (not adopted in the compiled unified surface) (task 371).**

- *CCXT surface:* fetches `perpDexs`, then each HIP-3 `metaAndAssetCtxs` slice and includes
  those markets in bare `fetchMarkets`.
- *Our carve:* retain task 370's spot + main-perp fan-out only. HIP-3 market identity and
  cross-DEX asset routing need their own authored read slice; exposing a partial result as
  the generic market list would hide those markets' distinct DEX context.

**C-T371b — `modifyMarginHelper`. Outcome: DIVERGE (do not expose CCXT's internal helper) (task 371).**

- *CCXT surface:* `addMargin` and `reduceMargin` call an internal helper.
- *Our carve:* author the shared construction behind the two public unified methods only:
  `updateIsolatedMargin` carries the market asset, fixed `isBuy: true`, and signed micro-USDC
  `ntli` (negative for reduce). The helper is an implementation detail, not client API.

**C-T371c — `reserveRequestWeight`. Outcome: DIVERGE (not adopted) (task 371).**

- *CCXT surface:* submits a paid `reserveRequestWeight` action that buys additional request
  capacity from the perp balance.
- *Our carve:* omit it from the unified API because it is account administration rather than
  trading, margin, transfer, or market-data capability. The generic raw endpoint remains
  available to callers who intentionally need it.

## Task 370 — unified READ slices (2026-07-18)

Live testnet sweep vs ccxt-js 4.5.65 found the hyperliquid unified read layer red beyond task 302's
fixture-gate coverage. Authority: Hyperliquid `/info` docs + live testnet
(`api.hyperliquid-testnet.xyz`); CCXT JS is a compatibility reference only.

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

**C-T417 — `action` / `nonce` / `signature` are signer-owned, never shaping-required.
Outcome: DIVERGE from the inherited spec carve (class-wide, task 417).**

- *Exchange carve:* the `/exchange` wire body is `{action, nonce, signature}`. All
  three are produced when the request is signed; none is caller-supplied input.
- *CCXT reference:* `hyperliquid.ts` builds `nonce = this.milliseconds()` and
  `signature = this.signL1Action(...)` inside each action method — they are locals
  of the signing step, not request params.
- *Our carve:* our pipeline shapes the request **before** `Bourse.Signing.Hyperliquid`
  runs, so declaring these as `identifier_reference` params made 12 methods raise
  `unresolved identifier_reference` before the signer could ever supply them. All
  three are now `{"kind": "omit"}` for the whole action class (task 384 had fixed
  only `withdraw`). The signer remains their sole producer.
- *Evidence:* live Hyperliquid testnet 2026-07-19 — `cancel_all_orders_after/2`
  previously raised locally; it now reaches the venue and returns a business
  rejection `%{"status" => "err", "response" => "Cannot set scheduled cancel time
  until enough volume traded. Required: $1000000. Traded: $704.86."}`. The venue
  answering with an *eligibility* error (rather than a signature/deserialization
  error) confirms the signed L1 action verified. No timer was armed, so no
  persistent state changed.

**C-T417b — `scheduleCancel.time` is nonce-relative. Outcome: CONFIRMED (adopt CCXT, task 417).**

- *Exchange carve:* `{"type":"scheduleCancel","time":<absolute ms>}`; dead man's
  switch. Packed type → time.
- *CCXT reference:* `hyperliquid.ts#cancelAllOrdersAfter` sends
  `time: nonce + timeout`, documenting `timeout` as "time in milliseconds, 0
  represents cancel the timer".
- *Our carve:* adopt `time = nonce + timeout` verbatim. An unusable `timeout`
  (nil / float / non-numeric / negative) raises rather than shaping an
  action-less body — dropping the identifier slots removed the guard that used
  to catch that input, so the builder fails loudly in its place.

## Historical confrontations (moved from authored-specs.md, task 466)

**C6 — hyperliquid price precision. Outcome: DIVERGE — no snapshot scalar.**

- *CCXT's carve:* computes a decimal-places number from the **current price** (5 significant
  figures via leading-zero count, capped at `MAX_DECIMALS − szDecimals`;
  `hyperliquid.ts:780-800`) — a price-level **snapshot** of a per-order rule, stale the moment
  price moves an order of magnitude.
- *Exchange semantics (non-CCXT):* "prices can have up to 5 significant figures, but no more
  than MAX_DECIMALS − szDecimals decimal places" (HL gitbook tick-and-lot-size; MAX_DECIMALS =
  6 perps / 8 spot) — a **rule** parameterized per asset, not a scalar.
- *Our carve + rationale:* author the rule parameters (`szDecimals` on the market;
  `MAX_DECIMALS` per market type); `precision.price` stays absent on HL — a snapshot scalar is
  actively misleading (it passes sanity checks the venue rejects exactly when price has moved).
  Order sanity derives the constraint from the rule per order price.
- *Compatibility cost:* consumers expecting a `precision.price` float on HL get nil and must
  apply the rule — named and accepted; correctness about the venue over a comforting wrong
  number.
- *Implementation:* 209.

**C-T302 — Hyperliquid response slices authored end-to-end (task 302). Outcome: ALIGNED-to-ccxt (tier 2) with venue-native wire shapes.**

- *Exchange semantics (non-CCXT):* Hyperliquid `/info` candles are objects (`t/o/h/l/c/v`);
  order status is a nested `{order, status, statusTimestamp}` wrapper (or flat open-order
  rows); positions live under `assetPositions[].position`; ledger deposits/withdrawals share
  `userNonFundingLedgerUpdates` and filter by `delta.type`; spot unit tokens (`UETH`/`USOL`)
  map to base codes via the venue's spot currency mapping; create-order acks are
  `response.data.statuses[]` filled/resting maps (multi-status when TP/SL attached).
- *CCXT's carve:* static fixtures freeze CCXT's parse of those shapes (arrays for OHLCV,
  B/A→buy/sell, filled−remaining, coin→`BASE/USDC:USDC` or hip3 map). Compatibility
  oracle only — not reality.
- *Our carve + rationale:* author field maps + read-parse annotation to reproduce the
  fixture goldens (tier 2). Envelope keys `fetchDeposits`/`fetchWithdrawals`→`delta` and
  `fetchOrder`→`order` preserved. Transfer response remains out of this gate (tasks
  328/330/331). Position `isolated` is materialised from `leverage.type` and is compared
  value-for-value against hyperliquid's golden (which carries `true`/`false` per row);
  venues whose goldens omit the key are key-set-aligned to nil by
  `@position_additive_keys`, never skipped — so an inverted `isolated` still fails the
  gate (verified: inverting it reds 4 cases).
- *Implementation:* task 302. The registered Hyperliquid reality recordings
  preserve this response carve.

**C-T339 — Hyperliquid L1 asset index is an explicit `Market.asset_index`, not `baseId`. Outcome: DIVERGE from CCXT's baseId overload; CONFIRMED against venue (task 339).**

- *Exchange semantics (non-CCXT):* Hyperliquid L1 cancel/order actions take integer
  `a` (asset). Per [Asset IDs](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/asset-ids):
  main perps use the index in `meta.universe`; spot uses `10000 + spotMeta.universe[].index`;
  builder-deployed (HIP-3) perps use `100000 + perp_dex_index * 10000 + index_in_meta`
  (name form `{dex}:{coin}`). The live `/info` `meta` / `spotMeta` payloads do **not**
  carry a `baseId` field — the index is positional.
- *CCXT's carve:* `parseMarket` overloads `baseId` (and often `id`) with that signing
  integer so `cancelOrder`/`createOrder` can read `market['baseId']`. Static markets
  fixtures freeze `baseId: "0"` / `"10000"` / `"110000"`.
- *Our carve + rationale:* add owned `%Bourse.Market{asset_index: integer() | nil}`.
  Identity fields (`id`, `base_id`) keep market-identity semantics and stay nil when
  the wire has no native id. `RequestShape.Hyperliquid` reads **only** `asset_index`
  for L1 `"a"`. Populate via universe-order annotation at parse time (not by
  inventing a wire `baseId`). Fixture-replay injects `asset_index` from the static
  CCXT `baseId` cache so tier-2 request fixtures stay green without re-overloading
  identity fields on the live path.
- *Evidence sources:* offline pins on recorded real `meta` (BTC=0, SOL=position), real-shaped
  spotMeta rows (PURR=10000), and the docs HIP-3 example (`test:ABC` → 110000);
  live `load_markets` on testnet requires every market's `asset_index` to be an
  integer (main-dex swaps = universe order). Task 338 pins signature validity,
  with live order/cancel evidence in tasks 225 and 355.
- *Implementation:* task 339.

**C-T331a — Hyperliquid request builder constructs `:action` (L1 + user-signed) (task 331). Outcome: CONFIRMED against the live venue after tasks 338 + 339.**

- *Exchange semantics (non-CCXT):* Hyperliquid `POST /exchange` requires a signed
  `action` object. Order/cancel paths use L1 msgpack-hashed actions
  (`type: "order" | "cancel"`, short keys `a`/`o`/`b`/`p`/`s`/`r`/`t`); spot↔perp
  USDC class transfer uses user-signed `usdClassTransfer`
  (`hyperliquidChain`, `signatureChainId`, `amount`, `toPerp`, `nonce`); main↔sub
  USDC uses L1 `subAccountTransfer` (`subAccountUser`, `isDeposit`, `usd` in 1e6
  units). Documented at
  [Exchange endpoint](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/exchange-endpoint)
  and implemented in the official Python SDK (`Exchange.cancel` /
  `usd_class_transfer` / `sub_account_transfer`).
- *CCXT's carve:* `sign()` does not accept a caller `action` — it builds the action
  inside cancel/createOrders/transfer helpers before POSTing JSON.
- *Our carve + rationale:* `Bourse.Unified.RequestShape.Hyperliquid` builds `:action`
  (+ `:nonce`) from the unified method + params for cancel/cancelOrders/createOrders/
  transfer; `Bourse.Signing.Hyperliquid` only signs the action it is given (L1 vs
  user-signed by `action.type`). Explicit caller `:action` remains an override for
  raw endpoints. Tier-2 byte-equality for action shape is pinned by the static
  request fixtures (signature/`nonce` already in `skipKeys`).
- *Evidence sources:* the user-signed `usdClassTransfer` path is tier-1 green (live transfer,
  see C-T331b). Tasks 339 and 338 supplied the explicit live `asset_index` and
  ordered msgpack encoding; task 225 then placed and filled a live L1 order, and
  task 355 pinned live cancel success/rejection semantics. Static fixtures remain
  the tier-2 compatibility net for request shape.
- *Implementation:* task 331.

## Evidence status records

<!-- carve-evidence-status
{"carve_id":"C-T384b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Official Hyperliquid Python and Rust SDKs establish 1e6 micro-USD units"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT vaultTransfer passes bare amount while its sibling transfer scales by 1e6"},"resolved_tier":2,"known_gap_reason":"The signed branch reached venue business handling, but no successful non-zero vault transfer observed how the venue credits usd; ledger item remains open"}
-->

<!-- carve-evidence-status
{"carve_id":"C6","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Hyperliquid tick-and-lot-size documentation defines a price-dependent significant-figures rule"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT computes a snapshot precision scalar from current price"},"resolved_tier":2,"known_gap_reason":"No registered live order-boundary observation is attached to this carve"}
-->

**C-T331b — Hyperliquid transfer success is a bare ack → structured TransferEntry (task 331). Outcome: DIVERGE from CCXT's raw-ack parse; CONFIRMED against venue.**

- *Exchange semantics (non-CCXT):* Successful class and sub-account transfers return
  `{'status': 'ok', 'response': {'type': 'default'}}` with **no** transfer id,
  amount, or account fields (same docs + Python SDK responses). The ack is the
  success signal; request context is the only source for currency/amount/from/to.
- *CCXT's carve:* `parseTransfer` of that body yields
  `{info: raw, status: 'ok', …all other fields undefined}` and the static response
  fixture freezes `parsedResponse == httpResponse` (no TransferEntry normalization).
- *Our carve + rationale:* return `{:ok, %Bourse.TransferEntry{status: "ok", info: raw,
  currency/amount/from_account/to_account from the request}}`. Never report a
  successful money-moving call as `{:error, all-nil struct}`. Response-gate
  exclusion retained — our structured entry is deliberately not byte-equal to
  CCXT's unparsed golden. Offline pin + one live testnet spot→swap (and reverse)
  are the oracles.
- *Live confrontation (2026-07-17, tier 1):* with
  `HYPERLIQUID_TESTNET_API_KEY/SECRET` against `api.hyperliquid-testnet.xyz`,
  `Bourse.transfer(ex, "USDC", 0.1, "spot", "swap")` then reverse `"swap"→"spot"`
  both returned
  `%Bourse.TransferEntry{status: "ok", currency: "USDC", amount: 0.1, …,
  info: %{"status" => "ok", "response" => %{"type" => "default"}}}`. An
  underfunded direction returned `{:error, %Bourse.Error{…, raw: %{"status" => "err",
  "response" => "Insufficient balance for token transfer"}}}` — venue business
  error, not a parse/signing defect.
- *Implementation:* task 331.

<!-- carve-evidence-status
{"carve_id":"C-T378g","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":null,"resolved_tier":3,"known_gap_reason":"This internal authoring outcome records no provider-owned semantic source, independent venue observation, or CCXT compatibility evidence"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T384","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T384 and its register context"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T384 and its register context"},"resolved_tier":2,"known_gap_reason":"Provider-owned semantics are recorded, but no independent live or recorded venue observation establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T371a","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T371a and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T371b","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T371b and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T371c","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T371c and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T370","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T370 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T370 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T370 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T417","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T417 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T417 and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T417b","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T417b and its register context"},"resolved_tier":2,"known_gap_reason":"The registered outcome is supported only by CCXT compatibility evidence, not provider-owned semantics plus an independent venue observation"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T302","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T302 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T302 and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T339","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T339 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T339 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T339 and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T331a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T331a and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T331a and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T331a and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T331b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T331b and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T331b and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T331b and its register context"},"resolved_tier":1}
-->

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
{"carve_id":"C-T594i","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Hyperliquid funding, fees, clearinghouse, mids, and fills contracts linked in C-T594i"},"observed_evidence":{"kind":"recorded_venue","reference":"Registered Hyperliquid funding-rate-history accepted request plus provider cross-field formulas"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Dynamic user fee rates and a populated clearinghouse percentage row are not both covered by manifest-registered responses"}
-->

## 2026-08-12 — ledger type authority (Task 598)

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
{"carve_id":"C-T600h","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Hyperliquid funding and perpetuals contracts linked in C-T600h"},"observed_evidence":{"kind":"recorded_venue","reference":"Registered Hyperliquid funding-rate-history accepted request"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The deleted income slice was unwired and had no independent response evidence"}
-->

**C-T603i — Hyperliquid position percentage preserves PnL sign (task 603).
Outcome: DIVERGE from the absolute-value normalization.**

<!-- rate-unit path="normalization.field_maps.position.field_map.percentage" unit="percent_points" --> Clearinghouse state publishes signed `unrealizedPnl` and signed `returnOnEquity`; a loss therefore remains negative when Bourse computes `unrealizedPnl / marginUsed × 100`. [Perpetuals API](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals)

<!-- carve-evidence-status
{"carve_id":"C-T603i","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Hyperliquid clearinghouseState contract linked in C-T603i"},"observed_evidence":{"kind":"provider_shaped","reference":"Provider example unrealizedPnl -0.0134 and marginUsed 4.967826 pinned in hyperliquid_authored_spec_test.exs"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The signed provider example is not a manifest-registered clearinghouse body"}
-->
