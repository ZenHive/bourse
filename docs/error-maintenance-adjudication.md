# Error maintenance adjudication (task 490)

Adjudicated 2026-07-22. Provider-owned error enumerations under `priv/authority/<venue>/errors.json` are the authority; CCXT class names are the mapping target only.

Runtime note: `Bourse.Error.from_spec_class("OnMaintenance")` resolves to `:exchange_not_available` (retry class `:server_busy`). There is no separate `:on_maintenance` atom — the task's "on_maintenance" wording names the CCXT class / maintenance state.

## Per-venue

| Venue | Identifier(s) | Status | Source meaning |
|---|---|---|---|
| binance | `-1016` | mapped → OnMaintenance → `:exchange_not_available` | -1016: SERVICE_SHUTTING_DOWN |
| binanceusdm | `-1016` | mapped → OnMaintenance → `:exchange_not_available` | -1016: SERVICE_SHUTTING_DOWN |
| bybit | `180023` | mapped → OnMaintenance → `:exchange_not_available` | 180023: Service maintenance |
| okx | `50001` | mapped → OnMaintenance → `:exchange_not_available` | 50001: Service temporarily unavailable. Please try again later. |
| deribit | `11051` | mapped → OnMaintenance → `:exchange_not_available` | 11051: system_maintenance — System is under maintenance. |
| derive | — | no documented maintenance code | Official Derive error enumeration documents no dedicated system-maintenance or service-shutting-down code. |
| hyperliquid | — | no documented maintenance code | Official Hyperliquid error enumeration documents trading/reject statuses only; no dedicated maintenance code. |

## Explicit non-mappings

- Dropped message sentinels such as `"System is under maintenance."` remain non-authoritative (task 461) and are **not** re-added.
- Binance `-1008` (`SERVER_BUSY` on spot) is **not** reclassified here: busy ≠ documented maintenance/shutdown. USD-M `-1008` is "Request Throttled".
- Bybit `10016` ("Service is restarting") stays general server error unless a later live capture proves it is the maintenance window signal; `180023` is the explicit "Service maintenance" code.

## Verification

```sh
mix ccxt.error_authority
mix test.json --quiet test/bourse/maintenance_error_classification_test.exs
```
