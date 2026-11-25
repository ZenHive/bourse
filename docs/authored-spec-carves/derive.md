# Derive carve register

Provider authority: [`priv/venues/derive/authority/manifest.json`](../../priv/venues/derive/authority/manifest.json).
Machine-read register: `test/bourse/authored_rate_unit_confrontation_test.exs`
parses the `rate-unit` markers and unit tables below against the public structs.
  [pinned authority manifest](../../priv/venues/derive/authority/manifest.json), artifact
## 2026-08-12 — rate-unit confrontation (Task 594)
**C-T594h — Derive's authored rate-like slots name their venue units, and private funding history
is corrected from rate to cashflow (task 594). Outcome: CONFIRMED against the venue's own contract;
the prior authoring mis-mapped the documented cashflow to `rate` and is corrected here.**

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
{"carve_id":"C-T594h","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Derive private funding-history, funding parameters/payment, instrument, trade, subaccount, and ticker contracts linked in C-T594h"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"known_gap_reason":"No populated private funding-history response is manifest-registered; the cashflow correction is provider-schema anchored and pinned with a provider-shaped offline row","note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
**C-T600g — Derive rate fields conform to the cross-venue unit contract (task 600).
Outcome: CONFIRM decimal IV and funding fractions; delete the dead income-rate sibling.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.funding_rate.field_map.fundingRate`, `normalization.field_maps.funding_rate_history.field_map.fundingRate` | fraction | Derive's funding formula multiplies size, spot, hours, and a decimal rate. [Asset parameters](https://docs.derive.xyz/docs/asset-parameters-1) |
| `normalization.field_maps.funding_history.field_map.rate`, `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate` | absent | Funding history carries cash amount, while these rate slots are null. [Funding history](https://docs.derive.xyz/reference/private-get_funding_history) |
| `normalization.field_maps.greeks.field_map.askImpliedVolatility`, `normalization.field_maps.greeks.field_map.bidImpliedVolatility`, `normalization.field_maps.greeks.field_map.markImpliedVolatility` | fraction | Derive's option-pricing response supplies IV to multiplicative volatility-shock formulas whose parameters are decimals; no percent-point scale is applied. [Ticker](https://docs.derive.xyz/reference/ticker-instrument_name-interval) [Portfolio margin](https://docs.derive.xyz/docs/portfolio-margin-1) |

- `normalization.field_maps.income` is now null. Its dead extras entry mapped the provider's
  dollar `funding` cashflow to `rate`, duplicating the error already corrected in funding history.

<!-- carve-evidence-status
{"carve_id":"C-T600g","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Derive ticker, portfolio-margin, asset-parameter, and funding-history contracts linked in C-T600g"},"observed_evidence":{"kind":"provider_shaped","reference":"IV and funding parser goldens in derive_authored_spec_test.exs"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"No manifest-registered populated option ticker or private funding-history row is carried"}
-->

## 2026-07-22 — response 4.5.65 position adjudication (Task 442)

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


## 2026-09-15 — public WS channel confrontation (Task 702)

**C-T702 — DIVERGE ticker and private message hashes; CONFIRMED trade channel
with production data delivery.** Provider sources:
[Ticker slim](https://docs.derive.xyz/api-reference/channels/tickerslim),
[Trades by instrument](https://docs.derive.xyz/api-reference/channels/tradesbyinstrument),
[Subaccount orders](https://docs.derive.xyz/api-reference/channels/subaccountorders),
[Subaccount trades](https://docs.derive.xyz/api-reference/channels/subaccounttrades).

| Authored method/template | Provider channel | Outcome and live evidence |
|---|---|---|
| `watchTicker`: `ticker.{symbol}.100` | `ticker_slim.{instrument_name}.{interval}` | DIVERGE. Demo rejected `ticker.ETH-PERP.100` with `{"code":-32602,"message":"Invalid params","data":"\u0060ticker\u0060 channel has been deprecated. Please use \u0060ticker_slim\u0060. Caught for wallet: "}`. Replacement delivered the frame below. |
| `watchTrades`: `trades.{symbol}` | `trades.{instrument_name}` | CONFIRMED. Production delivered `trades.ETH-PERP` on a later bounded probe (frame below). Demo acknowledged but remained idle in repeated 60-second waits; the demo gap remains ledgered. |
| `watchOrders`: `:{symbol}` | `{subaccount_id}.orders` (private) | DIVERGE. `:ETH-PERP` rejected with `{"code":13000,"message":"Invalid channels","data":"{\":ETH-PERP\":\"Channel name \u0060:ETH-PERP\u0060 does not match any patterns\"}"}`. No public counterpart. Slot now explicitly unresolved and names the private provider channel; `channel:` pass-through remains available. |
| `watchMyTrades`: `:{symbol}` | `{subaccount_id}.trades` (private) | DIVERGE, same rejected hash. No public counterpart. Slot explicitly unresolved; no new private handshake or unified watch method. |

Actual demo replacement frame (subscription, not acknowledgement):

```json
{"method":"subscription","params":{"channel":"ticker_slim.ETH-PERP.100","data":{"timestamp":1789470139328,"instrument_ticker":{"t":1789470139328,"A":"40","a":"2485.85","B":"40","b":"2483.35","f":"0.000012500","option_pricing":null,"I":"2484.67","M":"2484.81","stats":{"c":"94.04","v":"237377.368","pr":"237379.351","n":13,"oi":"14609.766","h":"2569.89","l":"2474.329","p":"-0.027"},"minp":"2424.21","maxp":"2546.92"}}}}
```

The router now reads `params.channel` and `params.data`, and dispatch names
`ticker_slim`. The ticker parse slice reads compact bid/ask/size/index/mark/time
fields from the nested `instrument_ticker` while retaining REST long-name inputs.
It does not invent last price or percentage from undocumented interpretations of
`stats`. The live test passes the routed payload through the generated
`parse_ticker/2`, asserting prices against that same newly received provider frame.
The recorded frame in the unit test is only a parser regression check.

Provider orderbook and trades-by-type channels exist but have no authored public
watch template here; adding unified methods is outside Task 702. Private account
event delivery remains outside this public audit and is explicitly ledgered.

Production trade delivery on `wss://api.lyra.finance/ws` (the earlier 60-second
production wait had been idle; the later probe received this actual trade):

