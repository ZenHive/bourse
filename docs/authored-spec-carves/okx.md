# OKX carve register

Append-only schema confrontations for OKX. Follow the allocation and evidence rules in
`docs/authored-specs.md`; this file records decisions and does not define doctrine.

**Canonical for this venue.** Historical narrative may still appear in `docs/authored-specs.md`;
this file is the complete OKX carve record.

## 2026-08-10 — current funding-rate cadence (Task 573)

**C-T573d — Funding cadence is the provider's adjacent funding-time delta (task 573).
Outcome: CONFIRM venue.** OKX's official
[Get Funding Rate](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-funding-rate)
response publishes `fundingTime` and `nextFundingTime` for the instrument. The unified interval
is their positive millisecond difference normalized to hours, rather than a venue literal. Live
international demo returned an eight-hour delta for BTC-USDT-SWAP and the unified result now
contains `interval: "8h"` instead of nil.

<!-- carve-evidence-status
{"carve_id":"C-T573d","date":"2026-08-10","semantic_source":{"kind":"provider_owned","reference":"OKX API v5 Get Funding Rate response contract"},"observed_evidence":{"kind":"live_venue","reference":"Live www.okx.com simulated-trading BTC-USDT-SWAP fundingTime/nextFundingTime delta returned unified interval 8h on 2026-08-10"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-08-04 — documented order-status coverage (Task 538)

**C-T538e — OKX order statuses cover the provider's published vocabulary (task 538).
Outcome: CONFIRM venue; documentation-anchored, live-unverified.** OKX's official
[order-details reference](https://www.okx.com/docs-v5/en/#order-book-trading-trade-get-order-details)
lists `mmp_canceled` as an order state. It is terminal and maps to unified `canceled`. The
runtime-wide provider-status coverage test pins the complete list.

<!-- carve-evidence-status
{"carve_id":"C-T538e","date":"2026-08-04","semantic_source":{"kind":"provider_owned","reference":"OKX Get order details state enum"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"No live order-history row carrying mmp_canceled is registered"}
-->

**C-T398b — OKX option Greeks for the surface use the Black-Scholes `*BS` family; rho is
unsupported (task 398). Outcome: CONFIRM C35; reality tier 1.**

- *Exchange semantics:* `public/opt-summary` publishes both PA bare keys and `deltaBS` /
  `gammaBS` / `vegaBS` / `thetaBS`. Rho is not published.
- *Our carve:* `markets.greeks_conventions` maps delta/gamma/vega/theta to the `*BS` fields
  (portable BS units, continuing C35) and marks rho `supported: false` with no fabricated
  value. Source `ts` remains distinct from local `observed_at`.
- *Live evidence (2026-07-23):* OptionSurface discovery + instrument_greeks on international
  demo with call/put delta sign and range assertions.

<!-- carve-evidence-status
{"carve_id":"C-T398b","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"OKX opt-summary *BS Greeks family (C35)"},"observed_evidence":{"kind":"live_venue","reference":"OKX demo OptionSurface discover + instrument_greeks 2026-07-23"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T397b — OKX option `sz` is contracts and base exposure is `sz × ctVal × ctMult`
(task 397). Outcome: CONFIRMED against provider docs and live international demo; reality
tier 1.**

- *Exchange semantics:* OKX's [Get instruments](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-instruments)
  defines derivative `lotSz`/`minSz` in contracts and exposes `ctVal`, `ctMult`, `ctValCcy`,
  and `settleCcy`. The option contract multiplier is `ctVal × ctMult` in `ctValCcy`.
- *Live evidence (2026-07-23):* `BTC-USD-260723-59000-C` reported `ctVal=1`,
  `ctMult=0.01`, `lotSz=1`, and `minSz=1`, so one native `sz` is 0.01 BTC. International
  demo accepted `amount=0.01` as native `sz=1`; `fetchOrder` round-tripped
  `amount=0.01`, `filled=0`, `remaining=0.01`, and the order was canceled. Raw `sz=0.5`
  returned per-operation `sCode=51121`, `Order quantity must be a multiple of the lot size`.
- *Our carve:* option `contract_size` is the product, not `ctVal` alone. Native precision and
  limits are scaled by that product into canonical base exposure; the native step remains
  separately visible as `native_amount_step`.

<!-- carve-evidence-status
{"carve_id":"C-T397b","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"OKX Get instruments option contract fields cited in C-T397b"},"observed_evidence":{"kind":"live_venue","reference":"OKX international demo sz success and lot-size provider error observed 2026-07-23"},"compatibility_reference":null,"resolved_tier":1}
-->

**C-T506b — OKX option position `pos` is converted by the instrument's `ctVal × ctMult`
multiplier (task 506). Outcome: CONFIRM venue; reality tier 1.**

- *Exchange semantics:* [Get positions](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-positions)
  defines derivative `pos` in contracts; [Get instruments](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-instruments)
  supplies `ctVal` and `ctMult`. Base exposure is therefore `abs(pos) × ctVal × ctMult`.
- *Live evidence (2026-07-23, international demo):* order `3768547579136425984` opened
  position `3768547579169980416`. The raw position carried `pos=1`; its live instrument row
  carried `ctVal=1`, `ctMult=0.01`, so unified contracts were 0.01. Reduce-only close order
  `3768547728587866112` left zero residual. This also resolves task 407's raw `pos=19` audit
  row to 0.19 rather than 19. The scrubbed rows are frozen in
  `test/fixtures/responses/okx/fetch_positions.json`.
- *Our carve:* the shared option-quantity conversion applies to positions after symbol
  resolution. The multiplier comes from the loaded market's authored live fields; there is no
  venue-specific divisor.

<!-- carve-evidence-status
{"carve_id":"C-T506b","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"OKX account/positions pos contract unit and instruments ctVal/ctMult fields"},"observed_evidence":{"kind":"live_venue","reference":"OKX international demo option open/position/close lifecycle order 3768547579136425984, position 3768547579169980416, close 3768547728587866112; frozen fetch_positions body"},"compatibility_reference":null,"resolved_tier":1}
-->

## Task 442 — response 4.5.65 currencies adjudication (2026-07-22)

**C-T442f — Per-network `active` preserves OKX deposit and withdrawal availability (task 442).
Outcome: DIVERGE from CCXT 4.5.65; CONFIRM venue.**

OKX's [Get currencies](https://www.okx.com/docs-v5/en/#funding-account-rest-api-get-currencies)
schema defines `canDep` and `canWd` as independent chain-availability booleans. The authored
currency map keeps both and retains `active_requires_both: true`: a network is fully active only
when both deposit and withdrawal are available, while the directional fields preserve partial
availability. CCXT 4.5.65 leaves per-network `active` undefined and discards those provider-owned
facts. The retired compatibility baseline carried `fetchCurrencies default #17` as the one
deliberate divergence for this carve.

The alleged numeric-rendering residual is not a parser defect, shared or venue-specific.
`fee: 0.0` versus `0` and withdraw limits such as `500.0` versus `500` are recursively numeric-
equal under the replay comparator; a focused currency regression test pins that rule. The same
check covers the Binance and Bybit currency cases, whose actual mismatch is also only `active`.

## Task 482 — Explicit currency `active` rollup declaration (2026-07-22)

**C-T482b — OKX declares AND rollup for currency- and network-level `active` (task 482).
Outcome: CONFIRM venue; extends C-T442f without superseding it.**

- *Exchange semantics:* Get currencies documents independent `canDep` / `canWd` per chain. A
  chain with only one direction open is partially available, not fully fundable.
- *Our carve:* set `active_requires_both: true` on **both** the `currency_network_summary`
  (`field: "active"`) rule and the `currency_networks` rule so currency-level and per-network
  `active` share one authored guarantee: both directions must be open. Directional
  `deposit` / `withdraw` fields still OR across chains. First-class maps may not omit the flag
  (global C-T482).
- *C-T442f status:* still true (per-network deliberate divergence from CCXT); not rewritten.

## Task 484 — funding-surface request builds (2026-07-22)

Evidence sources: [OKX Get deposit address](https://www.okx.com/docs-v5/en/#funding-account-rest-api-get-deposit-address),
[Get withdrawal history](https://www.okx.com/docs-v5/en/#funding-account-rest-api-get-withdrawal-history),
[Withdrawal](https://www.okx.com/docs-v5/en/#funding-account-rest-api-withdrawal),
[Get bills details (last 3 months)](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-bills-details-last-3-months)
(consulted 2026-07-22); CCXT static request fixtures and `okx.ts` are tier-2 compatibility
references only. Mutation evidence for withdraw is error-compare only — never a completed
withdrawal.

**C-T484a — `code` → `ccy` on deposit-address and withdrawal-history reads (task 484).
Outcome: CONFIRMED against OKX docs.**

- *Exchange semantics:* both `GET /api/v5/asset/deposit-address` and
  `GET /api/v5/asset/withdrawal-history` filter on native `ccy`. Unknown query keys are
  ignored, so a unified `code` leaves the currency filter silent and returns every chain /
  every currency.
- *Our carve:* rename unified `code` to `ccy` in `RequestShape.OKX` for
  `fetchDepositAddress` and `fetchWithdrawals`, matching the C-T434c ledger/deposit rename
  that previously stopped short of these two methods.
- *Compatibility:* CCXT request fixtures #114 / #149 expect `?ccy=USDT`. Tier-2 only.
- *Live boundary (2026-07-22, `my.okx.com` demo):* `fetch_withdrawals(code: "USDT")`
  accepted (`[]`, venue code 0). A bogus `ccy` on the raw withdrawal-history route returns
  `58006` naming the token — proving the filter is validated, not ignored. Deposit-address
  on this EEA demo is feature-blocked (`50038`) for every body (with/without `ccy`), so that
  host cannot grade deposit-address acceptance. The withdrawal-history half is confirmed live;
  the combined carve remains tier 2 until the existing deposit-address production-verification
  ledger entry closes.

**C-T484b — Withdrawal body: network→chain composite and string amt/fee (task 484).
Outcome: CONFIRMED against OKX docs; extends C-T432.**

- *Exchange semantics:* [Withdrawal](https://www.okx.com/docs-v5/en/#funding-account-rest-api-withdrawal)
  documents `ccy` / `amt` / `toAddr` / optional `chain` as Strings. `chain` is a composite
  `"<currency>-<network>"` id (`USDT-TRC20`, `BTC-Bitcoin`, `USDT-ERC20`). When `chain` is
  omitted the venue uses the default main chain — so leaving unified `network: "TRC20"` on
  the wire (unknown key) is a silent money-path wrong request.
- *Chain vocabulary:* the composite suffix is the OKX chain name from Get currencies / the
  authored alias inverse (`TRC20`, `ERC20`, `Bitcoin`, `Optimism`, …). Unified codes pass
  through `config.routing.networks` first (`ETH`→`ERC20`, `BTC`→`Bitcoin`, `TRC20`→`TRC20`)
  so the wire value is a real OKX chain id, not a CCXT-only alias.
- *Our carve:* compose `chain = ccy + "-" + network_suffix` when `network` is present and
  `chain` is not already set; drop `network`; stringify `amt` and `fee` (authored
  `transform: "string"` on amount plus runtime stringify for fee). Endpoint selection remains
  C-T432 (`asset/withdrawal`).
- *Compatibility:* fixture #128 expects
  `{"ccy":"USDT","toAddr":…,"dest":"4","amt":"5","chain":"USDT-TRC20","fee":"1"}`.
- *Live boundary (error-compare only):* withdraw with mapped `chain` reaches OKX's own
  rejection (`50120` permission or address validation / demo-unavailable) — never
  `code 0` / a completed withdrawal.

**C-T484c — Funding-history derives instType/ctType/ccy from the symbol (task 484).
Outcome: CONFIRMED against OKX bills-archive schema.**

- *Exchange semantics:* `GET /api/v5/account/bills-archive` accepts optional `instType`,
  `ccy`, `ctType` (`linear`/`inverse`, FUTURES/SWAP only), and bill `type`. Funding fees are
  bill type `8`. The endpoint does **not** take a unified `symbol` / raw `instId` as its
  primary filter — currency + contract type select the bill stream.
- *Our carve:* keep authored `type: "8"`. From a contract symbol, set `ctType` + `ccy`
  (linear → quote currency; inverse → base currency) and, for SWAP only, `instType=SWAP`.
  Drop raw `symbol`/`instId` so they never ride as unknown query keys.
- *Compatibility:* fixture #96 (`BTC/USDT:USDT`) expects
  `type=8&ctType=linear&ccy=USDT&instType=SWAP`. Tier-2 only for the exact param set;
  the bills schema is provider-owned.
- *Live boundary:* signed EEA-demo funding-history read accepted (`code 0`).

## Task 432 — withdraw endpoint selection (2026-07-19)

Evidence sources: [OKX API v5 — Withdrawal](https://www.okx.com/docs-v5/en/#funding-account-rest-api-withdrawal)
([pinned authority manifest](../../priv/authority/okx/manifest.json), artifact `api-v5-docs`;
consulted 2026-07-19), with CCXT `okx.withdraw` as a compatibility reference. The EEA demo
host (`my.okx.com` + `x-simulated-trading: 1`) rejects the funding withdrawal route with a
venue error rather than completing it; that rejection is the intended invalid-operation
evidence, never a completed withdrawal.

**C-T432 — Ordinary unified withdrawal selects the funding withdrawal endpoint (task 432).
Outcome: CONFIRMED.**

- *Exchange semantics:* the documented on-chain withdrawal route is
  `POST /api/v5/asset/withdrawal`. It accepts the authored unified carrier fields `ccy`, `amt`,
  and `toAddr` (plus the vendored `dest: "4"` default); it is distinct from the read-only
  `GET /api/v5/asset/currencies` surface also listed for CCXT `withdraw`.
- *CCXT reference:* `okx.withdraw` maps the unified operation to
  `privatePostAssetWithdrawal`, agreeing with the documented write route. It is compatibility
  evidence only; the OKX route determines this carve.
- *Our carve:* author `endpoint_selection.withdraw.default = "asset/withdrawal"`. No
  `default_family` applies: this is a funding operation, not an `instType` market-family choice.
  The explicit selection prevents the first-class multi-endpoint guard from choosing by list
  position and sends the request to the venue.
- *Live boundary (observed 2026-07-19, `my.okx.com` demo):* `Bourse.withdraw(ex, "USDT", 1,
  "invalid-addr-task-432-not-a-wallet", %{})` reaches OKX and returns HTTP 401 with the venue
  code `50120` ("This API key doesn't have permission to use this function") — the demo key
  carries no Withdraw permission, so the request is rejected at authorization before address
  validation or the `50038` funding-route block. The pre-wire ambiguous-multi-endpoint refusal
  is gone, which is what this carve fixes; the venue error proves `ccy`/`amt`/`toAddr` were
  actually sent. Reaching the `50038`/address-validation boundary needs a withdraw-enabled key
  and is not a precondition for this carve. The integration assertion keeps the must-not-succeed
  requirement, so this carve cannot be mistaken for permission to execute a withdrawal.
  Extended by C-T484b (network→chain + string amt/fee).

## Task 427 — trading-fee response slice (2026-07-19)

Evidence sources: [OKX API v5 — Get fee rates](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-fee-rates)
(consulted 2026-07-19), with a signed EEA-demo call to `my.okx.com` using
`x-simulated-trading: 1`. CCXT `okx.parseTradingFee` is a compatibility reference only.

**C-T427a — Fee-rate sign is normalized to the portfolio's positive-is-cost convention
(task 427). Outcome: CONFIRMED against OKX semantics, agrees with Bourse.**

- *Exchange semantics:* `GET /api/v5/account/trade-fee` returns the applicable fee-rate row in
  `data[0]`. Live EEA demo (2026-07-19) returns Lv1 spot `maker: "-0.002"`, `taker: "-0.0035"` —
  OKX signs a commission **negative** and a rebate positive, the inverse of every other
  first-class venue we author.
- *Our carve:* multiply by `-1` (`scale: -1`, exact decimal via `Precise.string_mul`) so
  `TradingFee.maker`/`taker` mean "rate charged" — the same sign our bybit (`makerFeeRate`),
  binance (`makerCommission`), and hyperliquid (`userAddRate`) slices already produce. The raw
  row is retained verbatim as `info`, so no signal is lost. CCXT `okx.parseTradingFee` reaches
  the same outcome by an independent route (`Precise.stringNeg`, commented "OKX returns the fees
  as negative values opposed to other exchanges, so the sign needs to be flipped") — recorded as
  agreement, not as the reason.
- *Why not raw:* preserving OKX's sign would make one venue's `TradingFee` mean the opposite of
  every other venue's in the same unified struct, so `taker * notional` would silently flip sign
  across venues. Normalization is the unified layer's job; `info` is where raw lives.

**C-T427b — `makerU`/`takerU` carry the fee row for USDT-margined contracts (task 427).
Outcome: CONFIRMED against live OKX rows, agrees with CCXT `safeString2`.**

- *Exchange semantics:* the carrier field depends on `instType`. Live EEA demo (2026-07-19):
  `SPOT BTC-USDT` → `maker: "-0.002"`, `makerU: ""`; `SWAP BTC-USDT-SWAP` → `maker: ""`,
  `makerU: "-0.0002"`. OKX blanks the inapplicable axis rather than omitting it, and empty ≡
  absent via `Bourse.Safe` (same rule as C28).
- *Our carve:* read `maker` then `makerU` (`key`/`key2`), mirroring CCXT's
  `safeString2(fee, 'maker', 'makerU')`. Without the second key a USDT-margined symbol parses to
  an all-nil struct and the fail-loud read guard rejects it — the same class of defect this task
  was filed for, one market type over.
- *Known gap:* `makerUSDC`/`takerUSDC` exist and populate for `FUTURES`/`OPTION`, but no observed
  row carries them while both `maker` and `makerU` are blank, so they are not read. CCXT does not
  read them either. Revisit if a USDC-margined row is ever observed with both other keys empty.

**C-T427c — Fee-row symbol and plural surface (task 427). Outcome: CONFIRMED.**

- The requested unified symbol remains the source of `TradingFee.symbol`: the fee row is keyed by
  the `instType`/`instId` request axes and does not echo an instrument id. CCXT does the same
  (`safeSymbol(undefined, market)`).
- OKX authors only `fetchTradingFee`; `fetchTradingFees` has no endpoint mapping, so no plural
  parser contract exists to carve.

## Task 365 — ledger, transfer, and account response semantics (2026-07-19)

Evidence sources: [OKX API v5 — Account](https://www.okx.com/docs-v5/en/#trading-account-rest-api)
and [Funding](https://www.okx.com/docs-v5/en/#funding-account-rest-api) response schemas
(consulted 2026-07-19). Signed EEA-demo calls confirm account configuration, account-bills
transport, and populated internal-transfer bills. CCXT fixtures are compatibility controls,
not the correctness oracle.

**C-T365a — Account-bill balance semantics (task 365). Outcome: CONFIRMED against OKX schemas.**

- *Exchange semantics:* an account-bill row identifies itself with `billId`; `ccy` is the
  currency; `balChg` is the signed change; `bal` is the resulting balance; `ts` is Unix
  milliseconds; and `fee` is denominated in the row currency.
- *Our carve:* `amount` keeps the signed `balChg`; `direction` is derived from its sign;
  `after` is `bal`; `before` is exact decimal `bal - balChg`; and fee is
  `%{cost: fee, currency: ccy}`. Account-bill rows are completed successfully, so their
  unified status is `ok`.
- *Compatibility:* the populated ledger fixture #25 is now green, including its trade type,
  order reference, signed direction, before/after balances, and zero-USDT fee.

**C-T365b — Internal-transfer account codes (task 365). Outcome: CONFIRMED against OKX schemas.**

- *Exchange semantics:* funding is account code `6` and trading (spot) is `18`; transfer-state
  rows expose those numeric values in `from` and `to`. `transId`, `ccy`, `amt`, and `state`
  supply the identifier, currency, amount, and lifecycle respectively.
- *Our carve:* map `6 → funding` and `18 → trading` on transfer responses, while retaining
  raw numeric codes under `info`. `success → ok`; absent `state` remains nil for a bare
  transfer acknowledgement.
- *Compatibility:* fixtures #43–46 are green. The older `fetchTransfers` route uses account
  bills, so its amount remains `balChg` (not `amt`) and receives the same account-code mapping.

**C-T365c — Account configuration is identity, not balance state (task 365). Outcome: CONFIRMED
against OKX schemas.**

- *Exchange semantics:* `GET /api/v5/account/config` returns account identity/configuration;
  `uid` identifies the account and `acctLv` identifies its account mode. It does not describe
  a currency balance.
- *Our carve:* `fetchAccounts` maps `uid` to `Account.id` and preserves `acctLv` as the
  venue account-mode `type`; balance semantics stay exclusively in `fetchBalance`.

**Tier-1 limitation:** the EEA demo has no guaranteed populated *trading-account* bill row.
An empty `fetchLedger` success proves signing and routing only. The populated ledger mapping is
schema-backed and fixture-compatible; the production-verification ledger records the remaining
live confirmation.

## Task 389 — deposit-address and network collection semantics (2026-07-19)

Evidence sources: [OKX API v5 — Get deposit address](https://www.okx.com/docs-v5/en/#funding-account-rest-api-get-deposit-address)
(response schema, consulted 2026-07-19) plus the response-shape record carried in CCXT's own
`okx.ts` `parseDepositAddress` doc comments. **Tier 2 overall** — the live EEA demo cannot serve
this endpoint at all (`50038 "This feature is unavailable in demo trading"`, observed
2026-07-19), so no populated row was obtainable. The signed call *was* accepted and routed
(business error, not an auth error), which confirms transport but not field semantics. The
populated-state confrontation is filed in `docs/prod-verification-ledger.md`.

**C-T389a — `selected: true` is the row filter, not a hint (task 389). Outcome: CONFIRMED
against OKX deposit-address semantics.**

- *Exchange semantics:* OKX returns **every** address it has issued for a currency, one row per
  (chain, address) pair. `selected` marks the address currently attached to the account; the
  unselected rows are historical. Multiple rows routinely share one `chain`.
- *Our carve:* drop every row where `selected != true` before parsing, authored as
  `deposit_address.row_filter`. Without it the parser returns whichever row happens to sort
  first, which the fixtures show is frequently a stale address — a fund-loss surface, not a
  cosmetic mismatch.
- *Compatibility:* matches CCXT `filterBy(data, 'selected', true)`. Fixtures #18 and #22 are
  precisely the case where the first row is unselected and the correct answer is the second.

**C-T389b — The unified network is derived from `chain`, currency-scoped (task 389). Outcome:
CONFIRMED against OKX chain naming.**

- *Exchange semantics:* `chain` is a composite `"<currency>-<network>"` id (`USDT-TRC20`,
  `BTC-Bitcoin`, `ETHK-OKTC`). The currency prefix is **not** always the row's `ccy` (`ETHK-OKTC`
  carries `ccy: "ETH"`), so the network cannot be recovered by stripping `ccy` — the whole chain
  id must be looked up.
- *Our carve:* a `network_code` field kind resolves the full chain id through the authored alias
  table (`"USDT-TRC20" → TRC20`, `"BTC-Bitcoin" → BTC`). The table is shared verbatim with the
  currency slice's `network_aliases` — the frozen projection of CCXT's two-step
  `currency['networks']` lookup + `networkIdToCode`. Agreement between the two tables is
  asserted in `test/bourse/okx_authored_spec_test.exs`, so they cannot drift apart silently.
- *Currency-scoped codes are deliberate:* `USDT-ERC20 → ERC20` but `ETH-ERC20 → ETH`. This is
  CCXT's `defaultNetworkCodeReplacements` collapsing a currency's native chain onto its own
  code, and the fixtures pin both halves.
- *One inherited naming choice, adopted knowingly:* `POL-Polygon → MATIC`. Polygon rebranded
  MATIC→POL in 2024 and OKX's own chain string says `Polygon`, but the unified code stays
  `MATIC` to match the rest of the catalog's network vocabulary. This is a **compatibility**
  choice, not an exchange-semantics claim.

**C-T389c — An unaliased chain yields `network: nil`, and the row is dropped from the dict
(task 389). Outcome: DIVERGE — deliberate, CCXT-compatible limitation.**

- *Exchange semantics:* OKX adds chains continuously; any frozen table is a snapshot.
- *Our carve:* `network_code` is **strict** — a chain id absent from the alias table resolves to
  `nil`, never to the raw id. `index_by_network` then drops that row from
  `fetchDepositAddressesByNetwork`, and `fetchDepositAddress` cannot select it.
- *Why strict:* emitting the raw `"USDT-Foo"` as if it were a unified network code would be an
  invented value that no caller can match against, and it would silently diverge from every
  other venue's network vocabulary. CCXT misses identically (its `networksById` lookup returns
  undefined and `indexBy` drops the entry), so this is the compatible behaviour as well as the
  honest one.
- *Known consequence:* a newly-listed OKX chain is invisible until the alias table is
  re-authored. **Partially superseded by C-T421** (task 421): a chain the loaded currency
  catalog knows is now recovered from it. The nil-on-total-miss contract is unchanged.

**C-T421 — The currency catalog recovers chains the aliases never saw, but does not outrank
them (task 421, extended by tasks 426, 430, and 441). Outcome: CONFIRMED against CCXT
`okx.parseDepositAddress` and `Exchange.networkIdToCode` source; OKX's own chain naming
adjudicates Optimism as `OP`; the fixture vintage skew is closed, with one upstream bybit skew
explicitly retained (task 430).**

- *Exchange semantics:* CCXT resolves the chain in **two** steps —
  `networksById = indexBy(currency['networks'], 'id')`, take `networkData['network']`, then
  `networkIdToCode(network, code)` (`js/src/okx.js:5310-5358`). The catalog supplies only step
  one: its value is a network **id**, not yet a unified network code.
- *Our carve:* both sources now complete both CCXT steps. Catalog-only chains run their catalog
  `network` id through `networkIdToCode` — the venue's `options.networksById`, which per
  `Exchange.createNetworksByIdObject` is the **inversion of `options.networks`** with the
  authored `networksById` extended over it, followed by CCXT's base
  `defaultNetworkCodeReplacements`. The inversion is load-bearing: okx's `describe` ships 3
  `networksById` overrides against 73 `networks` entries, so without it the port would be a
  near-identity. Currency lookup applies `safeCurrency` aliases before indexing the catalog.
  This supersedes C-T389c's "strict nil" consequence for the catalog-covered case; the
  nil-on-total-miss contract is unchanged.
- *Measured, real spec + real currencies cache* (`mix run`, not a hand-built table):
  `Optimism → OPTIMISM` (via inverted `networks`), `ERC20 + ETH → ETH` and `ERC20 + USDT →
  ERC20` (via the replacements table). Both are cases where the network **id** differs from
  the unified code, which is the behaviour task 426 was after.
- *Historical reference-corpus outcome (task 430):* the OKX response and currencies
  reference files were aligned to the same upstream revision on 2026-07-19.
  `USDT-Optimism` reads `OP` from both.
- *Optimism adjudication (task 441):* **`OP` is the unified code.** [OKX's own deposit and
  withdrawal announcement](https://www.okx.com/en-us/help/okx-to-support-the-optimism-op-network-upgrade-and-hard-fork)
  calls this the "Optimism (OP) network" and says deposits and withdrawals of `OP` resume on the
  "OP network"; its [native-USDC announcement](https://www.okx.com/en-us/help/okx-to-support-native-usdc-on-optimism-and-polygon-networks)
  separately calls the chain "the Optimism network." Thus `Optimism` is the exchange's
  descriptive chain name, while `OP` is its code. Both authored aliases (`ETH-Optimism` and
  `USDT-Optimism`) emit `OP` in both the deposit-address and currencies slices. This adjudication
  rests on OKX documentation rather than the tier-2 fixture alone, which independently agrees.
  `fetchDepositAddressesByNetwork #23` is green and off the replay baseline. `fetchCurrencies
  default #17` reaches network-key parity — both sides now emit `op`, and neither emits
  `optimism` — and C-T442f adjudicates the remaining `active` mismatch as deliberate. The
  integer/float values printed in the full diff are comparator-equivalent, not a second red axis.
- *Residual, and it is upstream's, not ours:* the same sweep found bybit's `OP` chain
  disagreeing at 4.5.65 — from one raw row, CCXT's own `currencies/` snapshot says `OPTIMISM`
  while its `response/` snapshot says `OP`, because upstream never regenerated the cache after
  its network-code rename. No CCXT release makes those two agree, so pinning cannot fix it and
  editing the vendored cache would fabricate a code no release contains. It is recorded as an
  adjudicated baseline entry instead. This does not touch okx's ordering decision below.
- *Ordering decision:* **retain alias-first.** Aliases answer for chains they know; the catalog
  remains the recovery path for newly listed chains, emitting the cache's CCXT unified code
  when the venue tables cannot further map it. The unit test that preserves an unmapped catalog
  value (`OP`) still protects `networkIdToCode`'s identity behavior.
- *Narrowing vs CCXT:* `prioritizedNetworkAliases`' `allowDefault` branch and the
  `currencyCode === undefined` `options.networks` disambiguation are not ported — this call
  path always has a currency code (`catalog_network_code/3` guards `is_binary(currency)`), so
  neither branch is reachable.

**C-T389d — Tag carrier precedence (task 389). Outcome: CONFIRMED against OKX response
schema.**

- *Exchange semantics:* the memo/tag travels in one of four places depending on currency —
  top-level `tag`, `pmtId`, or `memo`, or nested `addrEx.comment` (the documented carrier for
  TON-family currencies). All four are optional and routinely absent.
- *Our carve:* `tag` reads `tag` → `pmtId` → `memo` → `addrEx.comment`, first non-nil wins,
  authored as a `fallback_keys` chain (the dotted path reaches the nested key). Mirrors CCXT's
  `safeStringN(['tag','pmtId','memo'])` with the `addrEx.comment` fallback.
- *Tier-2 caveat:* every fixture row that reaches the parser has `tag: nil`, so the **ordering**
  is authored from the documented schema, not observed. The TON row carrying `addrEx.comment`
  exists in fixture #18's payload but is never the selected result. Confrontation deferred to
  the prod-verification ledger.

**C-T389e — Requested-network miss is an error, not a fallback (task 389). Outcome: CONFIRMED
against CCXT `InvalidAddress` semantics.**

- *Exchange semantics:* the venue has no notion of "the requested network" — it returns all
  chains and the client selects.
- *Our carve:* `fetchDepositAddress` with an explicit `network` selects the matching row or
  fails with `{:requested_row_not_found, network}`. With no `network`, precedence is
  `default_networks[code]` (authored `BTC→BTC`, `ETH→ERC20`, `USDT→TRC20`) → the code read as a
  network → first remaining row.
- *Why not fall back on a miss:* returning some other chain's address for a network the caller
  explicitly asked for sends funds to the wrong chain. CCXT throws `InvalidAddress` here for the
  same reason; a silent substitution would be a fund-loss divergence.
- *Compatibility:* fixture #19 pins the explicit-network branch (`POL`/`MATIC` selects
  `POL-Polygon` over the first-listed `POL-ERC20`); #22 pins the `defaultNetworks` branch
  (`USDT` with no network selects TRC20).

## Task 394 — loaded-market order precision (2026-07-19)

**C-T394 — Place/amend `sz` and `px` precision (task 394). Outcome: CONFIRMED against OKX V5
instruments semantics.**

- *Exchange semantics:* the [OKX V5 Get instruments](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-instruments)
  response defines `lotSz` as the quantity increment and `tickSz` as the price increment;
  place/amend bodies carry `sz`/`px` and `newSz`/`newPx` as strings. The documentation requires
  an instrument-conforming value but does not prescribe a client-side rounding algorithm.
- *Our carve:* use the caller-threaded loaded market precision derived from that instrument
  response. Amounts truncate toward zero to `lotSz`; prices round to the nearest `tickSz`
  (`half_up`) before stringification. This prevents invalid precision reaching the venue while
  keeping the decision tied to live instrument metadata rather than a frozen spec.
- *Precision is an increment, not a decimal-place count* — confirmed live against
  `my.okx.com /api/v5/public/instruments` (2026-07-19): `BTC-USDT` parses to
  `%{"amount" => 1.0e-8, "price" => 0.1}`, i.e. `lotSz`/`tickSz` verbatim. This is the axis on
  which the bybit sibling differs (its `_builder` precision is a decimal-place integer), so the
  two builders deliberately do NOT share a rounding helper.
- *Sub-lot / sub-tick inputs are forwarded unrounded, not zeroed.* Truncating an amount below
  one `lotSz` yields `0`, and no client-side rounding can satisfy such a request. Shipping
  `sz: "0"` would replace the caller's intent with a value OKX rejects on an opaque parameter
  error, so the original value rides to the wire and the venue answers with 51121/51006 naming
  the size actually requested. Enforcing `minSz` client-side is deliberately not carved here.
- *Compatibility:* CCXT-JS `amountToPrecision` / `priceToPrecision` remains a tier-2 reference
  only. The offline captures pin `0.000109` → `0.0001` at lot size `0.00001` and `31998.09` →
  `31998.1` at tick size `0.1` for both place and amend bodies, plus the sub-lot passthrough and
  raw-map market cases.

## Task 388 — market-data response semantics (2026-07-19)

Evidence sources: [OKX API v5 Market Data](https://www.okx.com/docs-v5/en/#rest-api-market-data)
(Candlesticks, Open interest, and Status sections, consulted 2026-07-19). Public calls were
observed against the live OKX host; signed funding-bill reads used EEA demo (`my.okx.com` +
`sandbox: true`). CCXT static fixtures are compatibility references only.

**C-T388a — Funding payment bill row. Outcome: CONFIRMED against OKX account-bills semantics (task 388).**

- *Exchange semantics:* a funding payment is an account-bill row. `billId` identifies the row,
  `balChg` is the signed account-balance change, `ccy` is its currency, and `ts` is Unix ms.
  `instId` supplies the market identity; the bills response does not contain the applied funding
  rate.
- *Our carve:* map `billId`, `balChg`, `ccy`, and `ts` into `FundingHistory`; retain `rate: nil`
  instead of deriving one from the payment amount or price. The request symbol remains authority
  for the unified market, as it disambiguates the funding-bill row.
- *Compatibility:* fixture #24 is green. The current EEA demo account returns a successful empty
  bills list, so a populated current funding-payment row is tracked in the production ledger.

**C-T388b — Candlestick chronology and volume. Outcome: CONFIRMED against OKX docs (task 388).**

- *Exchange semantics:* candle rows are `[ts, o, h, l, c, vol, volCcy, volCcyQuote, confirm]`;
  `ts` is opening Unix ms. `vol` is base quantity for SPOT/MARGIN and contracts for derivatives;
  `volCcy` is base quantity for derivatives but quote quantity for spot.
- *Our carve:* reverse OKX's newest-first `data` response before caller-side `since`/`limit`
  filtering. Preserve `vol` (array index 5) as unified OHLCV volume, which is the only field with
  a stable base-volume meaning for spot.
- *Tier-1 evidence:* live BTC-USDT 1h rows were populated and ascending after normalization;
  `NOPE/USDT` returned `51001` (unknown instrument) on 2026-07-19. Fixture #27 is green.

**C-T388c — Open interest quantities. Outcome: CONFIRMED against OKX docs (task 388).**

- *Exchange semantics:* open-interest rows expose `oi` in contracts, `oiCcy` in base currency,
  `oiUsd` in USD, and `ts` in Unix ms.
- *Our carve:* map those fields to `openInterestAmount`, `baseVolume`, `openInterestValue`, and
  timestamp/datetime respectively. We leave `quoteVolume` unset: `oiUsd` is USD regardless of
  the contract settlement currency and is not a quote-currency volume.
- *Tier-1 evidence:* a live `BTC-USDT-SWAP` row populated all three quantities; an invalid
  `instId` returned a typed `bad_symbol` error on 2026-07-19. Fixture #28 is green.

**C-T388d — Operational status. Outcome: CONFIRMED against OKX docs (task 388).**

- *Exchange semantics:* the system-status endpoint returns the normal `{code, msg, data}`
  envelope. `data` is the **maintenance-window collection**: an empty list represents normal
  operation, while each populated row carries `state`
  (`scheduled` / `ongoing` / `completed` / `canceled`), the window bounds `begin`/`end` (Unix ms),
  an announcement `href`, and a `serviceType`. A successful `code: "0"` therefore does **not**
  by itself mean the venue is operational.
- *Our carve:* normalize to CCXT's status shape
  `%{status, updated: nil, eta, url, info: raw}`. Empty `data` → `status: "ok"`. A populated
  `data` starts at `"maintenance"` and is then resolved per row: only `ongoing` degrades service;
  `scheduled` / `completed` / `canceled` windows remain `"ok"`. `eta` is the row's `end` and
  `url` its `href`, so a caller can surface an upcoming window even while operational. Nonzero
  business codes remain typed exchange errors and cannot be reported as operational success.
- *Compatibility:* fixture #39 (`data: []`) is green, but it exercises **only** the empty-window
  path — it cannot falsify the maintenance branch, so the populated-row semantics above are
  authored from the OKX schema (tier 1, non-CCXT) and pinned by offline unit tests rather than by
  the fixture. The zero-argument endpoint exposes no safe invalid request state, and a live
  maintenance window is not summonable on demand; the ledger records the exact unavailable state.

## 2026-07-19 — plain-order defaults for multi-endpoint no-arg reads (Task 378)

**C-T378f — OKX no-arg multi-endpoint defaults prefer plain orders over algo (task 378).**
Outcome: CONFIRMED. Several OKX unified lists put algo surfaces first
(`orders-algo-pending`, `orders-algo-history`). Authored `endpoint_selection` defaults pin
plain `orders-pending` / `orders-history`, `account/balance`, `account/positions`, and
`account/bills` for no-arg reads; algo/history/funding branches remain available via
`ordType` / `type` rules. No venue-level `default_family` (OKX is instType-shaped, not
fapi/dapi-family).

## Task 385 — createOrder / editOrder / fetchMyTrades request builds (2026-07-19)

Evidence sources: [OKX API v5 Trade](https://www.okx.com/docs-v5/en/#order-book-trading-trade) Place
order / Amend order / Transaction details (last 3 days) sections (consulted 2026-07-19). Live
checks use the EEA demo host (`my.okx.com` + `sandbox: true`). CCXT-JS `okx.ts`
`createOrderRequest` / `fetchMyTrades` are compatibility references only.

**C-T385a — Singular place-order surface. Outcome: DIVERGE from CCXT batch default (task 385).**

- *Exchange semantics:* `POST /api/v5/trade/order` accepts a **JSON object** body. The batch
  sibling `POST /api/v5/trade/batch-orders` requires a **JSON array** and returns `50002
  Incorrect json data format` when given an object (live EEA demo + offline capture pre-fix).
- *Our carve:* authored `endpoint_selection.createOrder.default = trade/order`. We do **not**
  follow CCXT-JS's habit of sending a single-element array to `batch-orders` for ordinary
  `createOrder`. Batch construction stays out of scope (`createOrders`).
- *Compatibility:* tier-2 fixtures show CCXT-JS batch-wrapping; our wire form is the singular
  object on `trade/order` by deliberate choice.

**C-T385b — Trade mode selection. Outcome: CONFIRMED-against-OKX docs (task 385).**

- *Exchange semantics:* place-order requires `tdMode`. Documented values include `cash` (spot
  non-margin), `cross`, and `isolated`. Derivatives use cross/isolated margin modes, not cash.
- *Our carve:* default `cash` when the instrument is spot (`BASE-QUOTE` id with two segments);
  default `cross` for swap/future/option ids. Explicit caller `tdMode` / `marginMode` /
  `margin_mode` always wins.
- *Compatibility:* matches the common CCXT-JS outcomes on spot (`cash`) and swap (`cross`)
  fixtures without inheriting CCXT's broader margin/tgtCcy branching as a hard dependency.
  Body field set for ordinary limit: `instId`/`tdMode`/`ordType`/`side`/`sz`/`px` as strings.

**C-T385c — Singular amend-order surface. Outcome: CONFIRMED-against-OKX docs (task 385).**

- *Exchange semantics:* `POST /api/v5/trade/amend-order` amends a live order via `instId` +
  `ordId` (or `clOrdId`) and optional `newSz`/`newPx` (strings).
- *Our carve:* `endpoint_selection.editOrder.default = trade/amend-order` (not
  `trade/amend-algos`, which was the previous `hd(configs)` default). Unified `amount`/`price`
  map to `newSz`/`newPx`. Algo amend is selected when `type`/`ordType` is an algo family or
  `algoId` is present (task 387).
- *Compatibility:* matches CCXT static amend-order fixtures for spot price/size edits.

**C-T385d — 3-day fills vs 3-month fills-history. Outcome: DIVERGE from CCXT-JS (task 385).**

- *Exchange semantics:* `GET /api/v5/trade/fills` is **Transaction details (last 3 days)** —
  `instType` is optional. `GET /api/v5/trade/fills-history` is the **last 3 months** archive
  and **requires** `instType` (live EEA demo returns `50014 Parameter instType can not be empty`
  when it is omitted; pre-fix capture sent `?symbol=BTC-USDT` on fills-history).
- *Our carve:* `endpoints.unified.fetchMyTrades = [privateGetTradeFills]` and request shape
  renames unified `symbol` → `instId` with no raw `symbol` key and no invented `instType`.
  This is a deliberate shorter lookback than CCXT-JS's fills-history default so a plain
  `fetch_my_trades(ex, symbol: "BTC/USDT")` never 50014s for missing `instType`.
- *Tier-1 evidence:* live EEA demo after the fix returns `{:ok, list}` (empty allowed) without
  50014; offline capture pins `GET /api/v5/trade/fills?instId=BTC-USDT`.

**C-T385e — Fills window parameter. Outcome: CONFIRMED-against-OKX docs (task 385, review).**

- *Exchange semantics:* `/api/v5/trade/fills` filters its window with `begin`/`end` (Unix ms);
  `after`/`before` are bill-id pagination. There is no `since` parameter, and OKX **ignores**
  unknown query keys rather than rejecting them.
- *Our carve:* unified `since` → `begin`. Left unmapped it produced
  `?instId=BTC-USDT&since=…` — accepted by the venue and silently unfiltered, so the caller's
  window vanished with no error. That silent drop is worse on the 3-day `fills` route chosen in
  C-T385d than it would be on the 3-month archive. `limit` is already OKX's own name and passes
  through unchanged.

## Task 387 — Algo, attached TP/SL, trigger, trailing, amend/cancel families (2026-07-21)

Evidence sources: [OKX API v5 Algo trading](https://www.okx.com/docs-v5/en/#order-book-trading-algo-trading)
Place algo order / Amend algo order / Cancel algo order / Cancel all after sections
(consulted 2026-07-21). Live checks use the EEA demo host (`my.okx.com` + `sandbox: true`).
CCXT-JS `okx.ts` `createOrderRequest` / static request fixtures are compatibility evidence only.

**C-T387a — Algo endpoint selection. Outcome: CONFIRMED-against-OKX docs (task 387).**

- *Exchange semantics:* standalone trigger / conditional (one TP/SL leg), OCO (both TP and SL),
  and trailing (`move_order_stop`)
  orders go to `POST /api/v5/trade/order-algo`. Attached TP/SL on a primary normal order
  (`attachAlgoOrds`) stays on `POST /api/v5/trade/order`. Algo amend is
  `POST /api/v5/trade/amend-algos` (`algoId`); normal attached-order amendment stays on
  `trade/amend-order` and nests the changes under `attachAlgoOrds`. Dead-man switch is
  `POST /api/v5/trade/cancel-all-after` with String `timeOut` in **seconds** and optional `tag`.
- *Our carve:* authored `endpoint_selection.createOrder` cases on `stopPrice` /
  `triggerPrice` / `takeProfitPrice` / `stopLossPrice` / trailing keys / algo `ordType`s →
  `trade/order-algo`; default remains `trade/order` (C-T385a). `editOrder` cases on
  `type`/`ordType` in `{conditional,oco,trigger,move_order_stop}` or present `algoId` →
  `trade/amend-algos`. `cancelAllOrdersAfter` defaults to `trade/cancel-all-after` and maps
  unified `timeout` ms → String `timeOut` seconds (0 clears); native `timeOut` is already
  seconds and is not divided again.
- *Tier-1 evidence (EEA demo 2026-07-21):* `cancelAllOrdersAfter(10000)` returns `code "0"`
  with a `triggerTime`, and `0` clears it; an invalid tag reaches business validation as `51000`.
  Missing-algo cancel returns `sCode 51400`; missing-algo amend returns `sCode 51527`;
  trigger/conditional/OCO/trailing/attached place calls reach the venue and answer `sCode 51155`
  (local compliance) — never `50002` malformed body. The tagged integration tests pin these
  outcomes and clean up any unexpected successful place before failing. Success-path resting
  orders remain blocked by the existing
  [production-verification ledger](../prod-verification-ledger.md) entry for OKX place/cancel
  lifecycle (task 363 / C-T363, reconfirmed task 385/387).

**C-T387b — Native algo field names and applicability. Outcome: CONFIRMED-against-OKX docs (task 387).**

- *Exchange semantics (ordType-specific):*
  - `trigger`: `triggerPx` + `orderPx` (`-1` = market)
    plus optional `triggerPxType`; its client identifier is `algoClOrdId`
  - `conditional`: one TP or SL leg; `oco`: both legs. They use
    `tpTriggerPx`/`tpOrdPx`/`tpTriggerPxType` and
    `slTriggerPx`/`slOrdPx`/`slTriggerPxType` (default trigger type `last`)
  - `move_order_stop`: `callbackRatio` (fraction) **or** `callbackSpread` (absolute),
    plus optional activation price `activePx`
  - attached: `attachAlgoOrds: [{sl*, tp*…}]` on the primary order body
  - `closeFraction` closes by fraction and must not also send `sz`
- *Our carve:* map unified scalars/maps into those native keys only; do **not** echo unified
  `stopLossPrice` / `takeProfit` / `trailingPrice` on the wire (CCXT fixtures sometimes do).
  `trailingPercent` is always a human percent (`"5"` → `"0.05"`, `"0.5"` → `"0.005"`),
  while native `callbackRatio` is already fractional. Spot algo rows keep `tdMode: cash`
  (C-T385b), not CCXT-JS's spot-algo `cross` default.
- *Amend applicability:* trigger amendments use `newTriggerPx` / `newOrdPx` /
  `newTriggerPxType`; trailing amendments use `newCallbackRatio` or `newCallbackSpread`
  plus optional `newActivePx`; stop/OCO amendments use the `newTp*` / `newSl*` families.
  Normal attached amendments put those `newTp*` / `newSl*` keys inside
  `attachAlgoOrds`, with the attachment identifier when supplied.
- *Compatibility residuals (explained, not chased):* singular `trade/order` vs CCXT
  batch-orders for attached/normal place (C-T385a); string vs bare-number `newSlOrdPx` /
  `newTpOrdPx` on amend (OKX documents strings); String `timeOut` vs CCXT's numeric JSON;
  `algoClOrdId` vs CCXT fixtures that reuse normal `clOrdId`; omission of echoed unified keys
  and of CCXT's residual `trailingPrice` duplicate beside `callbackSpread`.
- *Retired compatibility-baseline inventory:* eight deliberate divergences were tied to this
  carve: `cancelAllOrdersAfter #224/#225`, trailing-price `createOrder #187`, and
  `editOrder #107/#106/#103/#105/#104`.

**C-T387c — Spot algo `tdMode` stays cash. Outcome: DIVERGE from CCXT-JS (task 387).**

- *Exchange semantics:* place-algo accepts `cash` / `cross` / `isolated`. Spot non-margin is
  `cash` (same as place-order).
- *Our carve:* keep the C-T385b spot→`cash` rule for algo rows too. CCXT static fixtures send
  `tdMode: "cross"` for some spot conditionals; we do not inherit that.
- *Live:* EEA demo returns `51155` after accepting the body shape (same as normal place), so
  the cash default is not rejected as a schema error.
- *Retired compatibility-baseline inventory:* three deliberate divergences were tied to this
  carve: spot stop-loss buy `#167`, spot stop-loss sell `#168`, and spot take-profit buy `#166`.

## Task 483 — Order-read and market-with-cost request builds (2026-07-22)

Evidence sources: [OKX API v5 Trade](https://www.okx.com/docs-v5/en/#order-book-trading-trade)
Open orders / Order history / Order history (last 3 months) / Get order details sections, and
[Algo trading](https://www.okx.com/docs-v5/en/#order-book-trading-algo-trading) Pending algo
orders / Algo order history / Get algo order details sections (consulted 2026-07-22). CCXT-JS
static request fixtures remain compatibility evidence only.

**C-T483a — Order-read route, identifier, and state selection. Outcome: CONFIRMED against OKX docs (task 483).**

- *Exchange semantics:* regular open orders use `GET /api/v5/trade/orders-pending` with optional
  `instId`; normal history uses `orders-history` or `orders-history-archive` with `state` such as
  `filled` or `canceled`. Algo pending/history are separate routes and require the matching
  `ordType`; completed algo rows use `state=effective`. Algo details use `algoId` on
  `GET /api/v5/trade/order-algo`, not a normal `ordId`.
- *Our carve:* all unified order-read `symbol` values bind to `instId` and never reach the wire as
  an unknown `symbol` query key. Unified `stop` / `trigger` / `trailing` select the algo route and
  derive `conditional` / `trigger` / `move_order_stop` when no `ordType` is supplied. Closed and
  canceled reads supply `filled` / `canceled`; algo-closed reads instead supply `effective`.
  The archive selector remains an explicit `method` choice and is removed before dispatch.
- *Tier-1 evidence:* the signed EEA demo (`my.okx.com`, `sandbox: true`) accepted regular and
  algo order-read requests carrying `instId`, `state`, and `ordType` with top-level `code: "0"` on
  2026-07-22. Deliberately invalid `instType=NOPE` reached the venue and returned `51000`, rather
  than being dropped or rejected by the client. The static request cases #120–#126, #144–#148,
  #189–#193, and #228 now also serve as tier-2 compatibility regressions.

**C-T483b — Market-with-cost uses the singular place-order body. Outcome: DIVERGE from CCXT-JS (task 483).**

- *Exchange semantics:* `POST /api/v5/trade/order` accepts one JSON object. For a spot market
  order, `tgtCcy=quote_ccy` makes `sz` quote-denominated; it is the provider-owned expression of
  unified `cost` rather than a base-amount `sz`.
- *Our carve:* `createMarketBuyOrderWithCost` and `createMarketSellOrderWithCost` select the same
  singular `trade/order` endpoint as C-T385a. They build `ordType=market`, map `cost` to `sz`, and
  set `tgtCcy=quote_ccy` only for spot instruments. OKX documents `tgtCcy` as "Only applicable to
  SPOT Market Orders", so a derivative has **no** wire form for quote-denominated cost — its `sz`
  is always a contract count. The build therefore **raises** on a non-spot instrument rather than
  shipping `sz = cost` as contracts, which would silently place a wrong-sized order. This matches
  CCXT-JS, which throws `NotSupported` for non-spot on both methods.
- *Compatibility:* CCXT-JS's #88/#100 fixtures post a one-row array to `trade/batch-orders`.
  The retired compatibility baseline carried both as deliberate C-T483b divergences:
  `createMarketBuyOrderWithCost #88` and `createMarketSellOrderWithCost #100`.
- *Tier-1 evidence:* on 2026-07-22 the EEA demo reached business validation on a spot
  market-with-cost request sized below the venue minimum and returned a `51`-class business code;
  it did not create or fill an order. The derivative path is pinned offline by the raise, so no
  wrong-sized contract order is ever sent.

## Task 361 — Normal batch-order request contracts (2026-07-19)

Evidence sources: [OKX API v5 Trade](https://www.okx.com/docs-v5/en/#order-book-trading-trade-post-place-multiple-orders)
Place multiple orders, Cancel multiple orders, and Amend multiple orders sections (consulted
2026-07-19). Live checks use the EEA demo host (`my.okx.com` + `sandbox: true`). CCXT-JS static
request fixtures are compatibility references only.

**C-T361a — Batch place uses normal-order rows. Outcome: CONFIRMED-against-OKX docs (task 361).**

- *Exchange semantics:* `POST /api/v5/trade/batch-orders` requires a root JSON array. Each row
  owns its `instId`, `tdMode`, `side`, `ordType`, `sz`, and applicable normal-order fields; it is
  not an object containing an `orders` member. `sz` and `px` are strings.
- *Our carve:* each unified row runs through the authored normal `createOrder` body builder, so
  spot rows use `tdMode: cash`, derivatives use `cross` unless overridden, and native keys such
  as `clOrdId`, `posSide`, and `stpMode` are emitted per row. Attached TP/SL (`attachAlgoOrds`)
  is owned by task 387 on the singular place path; batch rows inherit the same builder.
- *Compatibility:* the bundled `createOrders` fixtures also use `trade/batch-orders` and an
  array, but their generated broker ids are not adopted as a requirement.

**C-T361b — Batch amend is a separate normal-order surface. Outcome: CONFIRMED-against-OKX docs (task 361).**

- *Exchange semantics:* `POST /api/v5/trade/amend-batch-orders` takes an array of normal amend
  rows. Each row identifies the normal order with `instId` plus `ordId` or `clOrdId`, and names
  its replacement fields `newSz` and `newPx`.
- *Our carve:* author `editOrders` to this endpoint and shape every row via the existing normal
  `editOrder` mapping. `cxlOnFail` and `reqId` may be shared or per-row; per-row values win.
  Singular algo amend is `trade/amend-algos` (task 387); batch algo amend is not exposed.
- *Tier-1 evidence:* EEA demo accepts both shaped batch families through venue business handling;
  its local-compliance `51155` restriction can prevent a successful resting order. The existing
  [production-verification ledger](../prod-verification-ledger.md) entry remains the tracked
  success-path evidence; tests cancel every accepted batch order immediately.

## Task 363 — Order reads, fills, and action acknowledgements (2026-07-18)

### C-T363-order — Trade-order lifecycle fields. Outcome: CONFIRMED-against-OKX docs

- *Exchange semantics:* The OKX V5 trade order-details and order-history rows carry `ordId`,
  `clOrdId`, `cTime`, `uTime`, `fillTime`, `state`, `sz`, `accFillSz`, `px`, `avgPx`, and
  `reduceOnly`. `state` distinguishes `live`/`partially_filled`/`filled`/`canceled`; the three
  clocks are creation, last update, and last fill respectively.
- *Our carve:* map normal order ids from `ordId` (with `algoId` retained for algo rows), preserve
  the three clocks, map state to unified status, and derive remaining only from the row's
  `sz - accFillSz`. `sz` is never mapped to order `cost`: a spot market buy can denominate it in
  quote currency, so treating it as filled quote cost would invent a semantic the row did not
  provide.
- *Compatibility:* the bundled CCXT `okx.parseOrder` is the tier-2 reference for the same id,
  status, clock, and fill vocabulary. The authored fixture test covers a partially-filled row.

### C-T363-ack — Place/cancel order responses are sparse acknowledgements. Outcome: DIVERGE from padding

- *Exchange semantics:* successful place/cancel responses return per-operation rows with
  `ordId`, `clOrdId`, `sCode`, and `sMsg`; they are not order-detail rows and do not assert order
  state, size, price, fill, cost, or timestamps.
- *Our carve:* retain the identifiers and raw acknowledgement only. Every absent order field stays
  `nil`; no zero fill, zero cost, request timestamp, or request amount is manufactured.
- *Tier-1 evidence:* EEA demo `my.okx.com` accepted the shaped request and returned its own
  populated per-operation error row (`sCode: 51155`, local-compliance restriction) on 2026-07-18.
  The environment blocks a successful lifecycle; the open live-success confirmation is filed in
  `docs/prod-verification-ledger.md`.

## Task 382 — Residual order, fill, and acknowledgement semantics (2026-07-21)

**C-T382a — Order details and fills share one instrument-invariant field contract. Outcome: CONFIRMED-against-OKX docs (task 382).**

- *Exchange semantics:* The OKX V5 order-details rows use `sz`/`accFillSz`, `px`/`avgPx`, signed
  `fee` plus `feeCcy`, and `ordType` for spot, margin, futures, swaps, and options. Fills use the
  same meanings under `fillSz`/`fillPx`, with `execType` `T`/`M` identifying taker/maker. The
  schema does not redefine these fields by instrument family; option size remains contracts and
  option price remains the quote in the contract's settlement currency.
- *Our carve:* derive order cost from `accFillSz × (avgPx ?? px ?? ordPx)`, negate the venue's
  signed fee into unified `fee.cost`, mirror the fee into `fees`, and normalize order type,
  time-in-force, and post-only state from `ordType`. Fill cost uses authored operand fallbacks
  (`sz`→`fillSz`, `px`→`fillPx`) and the same fee projection. Empty acknowledgement rows do not
  acquire an empty fee object.
- *Tier-1 evidence:* the first EEA-demo place attempt returned venue business code `51155`, so it
  created no order. The international demo then accepted a reversible far-from-market option
  order for `BTC-USD-260925-280000-C`: the populated detail row carried id, symbol, live state,
  buy side, limit type, price `0.0001`, size `1`, filled `0`, fee `0` in BTC, and creation/update
  clocks. The order was canceled and absence from open orders was verified. This option row plus
  the common OKX response schema establishes that the authored parser contract is not a
  spot/swap-only carve.
- *Compatibility:* `fetchOrder`, the populated normal-order `fetchOpenOrders`, and
  `fetchMyTrades` now match the bundled CCXT fixture semantics for price/cost/fees/type without a
  divergence contract.

**C-T382b — Sparse action responses do not echo request-only fields. Outcome: DIVERGE from CCXT request padding (task 382).**

- *Exchange semantics:* place-order acknowledgements return `ordId`, `clOrdId`, `tag`, `ts`,
  `sCode`, and `sMsg`; cancel acknowledgements return their identifiers, `ts`, `sCode`, and
  `sMsg`. They do not report the request's `side`, `type`, `reduceOnly`, `trigger`, or identifier
  list as parsed order state.
- *Our carve:* retain only fields present in the acknowledgement. Method-scoped
  `C-T382b` contracts gate CCXT's `createOrder` side/type/reduce-only echoes and
  `cancelOrders` client-id-list/reduce-only/trigger echoes; any regression that materializes one
  of those request-only values fails the contract.
- *Tier-1 evidence:* the successful international-demo option place acknowledgement contained
  only `clOrdId`, `ordId`, `sCode`, `sMsg`, `tag`, and `ts`; its cancel acknowledgement contained
  only `clOrdId`, `ordId`, `sCode`, `sMsg`, and `ts`, matching the OKX V5 schemas.

## Task 362 — Non-order account and conversion request semantics (2026-07-18)

Evidence sources: [OKX API v5](https://www.okx.com/docs-v5/en/) funding + trading-account REST sections
(consulted 2026-07-18). Live checks use the EEA demo host (`my.okx.com` + `sandbox: true`).

### C-T362-transfer — Funds transfer body. Outcome: CONFIRMED-against-OKX docs

- *Exchange semantics:* `POST /api/v5/asset/transfer` requires `ccy`, `amt` (**String**), `from`,
  `to` (account ids: funding `6`, trading/spot `18`), optional `type` (`0` = within-account).
- *Our carve:* bind `code`→`ccy`, `amount`→`amt` (string transform), `from_account`/`to_account`→
  numeric `from`/`to` via `options.accountsByType`, literal `type: "0"`.
- *Compatibility:* matches CCXT static request fixtures; amounts are strings on the wire.

### C-T362-transfer-state — Transfer lookup. Outcome: CONFIRMED-against-OKX docs

- *Exchange semantics:* `GET /api/v5/asset/transfer-state` takes `transId` (optional `type`);
  currency is **not** a documented query field.
- *Our carve:* bind unified `id`→`transId` (string); omit optional `code` from the wire.
- *Compatibility:* matches fixture `transId=0` without a leftover `params`/`code` bag.

### C-T362-convert-trade — Convert execute. Outcome: CONFIRMED-against-OKX docs (extends C-T308)

- *Exchange semantics:* `POST /api/v5/asset/convert/trade` requires `quoteId`, `baseCcy`,
  `quoteCcy`, `side`, `sz` (**String**), `szCcy`.
- *Our carve:* keep C-T308 renames; stringify `sz`. Authored `side: "sell"` sells `from_code`
  (matches the static fixture and the size-currency = source-currency convention).
- *Compatibility:* fixture `sz: "3"`; never executes a live conversion with a valid quote.

### C-T362-convert-history — Convert trade by client id. Outcome: CONFIRMED-against-OKX docs

- *Exchange semantics:* convert history accepts optional `clTReqId` (client order id).
- *Our carve:* bind unified `id`→`clTReqId` for `fetchConvertTrade`.
- *Compatibility:* matches fixture `clTReqId=12AB34`.

### C-T362-margin-bills — Margin adjustment history. Outcome: CONFIRMED-against-OKX docs

- *Exchange semantics:* margin add/reduce appear on account bills as `subType` `160` (add) /
  `161` (reduce); isolated mode is the documented margin-adjustment path CCXT fixtures pin.
- *Our carve:* map unified `type` `add`/`reduce`→`subType` `160`/`161`; default `mgnMode:
  isolated`.
- *Compatibility:* matches fixtures for bills query without inventing archive routing.

### C-T362-borrow-interest — Accrued interest filter. Outcome: CONFIRMED-against-OKX docs

- *Exchange semantics:* `GET /api/v5/account/interest-accrued` accepts `ccy`, `mgnMode`.
- *Our carve:* bind `code`→`ccy`; default `mgnMode: cross` (existing read default).
- *Compatibility:* fixture `ccy=USDT&mgnMode=cross`.

### C-T362-close-position — Dual-mode posSide. Outcome: CONFIRMED-against-OKX docs

- *Exchange semantics:* `POST /api/v5/trade/close-position` requires `instId`, `mgnMode`; in
  long/short mode also `posSide` (`long`/`short`), not order-side buy/sell.
- *Our carve:* default `mgnMode: cross`; map unified `side` `buy`→`long`, `sell`→`short`. An
  absent side is net mode and omits `posSide`; any other value is forwarded verbatim so OKX
  answers with its own error (CCXT's else-branch does the same, `okx.ts` `closePosition`).
  Dropping an unrecognised side would silently close a net-mode position instead.
- *Tier-1 evidence (live EEA demo, 2026-07-18):* `close_position("BTC/USDT:USDT", side: "shrot")`
  → `51000 "Parameter posSide error"` — the venue, not this client, rejects the bad side.
  A valid `side: "sell"` on the same pair returns `51155` (local compliance restriction), so
  the *accepted*-posSide branch is not reachable from this EEA demo key; that half stays tier-2
  (static request fixtures `closePosition` dual-mode #201/#202).
- *Compatibility:* dual-mode fixtures; out-of-scope for limit/market order construction.

### C-T362-leverage-margin-mode — Already authored (task 342). Outcome: CONFIRMED (no change)

- `setLeverage` / `setMarginMode` / `setPositionMode` / `addMargin` / `reduceMargin` request
  bindings were already green against fixtures and EEA demo (task 342). This task does not
  re-open those families; it only closes the residual non-order cluster above.

## Task 364 — Position response semantics (2026-07-21)

Evidence sources: [OKX API v5 — Account / positions](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-positions)
and [positions history](https://www.okx.com/docs-v5/en/#trading-account-rest-api-get-positions-history)
(consulted 2026-07-21). Authored from CCXT `okx.ts` `parsePosition` as a compatibility
reference; computed / branch-dependent values confronted against the official field meanings
plus a populated international-demo row. Response fixtures #34–#38 (fetchPosition linear
cross / inverse cross / inverse isolated / linear isolated + fetchPositions history) are
green offline.

### C-T364a — Open-position field meanings. Outcome: CONFIRMED-against-OKX docs + live intl demo

- *Exchange semantics (GET `/api/v5/account/positions`):*
  - `posId` — position identifier
  - `pos` — size (signed in net mode; absolute contracts)
  - `posSide` — `long` / `short` (hedge) or `net` (one-way)
  - `mgnMode` — `cross` / `isolated`
  - `avgPx` — average open price; `markPx` mark; `liqPx` estimated liquidation (empty = none)
  - `lever` — leverage
  - `imr` — initial margin (cross); `margin` — isolated margin balance
  - `mmr` — maintenance margin
  - `upl` / `uplRatio` — unrealized PnL and ratio
  - `notionalUsd` — USD notional (linear); inverse notional is coin-denominated
  - `realizedPnl` — realized PnL on the row
- *Our carve:*
  - `contracts = abs(pos)`; `side` from `posSide`/`direction`. Net-mode derivatives derive
    long/short from the sign of `pos`; net-mode `MARGIN` derives it from whether `posCcy`
    is the loaded market's base (long) or quote (short), because OKX margin `pos` is always
    positive. `hedged = (posSide !== "net")` **before** either conversion
  - linear `notional = notionalUsd`; inverse `notional = contracts × contractSize / markPx`
    (contract size from the loaded market cache)
  - cross: `initialMargin = imr`, `collateral = imr + upl`, `im% = imr/notional` truncated 4 dp
  - isolated: `collateral = margin`, `im% = 1/lever`, linear IM = im% × notional, inverse IM =
    `(contracts × cs / entry) / lever`
  - `mm% = truncate4(mmr/notional + 0.00005)`; `marginRatio = truncate4(mmr/collateral)`
  - `percentage = uplRatio × 100`
- *Tier-1 evidence (intl demo `www.okx.com` + sandbox, 2026-07-21):* market-buy 1 contract
  `BTC/USDT:USDT` → populated row with `posSide=net`, `side=long`, `hedged=false`,
  `contract_size=0.01`, non-null IM/MM/collateral/notional/percentage; singular
  `fetch_position` matches the list row; `close_position` returns to zero contracts.
  Cross collateral matched `imr + upl` within 1e-8. Unknown instrument → typed
  `:bad_symbol` / `51001`.
- *EEA demo (`my.okx.com`):* swap opens answer `sCode 51155` (local compliance). Empty
  `fetch_positions → []` is not semantic proof — ledgered as unreachable for *populated*
  rows; intl demo is the tier-1 vehicle.

### C-T364b — Positions-history field meanings. Outcome: CONFIRMED-against-OKX docs (tier-2 fixture + schema)

- *Exchange semantics (GET `/api/v5/account/positions-history`):* closed rows carry
  `openAvgPx` / `closeAvgPx` / `direction` / `realizedPnl` / `lever` / `mgnMode` / `posId`
  and **no** live `pos` / `markPx` / `imr` / `mmr` / `upl`.
- *Our carve:* history branch (guard `openAvgPx`) maps entry/last/side/realized/leverage/
  margin mode; leaves contracts/notional/collateral/unrealized/margins nil rather than
  inventing live margin from a closed row. Isolated history still stamps `im% = 1/lever`.
  `mm% = 0` matches the CCXT static fixture for missing mmr (compatibility, not a venue field).
- *Compatibility:* static response case #38 green. Live intl/EEA history lists were empty
  on 2026-07-21 (no closed rows on the demo accounts) — domain pins are offline + schema.

## Task 434 — Residual read and position request builds (2026-07-21)

Evidence sources: [OKX API v5](https://www.okx.com/docs-v5/en/) market-data, trading-account,
funding-account, and trading-statistics REST schemas (consulted 2026-07-21). CCXT-JS
4.5.65 and its static request fixtures are the tier-2 compatibility reference. All outcomes
below are confirmations; this task introduces no deliberate divergence.

**C-T434a — Order book, candles, tickers, and trades. Outcome: CONFIRMED-against-OKX docs
(task 434).**

- *Exchange semantics:* books take `instId` plus optional `sz`; candles take `instId`, `bar`,
  `limit`, and exclusive `before`/`after` history bounds; tickers take `instType`; trades take
  `instId`. History-candle and option-trade routes are distinct endpoints.
- *Our carve:* map unified depth to `sz`, cap ordinary history candles at 300, derive the
  candle window from the capped limit, derive ticker `instType` before the multi-symbol filter
  is removed, and route ordinary trades to `market/trades` (options to `public/option-trades`).
- *Tier-1 evidence:* EEA demo public calls against `my.okx.com` with `sandbox: true` returned
  populated BTC/USDT order-book, candle, swap-ticker, and trade results. The OHLCV success and
  invalid-instrument probes both exercised that host. Invalid instrument ids returned `51001`;
  invalid ticker `instType` returned `51000`. These endpoints are public under the OKX schema
  and therefore do not carry signed headers.

**C-T434b — Option chain, greeks, and open-interest history. Outcome: CONFIRMED-against-OKX
docs (task 434).**

- *Exchange semantics:* option tickers use `instType=OPTION` plus `uly`; option summaries use
  `uly`, `instFamily`, and optional `expTime`; contract open-interest history uses base `ccy`
  plus `period` on the Rubik contracts route.
- *Our carve:* expand a unified underlying such as `BTC` to `BTC-USD`, derive family/expiry
  from a single option symbol, and reduce a swap symbol to its base currency with default
  period `1D`. Option symbols select the option Rubik endpoint.
- *Tier-1 evidence:* EEA demo returned populated option-chain, greeks, and contract open-interest
  results. Invalid `instType`/`instFamily` returned `51000`; an unknown open-interest token
  returned `51012`.

**C-T434c — Ledger and deposit filters. Outcome: CONFIRMED-against-OKX docs (task 434).**

- *Exchange semantics:* account and funding bills accept `instType`/`ccy`; deposit history uses
  `ccy`, `before`, `after`, and `limit`. Account bills, archived bills, and funding bills are
  separate signed routes.
- *Our carve:* map `code` to `ccy`, default ledger `instType` from OKX's authored default type,
  route CCXT's explicit method selectors to the matching bill endpoint, and translate deposit
  time bounds to OKX's exclusive pagination names.
- *Tier-1 evidence:* signed EEA-demo ledger and deposit requests were accepted. Invalid
  `instType` and invalid `before` each returned `51000` with the valid demo credentials, proving
  request-shape validation rather than authentication failure.

**C-T434d — Position list, history, and singular filters. Outcome: CONFIRMED-against-OKX docs
(task 434; extended by task 456).**

- *Exchange semantics:* open positions accept comma-separated `instId`. OKX's official
  [positions-history endpoint](https://www.okx.com/docs-v5/en/#rest-api-account-get-positions-history)
  returns newest-first by `uTime`, accepts one `instId`, `limit`, `instType`, and `mgnMode`, and
  defines `after=T` as rows earlier than `T`. The official
  [pagination guide](https://www.okx.com/docs-v5/trick_en/#pagination) makes `after` exclusive and
  caps a page at 100 rows.
- *Our carve:* join requested native ids, emit a singular history id, default history limit to
  100, keep unified `since` as the existing local result filter, and map unified `until=T`
  directly to native `after=T`. Neither `since` nor `until` is a wire key. Native `after` is
  required so older qualifying rows remain reachable beyond the newest 100-row page. Derive the
  singular position `instType` from its native id.
- *Compatibility reference:* CCXT omits unified `until` and only filters `since` locally. That is
  compatibility behavior, not the exchange-owned pagination contract.
- *Tier-1 evidence:* all three signed EEA-demo reads were accepted (empty lists are valid for the
  account state). On 2026-07-22, EEA demo `my.okx.com` accepted the unified `until` request mapped
  to signed native `after` with code `0`; invalid history `instType` with the same bound returned
  `51000`. An unknown singular instrument returned `51001`.

## Task 475 — option underlying settle + open-interest period fail-loud (2026-07-22)

Evidence sources: OKX API v5 public/trading-statistics docs + live listings. Docs:
[Get underlying](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-underlying),
[Get instruments](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-instruments)
(`uly` / `instFamily` e.g. `BTC-USD` for OPTION),
[Get option market data / opt-summary](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-option-market-data),
[Get contracts open interest and volume](https://www.okx.com/docs-v5/en/#trading-statistics-rest-api-get-contracts-open-interest-and-volume)
(`period` enum `5m`/`1H`/`1D`),
[Get options open interest and volume](https://www.okx.com/docs-v5/en/#trading-statistics-rest-api-get-options-open-interest-and-volume)
(`period` enum `8H`/`1D`). Live (2026-07-22, `www.okx.com`):
`GET /api/v5/public/underlying?instType=OPTION` returned only
`SOL-USD`/`BTC-USD`/`ETH-USD`/`XAU-USD`; contracts OI with bad `period` returned
`51000 … support [5m,1H,1D]`. CCXT fixtures remain tier-2 compatibility only.

**C-T475a — Option underlying settle is registered USD-only (task 475). Outcome:
CONFIRMED-against-OKX docs + live listing.**

- *Exchange semantics:* option `uly` / `instFamily` are `BASE-SETTLE` identifiers
  (docs examples `BTC-USD`). The underlying listing endpoint is the authority for
  which settle families exist.
- *Our carve:* bare bases such as `BTC` expand only to `BTC-USD`. Explicit
  `BASE-USD` families pass. Any other settle (e.g. `BTC-USDT`) or non-family shape
  (e.g. `BTC/USD`) raises `ArgumentError` naming the input and the registered settle —
  never silently rewrite a non-USD family to `-USD`.
- *Premise assertion:* offline request-shape tests pin USD expansion and the
  non-USD raise, and assert that every option symbol in the frozen authored spec
  belongs to a USD family. Adding a non-USD option family to the spec fails that
  assertion until this carve and the settle constant are updated.
- *Tier-1 evidence:* live OPTION underlying list was exclusively `*-USD` (2026-07-22);
  `uly=BTC-USDT` instruments returned an empty set.

**C-T475b — Open-interest history `period` is a closed map (task 475). Outcome:
CONFIRMED-against-OKX docs + live rejection.**

- *Exchange semantics:* contracts Rubik `period` is `5m`/`1H`/`1D` (docs; live
  `51000` names the same set). Option Rubik `period` is `8H`/`1D`. Default for our
  unified history builder remains `1D` (works on both routes; contracts docs default
  is `5m`, which we deliberately do not change here).
- *Our carve:* map unified aliases within each endpoint's closed set (`1h`→`1H`
  for contracts, `8h`→`8H` for options, and `1d`→`1D` for both). An unmapped or
  wrong-endpoint timeframe raises locally with that endpoint's supported values
  named — no pass-through of venue-unknown strings.
- *Premise assertion:* offline tests accept each documented endpoint set and reject
  unknowns (`15m`) plus cross-endpoint values (`8H` for contracts, `5m` for
  options). An unknown Rubik endpoint also fails rather than inheriting the
  contracts set. Adding an endpoint or venue period requires extending the
  matching map and this carve together.
- *Tier-1 evidence:* live contracts OI accepted `5m`/`1H`/`1D` and rejected
  `1W`/`bogus` with `51000` naming `[5m,1H,1D]`; option OI accepted `8H`/`1D` and
  rejected `5m`/`1H`.

## Task 485 — contracts open-interest history column parse (2026-07-22)

**C-T485a — Contracts Rubik history rows are USD value/volume columns (task 485). Outcome:
DIVERGE from C-T388c's object-row mapping; CONFIRMED against OKX docs and live EEA demo.**

- *Exchange semantics:* `GET /api/v5/rubik/stat/contracts/open-interest-volume` returns
  `[ts, oi, vol]`. OKX defines `oi` as total open interest in USD and `vol` as total
  trading volume in USD. This differs from C-T388c's current-open-interest object rows,
  where `oi`, `oiCcy`, and `oiUsd` separately expose contracts, base currency, and USD.
- *Our carve:* the array branch maps index `0` to timestamp/datetime, index `1` to
  `openInterestValue`, and index `2` to `quoteVolume`. It leaves `openInterestAmount`
  and `baseVolume` unset because the contracts-history endpoint provides neither
  contract count nor base-currency quantity. The sibling option-history endpoint's
  coin-denominated columns remain `openInterestAmount`/`baseVolume`, discriminated by
  the requested option symbol. The object branch remains C-T388c.
- *Tier-1 evidence:* live EEA demo `my.okx.com` with `period=1D` returned populated rows,
  captured in `test/fixtures/responses/okx/fetch_open_interest_history.json` on
  2026-07-22. The offline semantic-oracle test replays those rows through the unified
  parser. CCXT's same column mapping agrees as tier-2 compatibility evidence only.

## Task 342 — non-convert identifier_reference request renames (2026-07-18)

**C-T342 — OKX non-convert identifier_reference request renames (task 342). Outcome: CONFIRMED
against OKX authority and live EEA-demo validation.**

Task 237 made unresolved `identifier_reference` entries loud for first-class venues.
A fresh shaped-method sweep on OKX still raised for non-convert methods whose full-file
defaults left `ccy` / `toAddr` / `depId` / `wdId` / `ordId` / `posMode` / leverage natives
as `kind: unresolved`. Authored bindings land only in `authored/okx.json` (deep-merged
over the vendored stubs). Convert methods stay with task 308.

| Method | Native key(s) | Authored binding | OKX authority |
| --- | --- | --- | --- |
| `withdraw` | `ccy` / `amt` / `toAddr` | `code` / `amount` / `address` (+ vendored `dest=4`) | `POST /api/v5/asset/withdrawal` |
| `borrowCrossMargin` / `repayCrossMargin` | `ccy` / `amt` (+ optional `ordId`) | `code` / `amount` / `id` | `POST /api/v5/account/borrow-repay` |
| `fetchDeposit` / `fetchWithdrawal` | `depId` / `wdId` | `id` | deposit/withdrawal history GETs |
| `fetchDepositAddressesByNetwork` | `ccy` | `code` | `GET /api/v5/asset/deposit-address` |
| `cancelOrder` / `fetchOrder` | `instId` / `ordId` | `symbol` / `id` | trade cancel/order endpoints |
| `setLeverage` / `setMarginMode` | `lever` / `mgnMode` / `instId` | `leverage` / `margin_mode` (default `cross`) / `symbol` | `POST /api/v5/account/set-leverage` |
| `closePosition` | `instId` / `mgnMode` | `symbol` / `margin_mode` default `cross` | `POST /api/v5/trade/close-position` |
| `setPositionMode` | `posMode` | conditional on `hedge_mode` → `long_short_mode` / `net_mode` | `POST /api/v5/account/set-position-mode` |
| `addMargin` / `reduceMargin` / `modifyMarginHelper` | `instId` / `amt` / `type` / `posSide` | `symbol` / `amount` / literal or `type` / `posSide` | `POST /api/v5/account/position/margin-balance` |

**Live pins (EEA demo `my.okx.com`, 2026-07-18):**

- *Success — leverage/position-mode family:* `set_leverage(5, "BTC/USDT:USDT")` → `code 0` with
  `data[0].{instId=BTC-USDT-SWAP, lever=5, mgnMode=cross}`; `set_position_mode(false)` →
  `posMode=net_mode`. `fetch_cross_borrow_rate("USDT")` → rate with `info.ccy=USDT`.
- *Error — id renames:* `fetch_deposit` / `fetch_withdrawal` with junk ids → `51000` naming
  `depId` / `wdId`; `fetch_order` with a non-existent numeric id → `51603` order-does-not-exist
  (proves `ordId`+`instId` reached validation). `borrow_cross_margin("USDT", 1e-8)` → `51000`
  Parameter `amt` error (ccy accepted). `withdraw` with invalid address → non-zero business
  error (`50038` demo-unavailable on EEA demo); never `code 0`.

Fresh shaped-method sweep reports **zero** unresolved `identifier_reference` ArgumentErrors for
OKX outside convert methods (`fetchConvertTrade.clTReqId` remains task 308). Known residual
outside this task: unified `cancelOrder` currently selects `trade/cancel-algos` ahead of
`trade/cancel-order` (body shape is correct; endpoint selection is a separate routing defect).

## Historical confrontations (moved from authored-specs.md, task 466)

**C-T308 — OKX convert-trade request fields. Outcome: CONFIRMED-against-OKX docs (task 308).**

- *Exchange-flow confrontation:* [OKX Convert Trade](https://www.okx.com/docs-v5/en/#trading-convert-trade)
  requires the accepted `quoteId`, conversion currencies (`baseCcy`, `quoteCcy`), `sz`, and the
  size currency (`szCcy`) in the `POST /api/v5/asset/convert/trade` body.
- *Our carve + rationale:* bind unified `id`, `from_code`, `to_code`, and `amount` to `quoteId`,
  `baseCcy`, `quoteCcy`, `szCcy`, and `sz` respectively; `szCcy` is `from_code` because the
  authored request sells that source currency. This sends a deliberately stale quote to the venue
  for error-only verification and never executes a conversion.
- *Compatibility cost:* none; this completes the existing C31 signature on OKX without changing it.

**C-T362 — OKX non-order account + conversion request residual. Outcome: CONFIRMED-against-OKX docs
(task 362).** Full per-family register: `docs/authored-spec-carves/okx.md` (C-T362-*).

- *Scope:* transfer / transfer-state / convert sz string / convert-history `clTReqId` / margin
  bills `subType` 160|161 / borrow-interest `ccy` / dual-mode close-position `posSide`.
- *Exchange-flow confrontation:* OKX v5 funding + trading-account schemas (2026-07-18); EEA demo
  success + business-error probes for each changed family.
- *Our carve + rationale:* author renames/transforms in the OKX slice; keep venue mechanics
  (`accountsByType`, buy/sell→long/short) in `RequestShape.OKX`. Never execute a valid
  irreversible transfer/withdrawal.

**C-T363 — OKX order read + sparse action-acknowledgement response semantics. Outcome: CONFIRMED-against-OKX
docs (task 363).** Full per-family register: `docs/authored-spec-carves/okx.md` (C-T363-*).

- *Scope:* order identifiers (`ordId`/`algoId`), the three clocks (`cTime`/`uTime`/`fillTime`),
  `state`→unified status, `sz`/`accFillSz` fill arithmetic, `reduceOnly`, and the sparse
  place/cancel acknowledgement rows.
- *Exchange-flow confrontation:* OKX v5 trade order-details / order-history schemas (2026-07-18);
  EEA demo business-error probe on `POST /api/v5/trade/order`.
- *Our carve + rationale:* derive `remaining` from the row's own `sz - accFillSz`, never map `sz`
  to `cost`, and leave every field a sparse acknowledgement does not supply as `nil`. The open
  live-success confirmation is tracked in `docs/prod-verification-ledger.md`.

**C-T364a — OKX open-position response semantics. Outcome: CONFIRMED-against-OKX docs + live
intl demo (task 364).** Full register: `docs/authored-spec-carves/okx.md` (C-T364a).

- *Scope:* `fetchPosition` / `fetchPositions` open rows — identifiers, side/hedged, contracts,
  notional (linear vs inverse), IM/MM/collateral, leverage, liquidation, percentage PnL.
- *Exchange-flow confrontation:* OKX v5 account/positions schema; static fixtures #34–#37;
  international demo reversible market open/close on `BTC/USDT:USDT` (2026-07-21).
- *Our carve + rationale:* annotate money-exact `_bourse_*` keys from venue strings + market
  `contractSize`; net-mode derivatives use signed `pos`, while net-mode `MARGIN` uses
  `posCcy` against market base/quote (OKX margin `pos` is always positive); both set
  `hedged=false`.

**C-T364b — OKX positions-history response semantics. Outcome: CONFIRMED-against-OKX docs
(task 364).** Full register: `docs/authored-spec-carves/okx.md` (C-T364b).

- *Scope:* closed-position history rows (`openAvgPx`/`closeAvgPx`/`direction`/`realizedPnl`).
- *Exchange-flow confrontation:* OKX v5 positions-history schema; static fixture #38.
- *Our carve + rationale:* history branch leaves live margin/notional/contracts nil rather
  than inventing them; isolated history still stamps `im% = 1/lever`.

**C35 — OKX option greeks denomination. Outcome: DIVERGE from CCXT's bare-key mapping.**

- *Exchange semantics (non-CCXT):* `GET /api/v5/public/opt-summary` returns two
  Greek families side by side. OKX's own
  [Explanation for Greeks Delta and Gamma](https://www.okx.com/en-us/help/vi-explanation-for-greeks-delta-and-gamma)
  defines them: `deltaBS`/`gammaBS`/`vegaBS`/`thetaBS` are "derived from the
  Black-Scholes or Black options pricing model" — dollar-denominated sensitivities
  to an absolute move in the underlying. The bare `delta`/`gamma`/`vega`/`theta`
  are the **price-adjusted (PA)** Greeks, "derivatives of the Black options pricing
  model with a price adjustment", because "the margin and the settlement currency
  of the OKX BTCUSD options contract is BTC but not USD". OKX states the relation
  `PA Delta = BS Delta - Options Mark Price (In BTC)`. The two are therefore
  different quantities in different units, not two encodings of one value.
- *Live evidence (EEA demo `my.okx.com`, 2026-07-17):* the
  `BTC-USD-261225-90000-P` row carried both families — `delta` `-1.2051359955599346`
  vs `deltaBS` `-0.7904674450641715`. The PA value falls outside the `[-1, 0]`
  interval a Black-Scholes put delta is mathematically bounded to, which is the
  observable tell that the bare key is not the BS Greek.
- *CCXT's carve:* maps the bare `delta`/`gamma`/`vega`/`theta` keys into its
  unified greeks result. Matching it would prove compatibility (tier 2) while
  silently carrying OKX's BTC-settlement unit choice into a portable field.
- *Our carve + rationale:* `%Bourse.Greeks{}` carries OKX's `*BS` family. The
  unified struct has no unit discriminator, so its Greeks must mean one quantity
  across venues; Deribit (`greeks.delta`) and Bybit (`delta`) both publish the
  Black-Scholes Greek, so OKX's `deltaBS` is the field that makes the abstraction
  portable. A PA value in the same unlabelled field is a differently-denominated
  number the consumer cannot detect.
- *Compatibility cost:* intentional divergence from CCXT's bare-key values.
  Callers needing OKX's BTC-settlement hedge ratio read the PA keys from the raw
  row in `info`, which is preserved.
- *Implementation:* 295. *Evidence sources:* OKX's own Greeks documentation (non-CCXT
  semantic source) plus the live EEA-demo opt-summary row; the recorded
  dual-family row pins the field family offline, and the tagged live probe
  asserts a put delta in `[-1, 0]`.

**C15a — OKX unified requests are keyed by instrument type, family and numeric account id, not by
the unified caller vocabulary. Outcome: CONFIRM exchange semantics · DIVERGE from CCXT on the
trade-fee instrument key.**

- *Formerly cited as `C15`* (landed by task 257, 2026-07-16). Task 240 landed a second, unrelated
  `C15` (GET array query encoding) 28 minutes later; the bare id stayed there because more live
  citations mean it. Prose that cites "C15" for OKX instrument-type keying — e.g. task 269's
  "Register the carve … (extends C15)" — resolves **here**.
- *Exchange semantics (non-CCXT — live OKX EEA demo `my.okx.com`, 2026-07-16):*
  - `GET /api/v5/account/trade-fee` accepts `instId` **only for SPOT/MARGIN**. `instType=SWAP` +
    `instId=BTC-USDT-SWAP` is rejected `50016 "instId and instType don't match"`; the same call with
    `instFamily=BTC-USDT` returns 200/code 0. So a derivative fee read is family-keyed, not id-keyed.
  - `GET /api/v5/public/instruments?instType=OPTION` (no `uly`/`instFamily`) is rejected
    `50015 "Either parameter uly or instFamily is required"`. SPOT/FUTURES/SWAP need no such key
    (live counts 543/91/175).
  - `GET /api/v5/trade/orders-history` requires `instType` (`50014` without it).
  - `GET /api/v5/market/books` returns top-of-book unless `sz` is supplied.
  - `GET /api/v5/account/leverage-info` requires a valid `mgnMode` (`51000 "Parameter mgnMode error"`).
  - `POST /api/v5/asset/transfer` requires `ccy`/`amt` and numeric `from`/`to` account ids
    (`funding=6`, `trading=18` per `options.accountsByType`).
- *Our carve:* the unified boundary keeps `code`/`amount`/`from_account`/`to_account`, the unified
  symbol, and `limit`. The authored spec entries rename them to OKX's `ccy`/`amt`/`from`/`to` and
  `instId`. Those renames are interpretive judgment, so they are hand-owned in
  `authored/okx.json` under `endpoints.request.defaults` and live **only** there — the full vendored
  `okx.json` keeps distill's `unresolved` stubs, so a re-vendor of the catalog cannot wipe them
  (`Bourse.Spec.load!/1` overlays the authored slice over the full spec; authored wins per key). This
  matches the deribit pattern. The OKX request-shape module then applies the venue mechanics the generic entries cannot
  express — instrument type derived from the symbol's market type, family derived from the
  instrument id, numeric account ids, and `sz` from the caller's `limit` (default 100).
  `fetchMarkets` static fan-out variants derive from `raw.describe.options.fetchMarkets.types` — never a
  client-side list. Its OPTION wave first reads `public/underlying?instType=OPTION`, then requests
  instruments once per returned `uly`; the underlying set is live venue data, not a spec-derived or
  hard-coded list. `fetchTickers` defaults to `options.defaultType` (SPOT); mark-price and
  open-interest reads default to SWAP.
- *Compatibility cost:* the trade-fee family key **diverges from a naive instId read** but matches
  both CCXT-JS and the venue; it is grounded in the live 50016 above, not in CCXT's source.
- *Implementation:* 257, 269, 270. Task 270 authored OKX's option examples against the live
  `BTC-USD-YYMMDD-STRIKE-C/P` shape so option symbols classify as `:option_yymmdd` and keep the
  quote segment in `instId`.
- *Known gaps (deliberately not smuggled in here):*
  - `fetchGreeks` no longer fails on a mangled family, but the response still parses to an all-nil
    struct: `public/opt-summary` returns the family's full row list and the requested `instId`'s row
    is never selected out of it. Tracked as task 273 (same class as the `fetchMarkets` envelope gap
    in task 258). Task 273's original `C17` citation is corrected here: this C15a Known gaps entry
    is the canonical record for that opt-summary row-selection gap.

**C17a — OKX sandbox `fetchCurrencies` short-circuit. Outcome: DIVERGE from CCXT — surface the
exchange error instead of faking an empty currency map.**

- *Formerly cited as `C17`* (landed by task 258, 2026-07-16). Task 236 landed a second, unrelated
  `C17` (deribit dated-instrument identity) two hours later; the bare id stayed there. The
  CHANGELOG's "Carve C17: sandbox `fetchCurrencies` surfaces demo `50038`" and task 277's "demo
  answers 50038 per carve C17" resolve **here**, not to the deribit carve.
- *CCXT's carve:* `okx.ts fetchCurrencies` returns `{}` client-side when `this.isSandboxMode` is
  true, never calling `GET /api/v5/asset/currencies`. Demo trading answers that private path
  with business code `50038 "This feature is unavailable in demo trading"`.
- *Exchange semantics (non-CCXT — live OKX EEA demo `my.okx.com`, 2026-07-16):* with
  `sandbox: true` + `hostname: "my.okx.com"` and valid demo creds, the signed currencies call
  returns `code: "50038"` / msg `"This feature is unavailable in demo trading"`. That is the
  venue's own capability gate for demo, not a client parse failure. Convert-currency
  (`asset/convert/currencies`) remains available on the same demo account and parses to a
  full currency dict after the task-258 envelope + field map.
- *Our carve + rationale:* do **not** adopt CCXT's sandbox short-circuit. Returning `{}` would
  silent-pass a demo-capability gap as "no currencies" and train consumers to treat empty as
  success. Surface the exchange error (`%Bourse.Error{type: :exchange_error, code: "50038", ...}`)
  so the caller can distinguish "demo does not expose this path" from "parse/auth/routing is
  broken." Production keys keep the real `asset/currencies` payload through the authored
  `currency` slot (`ccy` → id/code, fee/limits from the row).
- *Compatibility cost:* a CCXT consumer that relied on sandbox `fetchCurrencies → {}` now sees
  an error on demo — deliberate, because empty was never a real venue answer.
- *Implementation:* 258 (envelope + currency field map; no client-side sandbox guard).
- *Evidence sources:* live demo `50038` (tier-1) + offline convert-currencies list parse pin.

**C32 — OKX account configuration has no account currency. Outcome: DIVERGE from CCXT's
undefined-only key; retain the four-field Account schema.**

- *Exchange semantics (non-CCXT):* OKX's `GET /api/v5/account/config` identifies an account with
  `uid` and describes its account level with `acctLv`; its response carries no `ccy` field. The
  account is exchange-wide, not currency-specific.
- *CCXT's carve:* `parseAccount` includes `currency: undefined` in the JavaScript object even
  though the OKX row provides no currency value.
- *Our carve + rationale:* `%Bourse.Account{}` keeps `code` for genuinely currency-scoped accounts
  and does not add a second `currency` field for an absent OKX concept. The response-gate
  contract C32 asserts that CCXT's key is nil before removing it from the compatibility compare;
  it cannot hide a future non-nil value.
- *Compatibility cost:* consumers inspecting JavaScript object keys will not see an undefined
  `currency`; Elixir callers keep the meaningful `id`, `type`, `code`, and raw `info` fields.
- *Implementation:* 277. *Evidence sources:* [OKX Account API](https://www.okx.com/docs-v5/en/) account
  configuration schema plus the recorded `account/config` row.

**C33 — OKX bills are balance-change records, and their account endpoints stay numeric.
Outcome: DIVERGE from CCXT's account-name translation.**

- *Exchange semantics (non-CCXT):* OKX documents `balChg` as the account-level balance change
  and supplies `ccy`, `from`, and `to` on bills rows. `from`/`to` are venue account identifiers;
  the raw values are retained rather than guessed into labels.
- *CCXT's carve:* `parseTransfer` maps numeric account identifiers such as `6` and `18` to
  `funding` and `trading`.
- *Our carve + rationale:* `fetch_transfers` maps `amount` from `balChg` (falling back to `amt`
  for transfer acknowledgements), preserves `ccy`, and exposes the raw numeric account ids in
  `from_account`/`to_account`. This does not silently claim a stable cross-venue account-name
  ontology when the OKX response supplies ids.
- *Compatibility cost:* callers receive `"6"`/`"18"` rather than CCXT's labels; the raw row in
  `info` remains the source for any venue-specific interpretation.
- *Implementation:* 277. *Evidence sources:* [OKX Account API](https://www.okx.com/docs-v5/en/) bills
  schema plus the live EEA-demo bills row recorded on 2026-07-17.

**C-T311 — OKX `fetchCurrencies` currency-level withdrawal-fee rollup (task 311). Outcome: DIVERGE from CCXT; CONFIRMED against the OKX asset-currencies contract.**

- *Exchange semantics (non-CCXT — [OKX Funding Account: Get currencies](https://www.okx.com/docs-v5/en/#funding-account-rest-api-get-currencies), consulted 2026-07-18):* `GET /api/v5/asset/currencies` returns one row per chain. `canWd` is the availability to withdraw **to that chain**; `fee` is returned on that same chain row; and `wdTickSz` is the withdrawal precision, which also governs withdrawal-fee precision. A row whose `canWd` is false is therefore not an available withdrawal route and its `fee` cannot describe an available currency-level withdrawal.
- *CCXT's carve:* across the recorded default response's rows (BTC 7 chains, ETH 11, USDT 17), CCXT selects the minimum `fee` from every row — for all three currencies that minimum is `0`, sourced from a `canWd: false` chain (BTC's `BTCK-OKTC`, and the equivalent disabled `*-OKTC`/`X Layer` rows for ETH/USDT). It already excludes disabled rows for the parent `precision`, so its two currency-level withdrawal aggregates disagree.
- *Our carve + rationale:* select the minimum `fee` only from `canWd: true` chains, exactly as the authored precision rollup does. The fixture's withdraw-enabled parent fees become `BTC 0.00000001`, `ETH 0.0000016`, `USDT 0.000062`; the per-chain `networks` map remains the source of truth for route-specific fees. This is a deliberate scalar summary, not a claim that all routes charge the same fee.
- *Compatibility cost:* the static CCXT fixture records `fee: 0` for BTC/ETH/USDT. Contract `C-T311` carries one per-currency entry (BTC/ETH/USDT), each asserting both CCXT's `0` and our withdraw-enabled minimum before removing only that currency's `fee` from strict comparison, so a fixture refresh, an accidental reversion to CCXT's disabled-route minimum, or a third value fails loudly. A currency without a divergent rollup is left to strict comparison and is not gated.
- *Evidence sources:* OKX's own asset-currencies API documentation (tier 1 semantic source). Demo is unavailable for this endpoint (`50038`, C17a); no production-key observation was available in this worktree.

## Task 503 — unified-margin derivative identity (2026-07-23)

**C-T503a — `_UM` and `_UM_XPERP` are product markers, not currencies (task 503).
Outcome: CONFIRMED against OKX docs + live intl demo; CCXT-compatible.**

- *Exchange semantics (non-CCXT):* OKX's [USDⓈ contract
  FAQ](https://www.okx.com/en-eu/help/usds-contract-faq) defines
  `BASE-USD_UM-SWAP` and `BASE-USD_UM-YYMMDD` for perpetual and dated USDⓈ
  futures and says the family settles in USD/USDC/USDG. The [OKX API
  guide](https://www.okx.com/docs-v5/en/) distinguishes all four contract
  families for both swaps and dated futures: USDⓈ uses `BASE-USD_UM-*`,
  coin-margined uses `BASE-USD-*`, USDT-margined uses `BASE-USDT-*`, and
  USDC-margined uses `BASE-USDC-*`. Its [options
  introduction](https://www.okx.com/en-ae/help/i-okx-options-introduction)
  defines `BASE-USD_UM-YYMMDD-STRIKE-C|P`; the public-instruments schema supplies
  `instType`, `instId`, `expTime`, `stk`, and `optType`. The [X-Perps contract
  specifications](https://www.okx.com/en-gb/help/x-perps-contract-specifications)
  identify `_UM_XPERP` as the X-Perps product family.
- *Carve:* `_UM` and the trailing `_XPERP` family marker are removed from
  currency identity. The `_UM` marker is attached only when the unified quote
  and settlement currencies are both `USD`; USDT- and USDC-quoted contracts
  never receive it. `BASE-USD_UM-SWAP` becomes `BASE/USD:USD`;
  `BASE-USD_UM-YYMMDD` becomes
  `BASE/USD:USD-YYMMDD`; `BASE-USD_UM-YYMMDD-STRIKE-C|P` becomes
  `BASE/USD:USD-YYMMDD-STRIKE-C|P`; and
  `BASE-USD_UM_XPERP-YYMMDD` becomes `BASE/USD:USD-YYMMDD`. Thus base comes
  from the leading token, quote and settle are `USD`, expiry is the six-digit
  contract token, and option strike/type come from the final two tokens.
  Loaded-market identity resolves the canonical symbol to the exact `instId`,
  preserving `_XPERP` where canonical grammar intentionally omits that venue
  marker. Legacy coin-margined `BASE-USD-YYMMDD[-STRIKE-C|P]` keeps base
  settlement.
- *Live observation:* intl demo `fetch_markets` on 2026-07-23 returned 1,682
  options and 99 identified dated futures. Before this carve, 498 options retained raw
  `instId` as `symbol`; `SOL-USD_UM-260724` produced
  `SOL/USD_UM:USD_UM-260724`; and `DOGE-USD_UM_XPERP-310516` produced
  `DOGE/USD_UM_XPERP:USD_UM_XPERP-310516`. The venue rows themselves reported
  quote/settle as `USD`, confirming that the suffixes were parser artifacts.
  A 2026-07-23 convergence re-observation returned 553 `_UM` markets, including
  `EWJ-USD_UM-SWAP` and `SLX-USD_UM-SWAP`, plus 14 plain USDT-dated futures.
  The swap rows reported quote/settle as `USD`; the plain USDT ids confirmed
  that quote settlement alone does not imply the `_UM` marker.
- *Compatibility reference:* a live CCXT JS 4.5.x sandbox run on the same date
  emitted `BTC/USD:USD-260719-65500-C` for
  `BTC-USD_UM-260719-65500-C`, `SOL/USD:USD-260724` for
  `SOL-USD_UM-260724`, and `DOGE/USD:USD-310516` for
  `DOGE-USD_UM_XPERP-310516`. This agrees with the carve but remains tier-2
  compatibility evidence only.
- *Compatibility cost:* none observed for canonical symbols. Raw `instId`
  remains in `Market.id` and `Market.info`; callers that used raw ids as
  unified symbols must use the canonical symbol or the raw endpoint.

## Evidence status records

<!-- carve-evidence-status
{"carve_id":"C-T503a","date":"2026-07-23","semantic_source":{"kind":"provider_owned","reference":"OKX USDⓈ Contract FAQ and API guide define BASE-USD_UM-* for the USDⓈ swap/delivery family while BASE-USDT-*, BASE-USDC-*, and coin-margined BASE-USD-* remain unsuffixed; Options Introduction, Public Instruments schema, and X-Perps Contract Specifications define the option and _UM_XPERP tokens"},"observed_evidence":{"kind":"live_venue","reference":"International demo fetch_markets on 2026-07-23 returned 553 _UM markets including EWJ-USD_UM-SWAP and SLX-USD_UM-SWAP, plus 14 plain USDT-dated futures; quote/settle fields identified the USD-only attachment condition"},"compatibility_reference":{"kind":"ccxt","reference":"Live CCXT JS 4.5.x sandbox fetchMarkets emitted BASE/USD:USD canonical symbols for _UM options, futures, and X-Perps"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T485a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX V5 Trading Statistics documents contracts open-interest-volume rows as [ts,oi,vol], with oi and vol both denominated in USD"},"observed_evidence":{"kind":"live_venue","reference":"EEA demo my.okx.com returned populated 1D contracts rows captured at test/fixtures/responses/okx/fetch_open_interest_history.json on 2026-07-22"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT okx fetchOpenInterestHistory maps contracts array index 1 to openInterestValue and index 2 to quoteVolume"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T483a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX V5 orders-pending, orders-history, orders-history-archive, orders-algo-pending, orders-algo-history, order, and order-algo schemas cited in C-T483a"},"observed_evidence":{"kind":"live_venue","reference":"Signed EEA demo accepted instId/state/ordType order-read requests with code 0 and rejected instType=NOPE with 51000 on 2026-07-22"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT static request cases #120-#126, #144-#148, #189-#193, and #228"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T483b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX V5 place-order schema and the SPOT-market-order-only tgtCcy semantics cited in C-T483b"},"observed_evidence":{"kind":"live_venue","reference":"Signed EEA demo spot market-with-cost request sized below the venue minimum reached a 51-class business code without creating a filled order on 2026-07-22; the derivative path raises before any request"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT static request fixtures #88 and #100 post one-row batch-orders arrays; CCXT-JS throws NotSupported for non-spot"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T442f","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX Get currencies defines per-chain canDep and canWd availability"},"observed_evidence":{"kind":"recorded_venue","reference":"Recorded OKX fetchCurrencies #17 carries canDep and canWd for all 28 networks"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT 4.5.65 parsedResponse leaves per-network active undefined"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T482b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX Get currencies defines independent per-chain canDep and canWd booleans"},"observed_evidence":{"kind":"recorded_venue","reference":"Recorded OKX fetchCurrencies #17 carries canDep and canWd for all 28 networks"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT 4.5.65 leaves per-network active undefined"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C32","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX Account Configuration response schema cited in C32"},"observed_evidence":{"kind":"recorded_venue","reference":"Recorded account/config venue row carries uid and acctLv with no ccy"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT parseAccount materializes currency as undefined"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T311","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX Funding Account Get currencies schema cited in C-T311"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT static currencies fixture chooses disabled-chain zero fees"},"resolved_tier":2,"known_gap_reason":"Demo returns 50038 and no production asset/currencies response has been observed; the production verification ledger remains open"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T382b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX V5 place and cancel acknowledgement schemas cited in C-T382b"},"observed_evidence":{"kind":"live_venue","reference":"International-demo option place and cancel acknowledgements exposed only the documented sparse fields"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT fixtures echo request-only order fields"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T387b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX V5 algo order, amend, cancel, and cancel-all-after schemas cited in C-T387b"},"observed_evidence":{"kind":"live_venue","reference":"EEA demo accepted shaped algo families through business validation and returned documented cancel/amend codes on 2026-07-21"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT fixtures retain conflicting numeric and echoed unified fields"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T387c","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX V5 place-algo tdMode schema defines cash for non-margin spot"},"observed_evidence":{"kind":"live_venue","reference":"EEA demo accepted the cash spot-algo body through schema validation and returned business code 51155"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT spot conditional fixtures send tdMode=cross"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T432","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T432 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T432 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T432 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T427a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T427a and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T427a and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T427a and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T427b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T427b and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T427b and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T427b and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T427c","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T427c and its register context"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T427c and its register context"},"resolved_tier":2,"known_gap_reason":"Provider-owned semantics are recorded, but no independent live or recorded venue observation establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T365a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T365a and its register context"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T365a and its register context"},"resolved_tier":2,"known_gap_reason":"Provider-owned semantics are recorded, but no independent live or recorded venue observation establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T365b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T365b and its register context"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T365b and its register context"},"resolved_tier":2,"known_gap_reason":"Provider-owned semantics are recorded, but no independent live or recorded venue observation establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T365c","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T365c and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T365c and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T365c and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T389a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T389a and its register context"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T389a and its register context"},"resolved_tier":2,"known_gap_reason":"Provider-owned semantics and CCXT compatibility are recorded, but no independent live or recorded venue observation establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T389b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T389b and its register context"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T389b and its register context"},"resolved_tier":2,"known_gap_reason":"Provider-owned semantics and CCXT compatibility are recorded, but no independent live or recorded venue observation establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T389c","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T389c and its register context"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T389c and its register context"},"resolved_tier":2,"known_gap_reason":"Provider-owned semantics and CCXT compatibility are recorded, but no independent live or recorded venue observation establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T421","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T421 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T421 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T421 and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T389d","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T389d and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T389d and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T389d and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T389e","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T389e and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T389e and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T389e and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T394","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T394 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T394 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T394 and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T388a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T388a and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T388a and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T388a and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T388b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T388b and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T388b and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T388b and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T388c","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T388c and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T388c and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T388c and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T388d","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T388d and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T388d and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T388d and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T378f","date":"2026-07-22","semantic_source":null,"observed_evidence":null,"compatibility_reference":null,"resolved_tier":3,"known_gap_reason":"This internal authoring outcome records no provider-owned semantic source, independent venue observation, or CCXT compatibility evidence"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T385a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T385a and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T385a and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T385a and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T385b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T385b and its register context"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T385b and its register context"},"resolved_tier":2,"known_gap_reason":"Provider-owned semantics and CCXT compatibility are recorded, but no independent live or recorded venue observation establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T385c","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T385c and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T385c and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T385c and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T385d","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T385d and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T385d and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T385d and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T385e","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T385e and its register context"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Provider-owned semantics and CCXT compatibility are recorded, but no independent live or recorded venue observation establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T387a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T387a and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T387a and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T387a and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T361a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX V5 trade/batch-orders schema requires a root JSON array whose rows each own instId, tdMode, side, ordType, and string sz/px"},"observed_evidence":null,"compatibility_reference":{"kind":"ccxt","reference":"CCXT createOrders fixtures also post an array to trade/batch-orders; their generated broker ids are not adopted"},"resolved_tier":2,"known_gap_reason":"Provider-owned batch-place semantics and CCXT compatibility are recorded, but no live or recorded venue observation of the batch place path exists; C-T361b's EEA-demo acceptance covers batch amend, not place"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T361b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T361b and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T361b and its register context"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T382a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T382a and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T382a and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T382a and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T434a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX V5 books, candles, tickers, and trades schemas define instId/sz, bar plus exclusive before/after bounds, and instType; history-candle and option-trade routes are distinct endpoints"},"observed_evidence":{"kind":"live_venue","reference":"EEA demo my.okx.com returned populated BTC/USDT order-book, candle, swap-ticker, and trade results; invalid instrument ids returned 51001 and invalid ticker instType returned 51000"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T434b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX V5 option tickers take instType=OPTION plus uly; option summaries take uly/instFamily and optional expTime; contract open-interest history takes base ccy plus period on the Rubik contracts route"},"observed_evidence":{"kind":"live_venue","reference":"EEA demo returned populated option-chain, greeks, and contract open-interest results; invalid instType/instFamily returned 51000 and an unknown open-interest token returned 51012"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T434c","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX V5 account and funding bills accept instType/ccy and deposit history takes ccy, before, after, and limit; account bills, archived bills, and funding bills are separate signed routes"},"observed_evidence":{"kind":"live_venue","reference":"Signed EEA-demo ledger and deposit requests were accepted; invalid instType and invalid before each returned 51000 with valid demo credentials, proving request-shape validation rather than authentication failure"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT's explicit method selectors are routed to the matching bill endpoint"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T434d","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX positions-history endpoint returns newest-first by uTime and accepts one instId, limit, instType, and mgnMode; the official pagination guide defines after as exclusive"},"observed_evidence":{"kind":"live_venue","reference":"On 2026-07-22 EEA demo my.okx.com accepted the unified until request mapped to signed native after with code 0; invalid history instType with the same bound returned 51000 and an unknown singular instrument returned 51001"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT omits unified until and only filters since locally; that is compatibility behavior, not the exchange-owned pagination contract"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T484a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX Get deposit address and Get withdrawal history document ccy as the currency filter; unknown query keys are ignored"},"observed_evidence":{"kind":"live_venue","reference":"Signed EEA-demo my.okx.com fetch_withdrawals(code:USDT) accepted code 0; bogus ccy returned 58006 naming the token; deposit-address is demo-feature-blocked 50038 regardless of params"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT request fixtures #114 and #149 expect ?ccy=USDT"},"resolved_tier":2,"known_gap_reason":"EEA demo returns 50038 before deposit-address parameter semantics can be observed; the open task-389 production-verification ledger entry tracks the required code-0 response"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T484b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX Withdrawal documents ccy/amt/toAddr/chain as Strings; chain is the composite currency-network id (USDT-TRC20) and defaults to the main chain when omitted"},"observed_evidence":{"kind":"live_venue","reference":"EEA-demo withdraw with mapped chain reaches OKX rejection (50120 permission or address/demo-unavailable) — never code 0"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT request fixture #128 expects chain=USDT-TRC20 with string amt/fee"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T484c","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX bills-archive accepts instType, ccy, ctType linear|inverse, and bill type; funding fee is type 8"},"observed_evidence":{"kind":"live_venue","reference":"Signed EEA-demo bills-archive with type=8 ctType=linear ccy=USDT instType=SWAP returned code 0"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT request fixture #96 expects type=8&ctType=linear&ccy=USDT&instType=SWAP"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T475a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX option uly/instFamily are BASE-SETTLE identifiers (docs examples BTC-USD); the underlying listing endpoint is the authority for which settle families exist"},"observed_evidence":{"kind":"live_venue","reference":"Live OPTION underlying list was exclusively *-USD on 2026-07-22; uly=BTC-USDT instruments returned an empty set"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T475b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"OKX contracts Rubik period is 5m/1H/1D and option Rubik period is 8H/1D; our unified history builder defaults to 1D, which works on both routes"},"observed_evidence":{"kind":"live_venue","reference":"Live contracts OI accepted 5m/1H/1D and rejected 1W/bogus with 51000 naming [5m,1H,1D]; option OI accepted 8H/1D and rejected 5m/1H"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T342","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T342 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T342 and its register context"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T308","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T308 and its register context"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Provider-owned semantics are recorded, but no independent live or recorded venue observation establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T362","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T362 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T362 and its register context"},"compatibility_reference":null,"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T363","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T363 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T363 and its register context"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C-T364a","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T364a and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C-T364a and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T364a and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C-T364b","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C-T364b and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C-T364b and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C-T364b and its register context"},"resolved_tier":2,"known_gap_reason":"The register records partial or mixed evidence; it does not independently establish every assertion in this carve at tier 1"}
-->

<!-- carve-evidence-status
{"carve_id":"C35","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C35 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C35 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C35 and its register context"},"resolved_tier":1}
-->

<!-- carve-evidence-status
{"carve_id":"C15a","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C15a and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C15a and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C17a","date":"2026-07-22","semantic_source":null,"observed_evidence":{"kind":"live_venue","reference":"Partial live or recorded venue evidence cited in C17a and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C17a and its register context"},"resolved_tier":2,"known_gap_reason":"Venue behavior is recorded, but no provider-owned semantic source independent of CCXT establishes this carve"}
-->

<!-- carve-evidence-status
{"carve_id":"C33","date":"2026-07-22","semantic_source":{"kind":"provider_owned","reference":"Provider-owned documentation or schema cited in C33 and its register context"},"observed_evidence":{"kind":"live_venue","reference":"Live or recorded venue evidence cited in C33 and its register context"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT source or fixture cited in C33 and its register context"},"resolved_tier":1}
-->

## Task 514 — order-book level contract (2026-07-25)

**C-T514a — unified order-book levels are exact `[price, amount]` pairs; OKX's extra
columns remain in `OrderBook.info`. Outcome: DIVERGE from CCXT 4.5.65; CONFIRM venue;
reality tier 1 (task 514).**

- *Exchange semantics:* OKX's [Get order book](https://www.okx.com/docs-v5/en/#order-book-trading-market-data-get-order-book)
  documents each `asks` / `bids` row as `[price, quantity, deprecated, order_count]`.
  The third value belongs to a deprecated feature and is always `"0"`; the fourth is
  the number of orders at that price.
- *Live evidence (2026-07-25):* production `GET /api/v5/market/books` with
  `instId=BTC-USDT&sz=1` returned bid
  `["64137.9","4.01442447","0","24"]` and ask
  `["64138","0.00806502","0","3"]`.
- *CCXT reference:* `parseOrderBookBidAsk` defaults `countOrIdKey` to index 2, and
  `okx.fetchOrderBook` calls `parseOrderBook` without overriding it. CCXT therefore
  emits the deprecated zero as a third unified value and discards the meaningful
  order count at index 3.
- *Our carve:* every unified venue emits exact `[price, amount]` pairs. OKX's full
  four-column rows remain verbatim in `OrderBook.info`, so both provider fields stay
  observable without making level arity venue-dependent. A row outside the authored
  two-column or OKX documented three-/four-column shapes fails the unified parse loudly.
- *Retired compatibility-baseline inventory:* two deliberate divergences were tied to this
  carve: swap order book `#32` and spot order book `#33`.

<!-- carve-evidence-status
{"carve_id":"C-T514a","date":"2026-07-25","semantic_source":{"kind":"provider_owned","reference":"OKX API v5 Get order book response-row semantics"},"observed_evidence":{"kind":"live_venue","reference":"OKX production GET /api/v5/market/books BTC-USDT sz=1 returned [64137.9,4.01442447,0,24] bid and [64138,0.00806502,0,3] ask on 2026-07-25"},"compatibility_reference":{"kind":"ccxt","reference":"CCXT 4.5.65 parseOrderBookBidAsk default countOrIdKey=2 and OKX default parseOrderBook call"},"resolved_tier":1}
-->

## 2026-08-08 — single deposit and withdrawal reads (Task 565)

**C-T565e — Single-record transfer reads require a venue identifier observed in the demo
account (task 565). Outcome: mark unsupported without such evidence.**

- *Provider contract:* single deposit and withdrawal lookup is keyed by an existing provider
  record identifier.
- *Live evidence:* the international demo account returned empty deposit and withdrawal history,
  so it supplied no identifier with which to verify either single-record response contract.
- *Our carve:* `fetchDeposit` and `fetchWithdrawal` are `has=false`; the list history methods
  retain their independent contracts.

<!-- carve-evidence-status
{"carve_id":"C-T565e","date":"2026-08-08","semantic_source":{"kind":"provider_owned","reference":"OKX API v5 deposit and withdrawal history record contracts"},"observed_evidence":{"kind":"live_venue","reference":"Task 565 www.okx.com simulated-trading account returned zero deposit and zero withdrawal history rows"},"compatibility_reference":null,"resolved_tier":1}
-->
