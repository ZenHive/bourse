# Cross-venue carve register

Provider authority: [`priv/venues/global/authority/manifest.json`](../../priv/venues/global/authority/manifest.json).
Machine-read register: `test/bourse/authored_rate_unit_confrontation_test.exs`
parses the `rate-unit` markers and unit tables below against the public structs.

## 2026-08-18 — client identifier round-trip (Task 622)

**C-T622a — A venue maps a client identifier in both directions or in neither
(task 622). Outcome: CONFIRM class invariant.** One-way mapping — unified
`clientOrderId` renamed onto a native request key without a matching order and
trade field-map return — fails
`test/bourse/client_order_id_round_trip_invariant_test.exs`. A surface whose
provider contract has no returnable client identifier carries a named exemption
citing that contract. Deribit's round-trip is C-T622; Binance family, Derive,
Hyperliquid, and Lighter trade rows are exempted from the fill echo because those
providers do not return the client identifier on fills.

<!-- carve-evidence-status
{"carve_id":"C-T622a","date":"2026-08-18","semantic_source":{"kind":"provider_owned","reference":"Per-venue provider contracts for client identifiers: Deribit label; Binance Account Trade List orderId-only fills; Hyperliquid userFills oid; Lighter ask_client_id/bid_client_id; Derive get_trade_history trade_id/order_id"},"observed_evidence":{"kind":"live_venue","reference":"Live test.deribit.com labelled market order plus matching private/get_user_trades_by_instrument fill on 2026-08-18; catalog invariant test/bourse/client_order_id_round_trip_invariant_test.exs"},"compatibility_reference":null,"resolved_tier":1}
-->

## 2026-07-19 — Authored venue default_family for multi-endpoint selection (Task 378)

**C-T378a — Venue-level `config.default_family` slot (task 378).** Outcome: CONFIRMED as an
owned schema carve (not a CCXT field-name import). Multi-endpoint unified methods called with no
family signal (no symbol, no `type`/`subType`) must not resolve by bare `hd(configs)` list
ordering. The fall-through family is **authored** on the venue under `config.default_family`
(`spot` | `linear` | `inverse` | `option` | `swap` | `future`), loaded onto
`%Bourse.Exchange{default_family: ...}` and honored by `Bourse.Unified` selection after
configured/authored `endpoint_selection` rules. First-class venues refuse unresolved multi-
endpoint selection with a named `bad_request` (loud) rather than silently picking element zero;
long-tail public-data-only specs keep the legacy positional default. Preferred path within a
family (e.g. `positionRisk` vs `leverageBracket`) remains per-method
`endpoints.request.endpoint_selection` — the same rules+default shape already used for
`fetchBalance` / `fetchTicker`. Venue-local `Bourse.Unified` clause maps (tasks 368/373
`@binanceusdm_preferred_paths`) are retired.


**C-T378b — No-arg-read audit set and bare-hd predicate (task 378).** Outcome: CONFIRMED.
The named method set is `Bourse.Unified.no_arg_read_methods/0`; the predicate
`Bourse.Unified.bare_hd_no_arg_pairs/0` counts first-class `{exchange, method}` multi-endpoint
pairs that still resolve by bare `hd(configs)` under empty params. Acceptance: the list is
empty. Fan-out / param-fan-out methods and pairs with authored selection or `default_family`
section pick are excluded; loud first-class failures are not bare-hd resolutions.

