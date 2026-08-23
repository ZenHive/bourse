defmodule Bourse.StructValidators do
  @moduledoc """
  Per-struct assertion helpers for parsed unified types (Task 42, extended Task 221).

  Validates Phase 5/6 parser output in integration probes via
  `Bourse.IntegrationHelper`'s two-stage detection, and directly in unit tests.

  ## Provenance (Task 221)

  Audit against **vendored CCXT 4.5.65** (committed marker `priv/specs/json/ccxt/js/VERSION`;
  the CCXT source tree `priv/specs/json/ccxt/ts/src/test/` is a gitignored extraction artifact,
  so only the `static/{request,response}` fixtures are committed — the structural validators
  live upstream at `ts/src/test/Exchange/`). Not auto-synced — re-diff these upstream paths at
  the pinned tag when upgrading the vendored tree.

  **Consulted source files** (upstream `ts/src/test/Exchange/` paths, per-file identity for drift review):

  - `base/test.sharedMethods.ts` — structure/timestamp helpers, timestamp order
  - `base/test.ticker.ts` — ticker physics and policy checks
  - `base/test.orderBook.ts` — book sort, spread, level positivity
  - `base/test.ohlcv.ts` — candle OHLC relationships
  - `base/test.trade.ts` — trade enums and structure
  - `base/test.balance.ts` — free/used/total accounting identity
  - `base/test.market.ts` — market taxonomy and precision/limits ontology
  - `base/test.currency.ts` — currency deposit/withdraw/precision ontology
  - `base/test.position.ts` — position enums and contractSize positivity
  - `base/test.order.ts` — order status/side enums and amount relations
  - `test.fetchTrades.ts` — trades timestamp ordering
  - `test.fetchMyTrades.ts` — my-trades timestamp ordering
  - `test.fetchOHLCV.ts` — leaves sorted-timestamps as TODO (we repo-own it)
  - `test.fetchCurrencies.ts` — inactive-currency quota policy
  - `test.fetchBalance.ts`, `test.fetchTicker.ts`, `test.fetchOrderBook.ts`,
    `test.fetchMarkets.ts`, `test.fetchPositions.ts` — thin wrappers over base tests

  ## Classification table

  Buckets: **ported** (source-agnostic physics), **ontology-rejected** (CCXT ontology),
  **policy-adjusted** / **policy-rejected** (case-by-case), **repo-owned** (beyond CCXT).

  ### `base/test.sharedMethods.ts`

  | Check | Bucket | Rationale |
  |-------|--------|-----------|
  | `assertStructure` key-set + type expectations | ontology-rejected | Encodes CCXT's canonical object shape; our owned schema + carves diverge (C1–C7) |
  | `assertTimestamp` integer + type | ported | Integer ms timestamps when present |
  | Timestamp window 2009-01-03 .. 2038-01-19 | policy-adjusted | Adopted window when timestamp present; fixtures and distant futures stay out of band |
  | Timestamp `<= now + 1min` | policy-rejected | Clock skew false-reds the check; live ordering is out of scope for a structural validator |
  | `assertTimestampAndDatetime` iso8601 sibling | ontology-rejected | Requires both keys always present; our structs allow nil datetime |
  | `assertTimestampOrder` ascending | ported | Used for trades lists (see fetchTrades) |
  | `assertSymbol` / currency-id mapping | ontology-rejected | CCXT market registry coupling |
  | Fee structure shape helpers | ontology-rejected | Fee key-set is CCXT ontology |

  ### `base/test.ticker.ts`

  | Check | Bucket | Rationale |
  |-------|--------|-----------|
  | `assertStructure` ticker format | ontology-rejected | Canonical key-set |
  | bid <= ask (spread) | ported | Physics of a non-crossed top of book |
  | volumes (base/quote/bid/ask) >= 0 | ported | Non-negative volume physics |
  | high >= low | ported | OHLC range physics |
  | open/close/last within [low, high] when all set | ported | OHLC consistency |
  | last == close when both set | ported | Both fields denote the same closing price |
  | percentage >= -100 | ported | Floor of % change physics |
  | last within 1% of bid/ask midpoint | policy-rejected | False-reds on thin/volatile testnet markets |
  | quoteVolume in [base*low, base*high] band | policy-rejected | Fragile precision/rounding across venues |
  | open/high/low/close/bid/ask/average > 0 | policy-rejected | Zero/placeholder prints appear on illiquid and index-like markets |
  | percentage/change max-increase 100x | policy-rejected | Volatile launches legitimately breach the lab bound |
  | last/percentage/change mutual definability | ontology-rejected | Parser completeness policy, not physics |
  | symbol match | ported | Optional expected-symbol check (existing) |

  ### `base/test.orderBook.ts`

  | Check | Bucket | Rationale |
  |-------|--------|-----------|
  | `assertStructure` | ontology-rejected | Canonical key-set |
  | bids descending / asks ascending by price | ported | Book ordering physics (non-strict: equal prices allowed) |
  | consecutive levels strict inequality | policy-adjusted | Loosened to non-increasing/non-decreasing; venues emit equal-price levels |
  | best bid < best ask (strict) | policy-adjusted | Ported as bid <= ask; locked books with bid==ask are valid |
  | level price > 0, amount > 0 | policy-adjusted | Ported price > 0; amount >= 0 (zero-size levels appear) |
  | symbol match | ported | Optional expected-symbol check |

  ### `base/test.ohlcv.ts` + `test.fetchOHLCV.ts`

  | Check | Bucket | Rationale |
  |-------|--------|-----------|
  | array length / structure | ontology-rejected | List-vs-struct shape is ours |
  | high >= low | ported | Candle range physics |
  | open/close within [low, high] | ported | Candle consistency |
  | volume >= 0 | ported | Non-negative volume |
  | timestamp integer | ported | Candle start ms |
  | round-minute timestamp | policy-rejected | Non-1m timeframes and exchange offsets |
  | sorted timestamps | **repo-owned** | The CCXT compatibility reference leaves this as TODO; we enforce monotone (asc or desc — venues disagree) |

  ### `base/test.trade.ts` + `test.fetchTrades.ts` / `test.fetchMyTrades.ts`

  | Check | Bucket | Rationale |
  |-------|--------|-----------|
  | `assertStructure` | ontology-rejected | Canonical key-set |
  | side in buy/sell | ported | Enum physics |
  | takerOrMaker in taker/maker | ported | Enum when present |
  | price/amount numeric | ported | Existing |
  | price/amount >= 0 | ported | Non-negative quantities |
  | fee structure shape | ontology-rejected | Fee ontology |
  | timestamp order on lists | policy-adjusted | Ported as monotone either direction (venues return asc or newest-first) |

  ### `base/test.balance.ts`

  | Check | Bucket | Rationale |
  |-------|--------|-----------|
  | free/used/total maps present | ported | Existing |
  | numeric amounts | ported | Existing |
  | free/used/total >= 0 | policy-adjusted | Enforced by default. Deribit alone accepts signed currency equity when the caller supplies `venue: "deribit"` (live 2026-07-29: ETH total ≈ −0.19 with short options). |
  | free + used == total when all three set | policy-rejected | False-reds on venues with equity/options/margin buckets beyond free+used (observed deribit live) |
  | all codes appear in every map | policy-rejected | Sparse maps are valid; `Balance.get/2` defaults missing to 0 |
  | non-empty code arrays | policy-rejected | Empty wallet is a valid testnet state |

  ### `base/test.market.ts`

  | Check | Bucket | Rationale |
  |-------|--------|-----------|
  | symbol/base/quote strings, type enum soft check | ported | Existing soft metadata |
  | active boolean when set | ported | Existing |
  | precision/limits are maps when set | ported | Existing shape only — not key completeness |
  | spot/contract/linear/inverse taxonomy | ontology-rejected | CCXT market ontology; our carves diverge |
  | precision must include price+amount | ontology-rejected | Contradicts **C6** (hyperliquid `precision.price` may be nil) |
  | contractSize required/ >0 on contracts | ontology-rejected | Market-side twin of **C7** (payload may omit) |
  | settle required on contracts | ontology-rejected | Venue-specific; not source-agnostic |
  | limits min/max completeness | ontology-rejected | Incomplete limits are common |
  | marginModes cross/isolated keys | ontology-rejected | Not on our Market struct |

  ### `base/test.currency.ts` + `test.fetchCurrencies.ts`

  | Check | Bucket | Rationale |
  |-------|--------|-----------|
  | deposit/withdraw booleans required | ontology-rejected | CCXT currency ontology; not enforced here |
  | precision required | ontology-rejected | Venue gaps; conflicts with sparse currency data |
  | inactive currency percentage quota | policy-rejected | Exchange policy, not response physics |
  | limits min/max relations | ontology-rejected | Not wired into this module (no currency validator path) |

  ### `base/test.position.ts`

  | Check | Bucket | Rationale |
  |-------|--------|-----------|
  | side in long/short | ported | Enum when present |
  | marginMode in cross/isolated | ported | Enum when present |
  | contractSize required / > 0 | ontology-rejected | Contradicts **C7** (nil at parse; market-derived) |
  | leverage/margins/prices > 0 when set | policy-adjusted | Ported soft `> 0` only for leverage/entry/mark when present; others optional |
  | `assertStructure` | ontology-rejected | Canonical key-set |

  ### `base/test.order.ts`

  | Check | Bucket | Rationale |
  |-------|--------|-----------|
  | status/side enums, amount >= filled/remaining | ported lightly | Enum + non-neg amount/filled/remaining when present |
  | `assertStructure` | ontology-rejected | Canonical key-set |
  | timeInForce enum | ontology-rejected | Venue extensions exist beyond CCXT's list |

  ### Repo-owned (beyond the CCXT compatibility catalog)

  | Check | Bucket | Rationale |
  |-------|--------|-----------|
  | OHLCV list monotone non-decreasing timestamps | repo-owned | The CCXT compatibility reference leaves this as TODO |
  | Explicit non-enforcement of C6/C7 nils | repo-owned | Carve register: HL `precision.price` nil, position `contract_size` nil pass |

  ## Invariants enforcement

  All checks **flunk/raise** on breach via `ExUnit.Assertions` — never assert-true on every outcome.
  """

  import ExUnit.Assertions

  alias Bourse.Balance
  alias Bourse.Market
  alias Bourse.OHLCV
  alias Bourse.Order
  alias Bourse.OrderBook
  alias Bourse.Position
  alias Bourse.Ticker
  alias Bourse.Trade

  # Bitcoin genesis window .. signed-32-bit ms overflow (compatibility policy window).
  @min_ts_ms 1_230_940_800_000
  @max_ts_ms 2_147_483_648_000

  @market_types ~w(spot swap future future_combo option option_combo margin index other)
  @trade_sides ~w(buy sell)
  @taker_or_maker ~w(taker maker)
  @position_sides ~w(long short)
  @margin_modes ~w(cross isolated)
  @order_sides ~w(buy sell)
  @order_statuses ~w(open closed canceled cancelled expired rejected)
  @signed_value_venue "deribit"
  @nil_balance_venue "derive"

  @doc """
  Validates a parsed unified response for `method`.

  Dispatches by method first, then falls back to struct type. Unknown shapes are
  a no-op so newer unified types do not break older probes.
  """
  @spec validate_for_method!(atom(), term(), keyword()) :: :ok
  def validate_for_method!(method, data, opts \\ []) do
    dispatch!(method, data, opts)
    :ok
  end

  defp dispatch!(:fetch_balance, %Balance{} = data, opts), do: assert_balance_struct(data, opts)
  defp dispatch!(:fetch_positions, data, opts) when is_list(data), do: assert_position_list!(data, opts)
  defp dispatch!(:fetch_position, %Position{} = data, opts), do: assert_position_struct(data, nil, opts)
  defp dispatch!(method, data, _opts), do: dispatch!(method, data)

  @doc """
  Asserts ticker invariants: optional symbol match, numeric fields, bid <= ask,
  non-negative volumes, OHLC consistency, last==close, percentage floor.
  """
  @spec assert_ticker_struct(Ticker.t(), String.t() | nil) :: :ok
  def assert_ticker_struct(%Ticker{} = ticker, expected_symbol \\ nil) do
    if expected_symbol do
      assert ticker.symbol == expected_symbol,
             "ticker symbol #{inspect(ticker.symbol)} != expected #{inspect(expected_symbol)}"
    end

    for field <- [:last, :bid, :ask, :open, :high, :low, :close, :average, :vwap] do
      assert_optional_numeric!(ticker, field, "ticker")
    end

    for field <- [:bid_volume, :ask_volume, :base_volume, :quote_volume] do
      assert_optional_non_negative!(ticker, field, "ticker")
    end

    assert_ticker_price_relations!(ticker)
    assert_optional_timestamp!(ticker.timestamp, "ticker.timestamp")

    :ok
  end

  # bid<=ask when both sides are present and positive; high>=low; OHLC relations.
  # One-sided quotes (ask=0 or bid=0 outside hours / thin books) are provider-
  # valid — live 2026-07-29 alpaca GLD bid=369.11 ask=0; derive BTC/USDC ask=0.
  defp assert_ticker_price_relations!(%Ticker{} = ticker) do
    if positive_numeric?(ticker.bid) and positive_numeric?(ticker.ask) do
      assert compare_numeric(ticker.bid, ticker.ask) != :gt,
             "ticker bid #{inspect(ticker.bid)} > ask #{inspect(ticker.ask)}"
    end

    if numeric?(ticker.high) and numeric?(ticker.low) do
      assert compare_numeric(ticker.high, ticker.low) != :lt,
             "ticker high #{inspect(ticker.high)} < low #{inspect(ticker.low)}"
    end

    assert_within_high_low!(ticker.open, ticker.high, ticker.low, "ticker.open")
    assert_within_high_low!(ticker.close, ticker.high, ticker.low, "ticker.close")
    assert_within_high_low!(ticker.last, ticker.high, ticker.low, "ticker.last")

    if numeric?(ticker.last) and numeric?(ticker.close) do
      assert compare_numeric(ticker.last, ticker.close) == :eq,
             "ticker last #{inspect(ticker.last)} != close #{inspect(ticker.close)}"
    end

    if numeric?(ticker.percentage) do
      assert compare_numeric(ticker.percentage, -100) != :lt,
             "ticker percentage must be >= -100, got #{inspect(ticker.percentage)}"
    end
  end

  @doc """
  Asserts order book invariants: optional symbol match, sorted levels, no crossed book.
  """
  @spec assert_order_book_struct(OrderBook.t(), String.t() | nil) :: :ok
  def assert_order_book_struct(%OrderBook{} = book, expected_symbol \\ nil) do
    if expected_symbol do
      assert book.symbol == expected_symbol,
             "order book symbol #{inspect(book.symbol)} != expected #{inspect(expected_symbol)}"
    end

    assert_levels_sorted!(book.bids, :desc, "bids")
    assert_levels_sorted!(book.asks, :asc, "asks")
    refute_crossed_book!(book)
    assert_optional_timestamp!(book.timestamp, "order_book.timestamp")

    :ok
  end

  @doc """
  Asserts balance maps are present with numeric amounts.

  Does **not** enforce free+used==total (policy-rejected: venues with equity/options
  margin report totals outside free+used — observed on deribit testnet).

  Non-negative amounts are enforced unless `venue: "deribit"` is supplied.
  Deribit's account-summary contract defines equity as a numeric margin value,
  and its live portfolio-margin account can report negative currency equity:
  https://docs.deribit.com/api-reference/account-management/private-get_account_summary

  Nil free/used amounts are accepted only with `venue: "derive"`. Derive's
  provider response supplies collateral totals but no per-asset free/used
  fields (see `docs/authored-spec-carves/derive.md`, C-T528b).
  """
  @spec assert_balance_struct(Balance.t(), keyword()) :: :ok
  def assert_balance_struct(%Balance{} = balance, opts \\ []) do
    venue = Keyword.get(opts, :venue)
    allow_signed? = venue == @signed_value_venue
    allow_nil? = venue == @nil_balance_venue

    assert_currency_map!(balance.free, "balance.free", allow_signed?, allow_nil?)
    assert_currency_map!(balance.used, "balance.used", allow_signed?, allow_nil?)
    assert_currency_map!(balance.total, "balance.total", allow_signed?, allow_nil?)
    assert_optional_timestamp!(balance.timestamp, "balance.timestamp")
    :ok
  end

  @doc """
  Asserts each OHLCV candle has integer timestamp, high >= low, open/close in range,
  volume >= 0, and (list) monotone timestamps either direction (repo-owned).

  Accepts `%OHLCV{}` or Bourse list-form `[timestamp, open, high, low, close, volume?]`.
  """
  @spec assert_ohlcv_list([OHLCV.t() | list()]) :: :ok
  def assert_ohlcv_list(candles) when is_list(candles) do
    normalized = Enum.map(candles, &normalize_ohlcv!/1)
    Enum.each(normalized, &assert_ohlcv_struct!/1)
    # Repo-owned; either direction — some venues return newest-first.
    assert_monotone_timestamps!(normalized, & &1.timestamp, "ohlcv", :either)
    :ok
  end

  @doc """
  Asserts trade invariants: optional symbol match, numeric non-negative price/amount,
  valid side/taker_or_maker, optional timestamp window.
  """
  @spec assert_trade_struct(Trade.t(), String.t() | nil) :: :ok
  def assert_trade_struct(%Trade{} = trade, expected_symbol \\ nil) do
    if expected_symbol do
      assert trade.symbol == expected_symbol,
             "trade symbol #{inspect(trade.symbol)} != expected #{inspect(expected_symbol)}"
    end

    for field <- [:price, :amount, :cost] do
      assert_optional_numeric!(trade, field, "trade")
    end

    for field <- [:price, :amount, :cost] do
      assert_optional_non_negative!(trade, field, "trade")
    end

    if trade.side do
      assert trade.side in @trade_sides,
             "trade.side must be buy or sell, got #{inspect(trade.side)}"
    end

    if trade.taker_or_maker do
      assert trade.taker_or_maker in @taker_or_maker,
             "trade.taker_or_maker must be taker or maker, got #{inspect(trade.taker_or_maker)}"
    end

    assert_optional_timestamp!(trade.timestamp, "trade.timestamp")

    :ok
  end

  @doc """
  Asserts a list of trades individually and non-decreasing timestamp order when set.
  """
  @spec assert_trade_list([Trade.t()]) :: :ok
  def assert_trade_list(trades) when is_list(trades) do
    assert_trade_list!(trades)
    :ok
  end

  @doc """
  Asserts market metadata: symbol/base/quote strings and known type when set.

  Deliberately does **not** require `precision.price` (carve C6) or `contract_size`
  (market-side twin of carve C7).
  """
  @spec assert_market_struct(Market.t()) :: :ok
  def assert_market_struct(%Market{} = market) do
    assert is_binary(market.symbol) and market.symbol != "",
           "market.symbol must be a non-empty string, got #{inspect(market.symbol)}"

    for field <- [:base, :quote] do
      value = Map.get(market, field)

      if not is_nil(value) do
        assert is_binary(value),
               "market.#{field} must be a string, got #{inspect(value)}"
      end
    end

    if market.type do
      assert market.type in @market_types,
             "market.type must be one of #{inspect(@market_types)}, got #{inspect(market.type)}"
    end

    if not is_nil(market.active) do
      assert is_boolean(market.active),
             "market.active must be boolean, got #{inspect(market.active)}"
    end

    for field <- [:precision, :limits] do
      value = Map.get(market, field)

      if not is_nil(value) do
        assert is_map(value),
               "market.#{field} must be a map, got #{inspect(value)}"
      end
    end

    # C6/C7: nil precision.price and nil contract_size are explicitly allowed.
    :ok
  end

  @doc """
  Asserts position enums and soft positivity; **does not** require `contract_size` (C7).

  `contracts` is non-negative unless `venue: "deribit"` is supplied. Deribit's
  position contract defines `direction` as `buy | sell | zero`; the authored
  normalization represents `sell` as a negative contract count (live
  2026-07-29: ETH option contracts = −6.0):
  https://docs.deribit.com/api-reference/account-management/private-get_positions
  """
  @spec assert_position_struct(Position.t(), String.t() | nil, keyword()) :: :ok
  def assert_position_struct(%Position{} = position, expected_symbol \\ nil, opts \\ []) do
    if expected_symbol do
      assert position.symbol == expected_symbol,
             "position symbol #{inspect(position.symbol)} != expected #{inspect(expected_symbol)}"
    end

    if position.side do
      assert position.side in @position_sides,
             "position.side must be long or short, got #{inspect(position.side)}"
    end

    if position.margin_mode do
      assert position.margin_mode in @margin_modes,
             "position.margin_mode must be cross or isolated, got #{inspect(position.margin_mode)}"
    end

    for field <- [:leverage, :mark_price] do
      assert_positive_position_field!(position, field)
    end

    assert_position_entry_price!(position)
    assert_position_contracts!(position, opts)

    # C7: contract_size may be nil — do not require or bound it.
    assert_optional_timestamp!(position.timestamp, "position.timestamp")

    :ok
  end

  @doc """
  Asserts order side/status enums and non-negative amount/filled/remaining relations.
  """
  @spec assert_order_struct(Order.t(), String.t() | nil) :: :ok
  def assert_order_struct(%Order{} = order, expected_symbol \\ nil) do
    if expected_symbol do
      assert order.symbol == expected_symbol,
             "order symbol #{inspect(order.symbol)} != expected #{inspect(expected_symbol)}"
    end

    if order.side do
      assert order.side in @order_sides,
             "order.side must be buy or sell, got #{inspect(order.side)}"
    end

    if order.status do
      assert order.status in @order_statuses,
             "order.status must be one of #{inspect(@order_statuses)}, got #{inspect(order.status)}"
    end

    for field <- [:amount, :filled, :remaining, :cost, :price] do
      assert_optional_non_negative!(order, field, "order")
    end

    if numeric?(order.amount) and numeric?(order.filled) do
      assert compare_numeric(order.amount, order.filled) != :lt,
             "order.amount #{inspect(order.amount)} < filled #{inspect(order.filled)}"
    end

    if numeric?(order.amount) and numeric?(order.remaining) do
      assert compare_numeric(order.amount, order.remaining) != :lt,
             "order.amount #{inspect(order.amount)} < remaining #{inspect(order.remaining)}"
    end

    assert_optional_timestamp!(order.timestamp, "order.timestamp")

    :ok
  end

  defp dispatch!(:fetch_ticker, %Ticker{} = data), do: assert_ticker_struct(data)
  defp dispatch!(:fetch_order_book, %OrderBook{} = data), do: assert_order_book_struct(data)
  defp dispatch!(:fetch_balance, %Balance{} = data), do: assert_balance_struct(data)
  defp dispatch!(:fetch_ohlcv, data) when is_list(data), do: assert_ohlcv_list(data)
  defp dispatch!(:fetch_trades, data) when is_list(data), do: assert_trade_list!(data)
  defp dispatch!(:fetch_markets, data) when is_list(data), do: assert_market_list!(data)
  defp dispatch!(:fetch_my_trades, data) when is_list(data), do: assert_trade_list!(data)
  defp dispatch!(:fetch_positions, data) when is_list(data), do: assert_position_list!(data)
  defp dispatch!(:fetch_position, %Position{} = data), do: assert_position_struct(data)
  defp dispatch!(:fetch_open_orders, data) when is_list(data), do: assert_order_list!(data)
  defp dispatch!(:fetch_closed_orders, data) when is_list(data), do: assert_order_list!(data)
  defp dispatch!(:fetch_orders, data) when is_list(data), do: assert_order_list!(data)
  defp dispatch!(:fetch_order, %Order{} = data), do: assert_order_struct(data)

  defp dispatch!(_method, %Ticker{} = data), do: assert_ticker_struct(data)
  defp dispatch!(_method, %OrderBook{} = data), do: assert_order_book_struct(data)
  defp dispatch!(_method, %Balance{} = data), do: assert_balance_struct(data)
  defp dispatch!(_method, %Trade{} = data), do: assert_trade_struct(data)
  defp dispatch!(_method, %Market{} = data), do: assert_market_struct(data)
  defp dispatch!(_method, %Position{} = data), do: assert_position_struct(data)
  defp dispatch!(_method, %Order{} = data), do: assert_order_struct(data)
  defp dispatch!(_method, %OHLCV{} = data), do: assert_ohlcv_list([data])
  defp dispatch!(_method, data) when is_list(data), do: dispatch_list!(data)
  defp dispatch!(_method, _data), do: :ok

  defp dispatch_list!([%Trade{} | _] = trades), do: assert_trade_list!(trades)
  defp dispatch_list!([%OHLCV{} | _] = candles), do: assert_ohlcv_list(candles)
  defp dispatch_list!([%Market{} | _] = markets), do: assert_market_list!(markets)
  defp dispatch_list!([%Position{} | _] = positions), do: assert_position_list!(positions)
  defp dispatch_list!([%Order{} | _] = orders), do: assert_order_list!(orders)
  defp dispatch_list!(_other), do: :ok

  defp assert_trade_list!(trades) do
    Enum.each(trades, &assert_trade_struct/1)
    # Policy-adjusted from the CCXT compatibility validator's ascending-only rule:
    # exchanges commonly return newest-first.
    assert_monotone_timestamps!(trades, & &1.timestamp, "trades", :either)
  end

  defp assert_market_list!(markets) do
    Enum.each(markets, &assert_market_struct/1)
  end

  defp assert_position_list!(positions, opts \\ []) do
    Enum.each(positions, &assert_position_struct(&1, nil, opts))
  end

  defp assert_order_list!(orders) do
    Enum.each(orders, &assert_order_struct/1)
  end

  defp normalize_ohlcv!(%OHLCV{} = candle), do: candle

  defp normalize_ohlcv!([ts, open, high, low, close | rest]) do
    volume = List.first(rest)

    %OHLCV{
      timestamp: coerce_timestamp!(ts, "ohlcv.timestamp"),
      open: open,
      high: high,
      low: low,
      close: close,
      volume: volume
    }
  end

  defp normalize_ohlcv!(other), do: flunk("ohlcv candle must be %OHLCV{} or [ts,o,h,l,c,v?], got #{inspect(other)}")

  defp coerce_timestamp!(ts, _label) when is_integer(ts), do: ts

  defp coerce_timestamp!(ts, label) when is_binary(ts) do
    case Integer.parse(ts) do
      {int, ""} -> int
      _ -> flunk("#{label} must be integer or integer string, got #{inspect(ts)}")
    end
  end

  defp coerce_timestamp!(ts, label), do: flunk("#{label} must be integer, got #{inspect(ts)}")

  defp assert_ohlcv_struct!(%OHLCV{} = candle) do
    assert is_integer(candle.timestamp),
           "ohlcv.timestamp must be integer, got #{inspect(candle.timestamp)}"

    assert_optional_timestamp!(candle.timestamp, "ohlcv.timestamp")

    for field <- [:open, :high, :low, :close, :volume] do
      assert_optional_numeric!(candle, field, "ohlcv")
    end

    if numeric?(candle.high) and numeric?(candle.low) do
      assert compare_numeric(candle.high, candle.low) != :lt,
             "ohlcv high #{inspect(candle.high)} < low #{inspect(candle.low)}"
    end

    assert_within_high_low!(candle.open, candle.high, candle.low, "ohlcv.open")
    assert_within_high_low!(candle.close, candle.high, candle.low, "ohlcv.close")

    if numeric?(candle.volume) do
      assert compare_numeric(candle.volume, 0) != :lt,
             "ohlcv volume must be >= 0, got #{inspect(candle.volume)}"
    end
  end

  defp assert_levels_sorted!(levels, _order, _label) when levels in [nil, []], do: :ok

  defp assert_levels_sorted!(levels, order, label) when is_list(levels) do
    Enum.each(levels, fn level ->
      assert_level_pair!(level, label)
    end)

    prices = Enum.map(levels, &level_price/1)

    assert prices == sort_prices(prices, order),
           "#{label} must be #{order}ending by price, got #{inspect(prices)}"
  end

  defp assert_levels_sorted!(levels, _order, label), do: flunk("#{label} must be a list, got #{inspect(levels)}")

  defp assert_level_pair!([price, amount], label) do
    assert numeric?(price), "#{label} price must be numeric, got #{inspect(price)}"
    assert numeric?(amount), "#{label} amount must be numeric, got #{inspect(amount)}"

    assert compare_numeric(price, 0) == :gt,
           "#{label} price must be > 0, got #{inspect(price)}"

    assert compare_numeric(amount, 0) != :lt,
           "#{label} amount must be >= 0, got #{inspect(amount)}"
  end

  defp assert_level_pair!(level, label),
    do: flunk("#{label} level must be exactly [price, amount], got #{inspect(level)}")

  defp refute_crossed_book!(%OrderBook{} = book) do
    bid = OrderBook.best_bid(book)
    ask = OrderBook.best_ask(book)

    if numeric?(bid) and numeric?(ask) do
      refute compare_numeric(bid, ask) == :gt,
             "crossed book: best bid #{inspect(bid)} > best ask #{inspect(ask)}"
    end
  end

  defp assert_currency_map!(map, label, allow_signed?, allow_nil?) do
    assert is_map(map), "#{label} must be a map, got #{inspect(map)}"

    Enum.each(map, fn {currency, amount} ->
      assert is_binary(currency),
             "#{label} currency keys must be strings, got #{inspect(currency)}"

      assert allow_nil? or numeric?(amount),
             "#{label}[#{currency}] must be numeric, got #{inspect(amount)}"

      if not is_nil(amount) and not allow_signed? do
        assert compare_numeric(amount, 0) != :lt,
               "#{label}[#{currency}] must be >= 0, got #{inspect(amount)}"
      end
    end)
  end

  defp assert_positive_position_field!(position, field) do
    value = Map.get(position, field)

    if numeric?(value) do
      assert compare_numeric(value, 0) == :gt,
             "position.#{field} must be > 0 when set, got #{inspect(value)}"
    end
  end

  # Flat / zero-size rows may carry entry_price 0.0 (Deribit live). Only require
  # a positive entry when the position has non-zero contracts.
  defp assert_position_entry_price!(%Position{} = position) do
    if numeric?(position.entry_price) do
      nonzero_contracts? =
        numeric?(position.contracts) and compare_numeric(position.contracts, 0) != :eq

      comparison = compare_numeric(position.entry_price, 0)

      assert (nonzero_contracts? and comparison == :gt) or
               (not nonzero_contracts? and comparison != :lt),
             "position.entry_price must be positive for non-zero contracts and non-negative otherwise, " <>
               "got #{inspect(position.entry_price)}"
    end
  end

  defp assert_position_contracts!(%Position{contracts: nil}, _opts), do: :ok

  defp assert_position_contracts!(%Position{} = position, opts) do
    assert numeric?(position.contracts),
           "position.contracts must be numeric, got #{inspect(position.contracts)}"

    if compare_numeric(position.contracts, 0) == :lt do
      assert Keyword.get(opts, :venue) == @signed_value_venue and position.side == "short",
             "position.contracts must be >= 0 unless Deribit reports a short, got " <>
               "#{inspect(position.contracts)} for venue #{inspect(Keyword.get(opts, :venue))} " <>
               "and side #{inspect(position.side)}"
    end
  end

  defp assert_within_high_low!(value, high, low, label) do
    if numeric?(value) and numeric?(high) and numeric?(low) do
      assert compare_numeric(value, low) != :lt,
             "#{label} #{inspect(value)} < low #{inspect(low)}"

      assert compare_numeric(value, high) != :gt,
             "#{label} #{inspect(value)} > high #{inspect(high)}"
    end
  end

  defp assert_monotone_timestamps!(items, ts_fun, label, direction) when is_list(items) do
    timestamps =
      items
      |> Enum.map(ts_fun)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&is_integer/1)

    case {direction, timestamps} do
      {_, []} ->
        :ok

      {_, [_]} ->
        :ok

      {:asc, ts} ->
        assert ts == Enum.sort(ts),
               "#{label} timestamps must be non-decreasing, got #{inspect(ts)}"

      {:desc, ts} ->
        assert ts == Enum.sort(ts, :desc),
               "#{label} timestamps must be non-increasing, got #{inspect(ts)}"

      {:either, ts} ->
        asc? = ts == Enum.sort(ts)
        desc? = ts == Enum.sort(ts, :desc)

        assert asc? or desc?,
               "#{label} timestamps must be monotone (asc or desc), got #{inspect(ts)}"
    end
  end

  defp assert_optional_timestamp!(nil, _label), do: :ok

  defp assert_optional_timestamp!(ts, label) do
    assert is_integer(ts), "#{label} must be integer, got #{inspect(ts)}"

    assert ts > @min_ts_ms,
           "#{label} #{ts} is before Bitcoin genesis window (#{@min_ts_ms})"

    assert ts < @max_ts_ms,
           "#{label} #{ts} is after 2038-01-19 bound (#{@max_ts_ms})"
  end

  defp assert_optional_numeric!(struct, field, label) do
    value = Map.get(struct, field)

    if not is_nil(value) do
      assert numeric?(value),
             "#{label}.#{field} must be numeric, got #{inspect(value)}"
    end
  end

  defp assert_optional_non_negative!(struct, field, label) do
    value = Map.get(struct, field)

    if numeric?(value) do
      assert compare_numeric(value, 0) != :lt,
             "#{label}.#{field} must be >= 0, got #{inspect(value)}"
    end
  end

  defp level_price([price | _]), do: to_float(price)
  defp level_price(_), do: flunk("order book level missing price")

  defp sort_prices(prices, :asc), do: Enum.sort(prices)
  defp sort_prices(prices, :desc), do: Enum.sort(prices, :desc)

  defp numeric?(value) when is_number(value), do: true

  defp numeric?(value) when is_binary(value) do
    match?({_num, ""}, Float.parse(value))
  end

  defp numeric?(_), do: false

  defp positive_numeric?(value), do: numeric?(value) and compare_numeric(value, 0) == :gt

  defp compare_numeric(left, right) do
    left_f = to_float(left)
    right_f = to_float(right)

    cond do
      left_f > right_f -> :gt
      left_f < right_f -> :lt
      true -> :eq
    end
  end

  defp to_float(value) when is_number(value), do: value * 1.0

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {num, ""} -> num
      _ -> flunk("expected numeric string, got #{inspect(value)}")
    end
  end
end
