# Lighter carve register

Provider authority: [`priv/venues/lighter/authority/manifest.json`](../../priv/venues/lighter/authority/manifest.json).
Machine-read register: `test/bourse/authored_rate_unit_confrontation_test.exs`
parses the `rate-unit` markers and unit tables below against the public structs.
## 2026-08-11 — account and history response slices (Task 546)
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
{"carve_id":"C-T600i","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Pinned Lighter OpenAPI Funding, AccountPosition, OrderBookDetail and fee schemas"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
**C-T603g — Lighter's scaled percentages declare their source units (task 603).
Outcome: CONFIRM percent-point-to-fraction conversion.**

<!-- rate-unit path="normalization.field_maps.funding_rate_history.field_map.fundingRate" unit="fraction" source-unit="percent_points" --> Lighter's funding row is percentage-valued; `scale: 0.01` emits the unified fraction. [API reference](https://apidocs.lighter.xyz/)
<!-- rate-unit path="normalization.field_maps.position.field_map.initialMarginPercentage" unit="fraction" source-unit="percent_points" --> `initial_margin_fraction` is percentage-valued; `scale: 0.01` emits the unified fraction. [API reference](https://apidocs.lighter.xyz/)

<!-- carve-evidence-status
{"carve_id":"C-T603g","date":"2026-08-12","semantic_source":{"kind":"provider_owned","reference":"Pinned Lighter Funding and AccountPosition schemas"},"observed_evidence":null,"compatibility_reference":null,"resolved_tier":null,"note":"the replay corpus this tier rested on was deleted; unverified until a live call against the venue re-proves it"}
-->
## 2026-09-15 — current venue funding rates (Task 692)
**C-T692 — Lighter's current funding `rate` is a signed hourly fraction, not history percent-points (task 692).
Outcome: CONFIRM current `GET /api/v1/funding-rates` `rate` as source-unit fraction; DIVERGE from `/fundings` history `scale: 0.01`.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.funding_rate.field_map.fundingRate` | fraction | OpenAPI `FundingRate.rate` is a signed decimal with no percent conversion. Live testnet 2026-09-15 returned Lighter BTC `rate: 9.6e-5` alongside comparison-venue rows; that magnitude matches an hourly fraction (Hyperliquid `funding: 0.0001841099` the same day), not the history percent-points that C-T546g/`scale: 0.01` convert. [Funding rates](https://apidocs.lighter.xyz/#tag/funding/GET/api/v1/funding-rates) [OpenAPI FundingRate](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |
| `normalization.field_maps.funding_rate.field_map.interestRate`, `normalization.field_maps.funding_rate.field_map.nextFundingRate`, `normalization.field_maps.funding_rate.field_map.previousFundingRate` | absent | The current `FundingRate` object is `{market_id, exchange, symbol, rate}` — no interest, next, or previous slots. [OpenAPI FundingRate](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |
| `normalization.field_maps.funding_rate.field_map.interval` | `1h` (authored default) | Lighter documents the cadence itself: "Each deployed market on Lighter has a funding period of 1 hour", and the hourly rate is clamped to [-0.5%, +0.5%]. The rate rows carry no cadence field — `FundingRate` is `{market_id, exchange, symbol, rate}` — so the interval is an authored default, not a parsed one. 🚨 **Do not "correct" this to `8h`.** The same page defines the rate as `premium / 8 + interestRateComponent`, and that `/ 8` spreads the *premium* over eight hours; it does not change the charge period, which is hourly. [Funding](https://docs.lighter.xyz/perpetual-futures/funding) [OpenAPI FundingRate](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json) |

<!-- rate-unit path="normalization.field_maps.funding_rate.field_map.fundingRate" unit="fraction" source-unit="fraction" --> Lighter's current `funding-rates` `rate` is already a signed decimal fraction; no scale. History `/fundings` stays percent-points under C-T603g. [Funding rates](https://apidocs.lighter.xyz/#tag/funding/GET/api/v1/funding-rates)
<!-- rate-unit path="normalization.field_maps.funding_rate.field_map.interestRate" unit="absent" --> Current funding rows do not carry an interest component. [OpenAPI FundingRate](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json)
<!-- rate-unit path="normalization.field_maps.funding_rate.field_map.nextFundingRate" unit="absent" --> Current funding rows do not carry a next-rate slot. [OpenAPI FundingRate](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json)
<!-- rate-unit path="normalization.field_maps.funding_rate.field_map.previousFundingRate" unit="absent" --> Current funding rows do not carry a previous-rate slot. [OpenAPI FundingRate](https://github.com/elliottech/lighter-python/blob/6957dd8a1b36894ca9580be0d51de30aeea3bd4a/openapi.json)

<!-- carve-evidence-status
{"carve_id":"C-T692","date":"2026-09-15","semantic_source":{"kind":"provider_owned","reference":"Pinned Lighter OpenAPI FundingRate plus GET /api/v1/funding-rates"},"observed_evidence":{"kind":"live_call","reference":"testnet GET /api/v1/funding-rates 2026-09-15 Lighter BTC rate 9.6e-5 signed fraction; comparison rows dropped"},"compatibility_reference":null,"resolved_tier":"verified","note":"interval authored 1h against the provider's own funding page ('Each deployed market on Lighter has a funding period of 1 hour'), re-cited 2026-09-15 — the pinned OpenAPI documents no cadence, so the earlier derivation from history resolution plus cross-venue magnitude was not provider-owned evidence and has been replaced. REST snapshot is not the market_stats WebSocket"}
-->
## 2026-09-15 — order time-in-force and margin-aware balances (Task 704)
**C-T704a — the venue's time-in-force set is exactly {ImmediateOrCancel, GoodTillTime, PostOnly}, and an IOC limit order must carry the nil expiry (task 704).
Outcome: DIVERGE from the authored `FOK: true` / `GTD: false` capability; CONFIRM one resting mode answering to both GTC and GTD.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `capabilities.createOrder.timeInForce.FOK` | absent | The signer's own constant block publishes three values — `ImmediateOrCancel = iota`, `GoodTillTime = 1`, `PostOnly = 2` — and `L2CreateOrderTxInfo.Validate/0` rejects anything else, so no fill-or-kill exists to advertise. The authored `true` was never callable: `Bourse.Unified.RequestShape.Lighter`'s map has no FOK key either, so the capability claimed a mode the request shape could not build. [lighter-go constants](https://github.com/elliottech/lighter-go/blob/v1.0.9/types/txtypes/constants.go) |
| `capabilities.createOrder.timeInForce.GTD`, `capabilities.createOrder.timeInForce.IOC`, `capabilities.createOrder.timeInForce.PO` | supported | `GoodTillTime` is the venue's single resting mode and it is expressed as an explicit `OrderExpiry` (`MinOrderExpiryPeriod` 5 minutes, `MaxOrderExpiryPeriod` 30 days), so "good till cancelled" and "good till date" are two spellings of one venue behaviour rather than two behaviours — both authored to `1`. Live 2026-09-15 on `testnet.zklighter.elliot.ai`: a PO buy on market 4096 signed and rested (tx `03c2c667647ba021c2be42df8a312bab3f9ed04761e0f38d31942afff783f72bf18580ca3b753da6`, order `844424927511380`, later cancelled), and an IOC buy filled (tx `32c58e4d04116ff4a248cd1c88c968b589913440052a88c40feb292525a916f5a4fcaafb927df155`). [lighter-go constants](https://github.com/elliottech/lighter-go/blob/v1.0.9/types/txtypes/constants.go) [API reference](https://apidocs.lighter.xyz/) |
| `capabilities.createOrder.timeInForce` — the IOC expiry coupling | nil expiry (`NilOrderExpiry = 0`) | An IOC `LimitOrder` may carry only `NilOrderExpiry`; the signer rewrites the caller's `-1` sentinel into `now + 28d` *before* that check, so a flat `-1` default made `timeInForce: "IOC"` unsignable for every caller. The slice now derives the default from the resolved time-in-force, and an explicit caller `order_expiry` still wins. Live 2026-09-15: `{market 4096, IOC, -1}` fails to sign, `{market 4096, IOC, 0}` signs. [lighter-go constants](https://github.com/elliottech/lighter-go/blob/v1.0.9/types/txtypes/constants.go) |

<!-- carve-evidence-status
{"carve_id":"C-T704a","date":"2026-09-15","semantic_source":{"kind":"provider_owned","reference":"github.com/elliottech/lighter-go v1.0.9 types/txtypes/constants.go and L2CreateOrderTxInfo.Validate"},"observed_evidence":{"kind":"live_call","reference":"testnet.zklighter.elliot.ai 2026-09-15 — IOC fill tx 32c58e4d…, PO rest+cancel tx 03c2c667… / 83be2699…, and the {IOC,-1} vs {IOC,0} signing differential"},"compatibility_reference":null,"resolved_tier":"verified","note":"the authored FOK:true/GTD:false pair was an inherited carve that the request shape never implemented; corrected to FOK:false/GTD:true with good-till-date and good-till-time as aliases of GoodTillTime"}
-->
**C-T704b — a cross-margin account's `used` and `total` are parent-level, not per-asset (task 704).
Outcome: DIVERGE from the per-asset `locked_balance` / `balance + margin_balance` carve.**

| Authored slot | Unit | Venue-owned confrontation |
|---|---|---|
| `normalization.field_maps.balance.field_map.used` | quote currency | The per-asset `locked_balance` is the spot-order lock and stays `0` while a perp position is open, so the authored carve reported zero margin for an account that had margin posted. The venue publishes the collateral it actually withholds at the account level as `cross_initial_margin_requirement`; `parent_value_key` reads it for the USDC row. [API reference](https://apidocs.lighter.xyz/) |
| `normalization.field_maps.balance.field_map.total` | quote currency | `balance + margin_balance` double-counts nothing while flat but drifts the moment a position exists, breaking `free + used == total`. The venue's own arithmetic is `available_balance = cross_asset_value − cross_initial_margin_requirement`, so `total` reads `cross_asset_value` — the same parent object `free` already reads `available_balance` from. Live 2026-09-15 with a long 0.0002 BTC open: `9999.217068 + 0.768852 = 9999.98592` exactly. [API reference](https://apidocs.lighter.xyz/) |

<!-- carve-evidence-status
{"carve_id":"C-T704b","date":"2026-09-15","semantic_source":{"kind":"provider_owned","reference":"Lighter account response cross_asset_value / cross_initial_margin_requirement / available_balance triple"},"observed_evidence":{"kind":"live_call","reference":"testnet.zklighter.elliot.ai fetch_balance 2026-09-15 with an open long — free 9999.217068 + used 0.768852 == total 9999.98592"},"compatibility_reference":null,"resolved_tier":"verified","note":"the defect was invisible while the sandbox account was flat: every per-asset margin field reads 0 with no position, so the per-asset carve and the parent carve agree exactly until the account has exposure"}
-->