```json
{"method":"subscription","params":{"channel":"trades.ETH-PERP","data":[{"trade_id":"f69d1a1d-5c4f-4f7b-b66a-1234838364ee","instrument_name":"ETH-PERP","timestamp":1789470739946,"trade_price":"2485.2","trade_amount":"0.1","mark_price":"2485.268140596208468195982277393341064453125","index_price":"2485.170961678356","direction":"buy","quote_id":null,"rfq_id":null}]}}
```

<!-- carve-evidence-status
{"carve_id":"C-T702","date":"2026-09-15","semantic_source":{"kind":"provider_owned","reference":"Derive ticker_slim, trades-by-instrument, subaccount orders and subaccount trades channel docs linked above"},"observed_evidence":{"kind":"live_venue","reference":"2026-09-15 api-demo.lyra.finance ticker_slim.ETH-PERP.100 instrument_ticker frame; production trades.ETH-PERP trade_id f69d1a1d-5c4f-4f7b-b66a-1234838364ee; deprecated ticker and :ETH-PERP rejection frames in this carve"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Demo trades.ETH-PERP acknowledged without a data frame in repeated 60s waits; private {subaccount_id}.orders/.trades not proven in this public audit"}
-->

## 2026-11-25 — API v2 → v3 confrontation (Task 709)

Provider sources (all retrieved 2026-11-25, pinned in the authority manifest):
[introduction](https://docs.derive.xyz/getting-started/introduction.md),
[breaking changes](https://docs.derive.xyz/migrating/breaking-changes.md),
[action signing](https://docs.derive.xyz/authentication/action-signing.md),
[session login](https://docs.derive.xyz/authentication/session-login.md),
[error codes](https://docs.derive.xyz/error-codes.md),
[OpenAPI](https://docs.derive.xyz/openapi.json),
[WS AsyncAPI](https://docs.derive.xyz/websocket.asyncapi.json),
[subscriptions AsyncAPI](https://docs.derive.xyz/subscriptions.asyncapi.json).
Live host: `https://testnet.api.derive.xyz/v3` and `wss://testnet.api.derive.xyz/v3/ws`.

**C-T709 — DIVERGE on hosts, auth, signing domain, order reads, ticker and symbols. CONFIRMED
live: the 12 public REST-read contract cases, the public `ticker_slim` and `trades` frames, and
the option-surface Greeks join (`test/live/option_surface_integration_test.exs`, both derive
cases green 2026-11-25 once identity moved to `public/get_instrument`). Everything private is
unverified: the testnet wallet owns no v3 subaccount.**

| Slot | v2 authoring | v3 provider contract | Outcome and evidence |
|---|---|---|---|
| Hosts | `api.lyra.finance`, `api-demo.lyra.finance` | `api.derive.xyz/v3`, `testnet.api.derive.xyz/v3`, WS `/v3/ws` | DIVERGE. The v2 hosts answer Cloudflare 521/530. 12/12 public REST-read contract cases are green on the v3 testnet. |
| Session headers | `X-LyraWallet/Timestamp/Signature` | `X-DeriveWallet/Timestamp/Signature`, same EIP-191 primitive | DIVERGE. An unknown session key answers JSON `14026` "Session key not found" and names the recovered address. v2's nginx HTML 403 is gone. |
| Wallet identity | smart-contract "Derive Wallet" | owner EOA or multisig | DIVERGE. The wallet that owned 144422 on v2 returns `subaccount_ids: []` on the v3 testnet and on mainnet. |
| EIP-712 domain | chainId 957 / 901, fixed separators | `Matching` / `1.0` / chainId 1 / 11155111 / `0xeB8d…DeAD` | DIVERGE. The separators `0xda616dfa…fe19` and `0x24d674cd…3e85` were reproduced independently with ethers 6.13.4 `TypedDataEncoder.hashDomain`. |
| Trade module | per-network v2 addresses | `0xB8D20c2B7a1Ad2EE33Bc50eF10876eD3035b5e7b` on both networks | DIVERGE. The digests in `prepared_order_test.exs` match ethers byte-for-byte. A venue-accepted order is still unverified. |
| Order nonce | ms + 3-digit suffix, integer | `ms × 1e6` + random 6 digits, decimal string | DIVERGE. **The provider docs disagree on the window:** breaking-changes.md says "90 days before → 1 hour after", action-signing.md says "± 5 minutes when placed". The live window is not yet measured; the nonce is always "now". |
| Price/amount precision | unrestricted 1e-18 | values below `1e-12` are rejected (`14014`) | DIVERGE. `PreparedOrder.scaled/2` refuses them before signing. |
| Perp symbols | `BTC/USD:USDC` | instruments report `quote_currency: "USDC"` | DIVERGE. The unified symbol is `BTC/USDC:USDC` ↔ `BTC-PERP`, and `Bourse.Symbol` `:suffix_perp` now implies a USDC quote. Live: `load_markets` on the testnet listed 21 perps, all `*/USDC:USDC`. |
| fetchOpenOrders / fetchOrders | `private/get_orders` + status filter | `private/get_open_orders`, `private/get_order_history` (`result.orders` + pagination) | DIVERGE. v3 removed `get_orders`. fetchClosedOrders / fetchCanceledOrders delegate to fetchOrders (history only). |
| fetchTicker / fetchGreeks | long-name ticker | slim ticker (`a/A/b/B/I/M/t/f`, `stats{h,l,c,v,…}`, `option_pricing{d,g,v,t,r,i,ai,bi,m}`) | DIVERGE. Live: BTC-PERP bid/ask/high/low parse, and `fetch_greeks` on a live testnet option returned delta, gamma, theta, vega and rho. The slim ticker carries no instrument field, which broke the option-surface identity check in round 1. `markets.greeks_identity` now names `public/get_instrument`: `OptionSurface` queries it with the requested market id and still rejects a mismatch. `greeks_conventions` native fields are `option_pricing.d/g/v/t/r`. |
| Currency precision | from decimals | `get_all_currencies` gives `spot[{erc20{decimals}}]` | Mapped `null`: the nested-list index reach needs a shared parser change, which is out of this venue's scope. |
| Transaction/transfer status | `status` string | `batch_status` PascalCase (`Batching … Settled`, `*Error`), `operation_id` | DIVERGE. Mapped to `pending` / `ok` / `failed`. Envelopes are `result.deposits`, `result.withdrawals`, `result.transfers` (OpenAPI `*HistoryResult`; round 1 read `result.events` for all three). A live row is unverified (no account). |
| `get_subaccount.currency` | string | `string[]` | DIVERGE (OpenAPI). A live row is unverified. |
| `private/set_cancel_on_disconnect` | REST | WS-only (`websocket.asyncapi.json` `privateSetCancelOnDisconnect`) | DIVERGE. REST answers 404 even though trading/cancel-on-disconnect.md shows a cURL example. Not authored as a REST raw. |
| Session keys | `register_session_key`, … | `private/set_session_key` (owner-signed), `edit_session_key`, `session_keys` | DIVERGE. The removed v2 methods are not authored. |
| WS private channels (C-T702 gap) | unresolved | `{subaccount_id}.orders`, `{subaccount_id}.trades` | Templates authored. `Bourse.WS.watch_my_trades/2` builds `{subaccount_id}.trades` on the private section. Inbound, authored `channel_pattern` dispatch entries send `^[0-9]+\.trades$` to `:watch_my_trades` and `^[0-9]+\.orders$` to `:watch_orders`, so public `trades.{instrument}` stays `:watch_trades`. The unauthenticated subscribe is rejected live with `13000` "Subscription to a private channel failed". Authenticated delivery is **unverified** (no account). |

### C-T709f — fetchFundingRate reads the slim ticker f

`fetchFundingRate` routes to `public/get_ticker` and reads `f`, which the OpenAPI describes as
"Current hourly funding rate (perpetuals only; `null` otherwise)". `breaking-changes.md` gives the
same meaning ("`f`, the hourly funding rate"). The authored `interval` default is therefore `"1h"`.
Live 2026-11-25: BTC-PERP `f` parsed to `1.25e-5`, with mark and index from the same ticker.

<!-- carve-evidence-status
{"carve_id":"C-T709","date":"2026-11-25","semantic_source":{"kind":"provider_owned","reference":"Derive v3 OpenAPI, AsyncAPI, breaking-changes, action-signing, session-login and error-codes pages pinned in priv/venues/derive/authority/manifest.json"},"observed_evidence":{"kind":"live_venue","reference":"2026-11-25 testnet.api.derive.xyz/v3 public REST-read contract cases 12/12; ticker_slim.ETH-PERP.100 and trades.ETH-PERP frames on /v3/ws; option-surface call/put Greeks join; 14026 and 13000 rejections"},"compatibility_reference":null,"resolved_tier":2,"known_gap_reason":"Owner wallet has no v3 testnet subaccount: private reads, order accept/reject, MMP, cancel-on-disconnect and private channel delivery unproven pending the operator's L1 deposit"}
-->
