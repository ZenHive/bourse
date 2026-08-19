defmodule Bourse.Test.TimeWindowProbeMatrix do
  @moduledoc """
  Live time-window probes and explicit exclusions for supported unified reads.

  A probe must assert returned timestamps at both requested boundaries. A
  successful response without that timestamp assertion is not coverage.

  Unified `since` and `until` are inclusive. Venues with exclusive cursors
  compensate on the request: OKX pagination `before`/`after` send
  `before = since - 1` and `after = until + 1` (candles, deposits,
  withdrawals, and positions-history).

  The live `until` direction mutation-killed OKX's translation. The live
  `since` direction does not prove request translation: `ReadParse`'s
  `filter_ohlcv_by_since/2` and `filter_by_since/2` can rebuild the requested
  lower boundary from a venue's default page. The offline request-shape guard
  below proves that direction and catches a deleted translation before parse.
  """

  @type probe :: %{
          venue: atom(),
          method: atom(),
          args: [term()],
          opts: keyword(),
          exchange_opts: keyword(),
          credentials: boolean(),
          tolerance_ms: non_neg_integer()
        }

  @type exclusion :: %{
          venue: atom(),
          methods: [atom()],
          reason: String.t(),
          tracking: String.t()
        }

  @one_second_ms 1_000
  @one_minute_ms 60 * @one_second_ms

  @probes [
    %{
      venue: :alpaca,
      method: :fetch_ohlcv,
      args: ["GLD", "1d"],
      opts: [],
      exchange_opts: [],
      credentials: true,
      tolerance_ms: @one_second_ms
    },
    %{
      venue: :alpaca,
      method: :fetch_trades,
      args: ["GLD"],
      opts: [],
      exchange_opts: [],
      credentials: true,
      tolerance_ms: @one_second_ms
    },
    %{
      venue: :binance,
      method: :fetch_ohlcv,
      args: ["BTC/USDT", "1m"],
      opts: [],
      exchange_opts: [sandbox: true],
      credentials: false,
      tolerance_ms: @one_second_ms
    },
    %{
      venue: :binance,
      method: :fetch_trades,
      args: ["BTC/USDT"],
      opts: [],
      exchange_opts: [sandbox: true],
      credentials: false,
      tolerance_ms: @one_second_ms
    },
    %{
      venue: :binance,
      method: :fetch_orders,
      args: [],
      opts: [symbol: "BTC/USDT"],
      exchange_opts: [sandbox: true],
      credentials: true,
      tolerance_ms: @one_second_ms
    },
    %{
      venue: :binancecoinm,
      method: :fetch_trades,
      args: ["BTC/USD:BTC"],
      opts: [],
      exchange_opts: [sandbox: true],
      credentials: false,
      tolerance_ms: @one_minute_ms
    },
    %{
      venue: :binanceusdm,
      method: :fetch_ohlcv,
      args: ["BTC/USDT:USDT", "1m"],
      opts: [],
      exchange_opts: [sandbox: true],
      credentials: false,
      tolerance_ms: @one_second_ms
    },
    %{
      venue: :binanceusdm,
      method: :fetch_trades,
      args: ["BTC/USDT:USDT"],
      opts: [],
      exchange_opts: [sandbox: true],
      credentials: false,
      tolerance_ms: @one_second_ms
    },
    %{
      venue: :binanceusdm,
      method: :fetch_orders,
      args: [],
      opts: [symbol: "BTC/USDT:USDT"],
      exchange_opts: [sandbox: true],
      credentials: true,
      tolerance_ms: @one_second_ms
    },
    %{
      venue: :binanceusdm,
      method: :fetch_my_trades,
      args: [],
      opts: [symbol: "BTC/USDT:USDT"],
      exchange_opts: [sandbox: true],
      credentials: true,
      tolerance_ms: @one_second_ms
    },
    %{
      venue: :bybit,
      method: :fetch_ohlcv,
      args: ["BTC/USDT", "1m"],
      opts: [],
      exchange_opts: [sandbox: true],
      credentials: false,
      tolerance_ms: @one_second_ms
    },
    %{
      venue: :coinbaseexchange,
      method: :fetch_ohlcv,
      args: ["ETH/USD", "1m"],
      opts: [],
      exchange_opts: [],
      credentials: false,
      tolerance_ms: @one_second_ms
    },
    %{
      venue: :deribit,
      method: :fetch_ohlcv,
      args: ["BTC/USD:BTC", "1m"],
      opts: [],
      exchange_opts: [sandbox: true],
      credentials: false,
      tolerance_ms: @one_second_ms
    },
    %{
      venue: :deribit,
      method: :fetch_trades,
      args: ["BTC/USD:BTC"],
      opts: [],
      exchange_opts: [sandbox: true],
      credentials: false,
      tolerance_ms: @one_second_ms
    },
    %{
      venue: :derive,
      method: :fetch_trades,
      args: ["BTC/USD:USDC"],
      opts: [],
      exchange_opts: [sandbox: true],
      credentials: false,
      tolerance_ms: @one_minute_ms
    },
    %{
      venue: :hyperliquid,
      method: :fetch_ohlcv,
      args: ["BTC/USDC:USDC", "1h"],
      opts: [],
      exchange_opts: [sandbox: true],
      credentials: false,
      tolerance_ms: @one_second_ms
    },
    %{
      venue: :lighter,
      method: :fetch_ohlcv,
      args: ["BTC/USDC:USDC", "1m"],
      opts: [],
      exchange_opts: [sandbox: true],
      credentials: false,
      tolerance_ms: @one_minute_ms
    },
    %{
      venue: :okx,
      method: :fetch_ohlcv,
      args: ["BTC/USDT", "1h"],
      opts: [],
      exchange_opts: [sandbox: true, hostname: "www.okx.com"],
      credentials: false,
      tolerance_ms: @one_second_ms
    }
  ]

  @exclusions [
    %{
      venue: :alpaca,
      methods: [:fetch_closed_orders, :fetch_open_orders, :fetch_orders],
      reason: "paper order-history rows depend on account activity and are not guaranteed to populate",
      tracking: "docs/prod-verification-ledger.md — task 526 residual oracle critical slots"
    },
    %{
      venue: :alpaca,
      methods: [:fetch_my_trades],
      reason:
        "paper GET /v2/account/activities/FILL returns an empty list; the account's only activity is a JNLC funding journal, so both window boundaries cannot be asserted",
      tracking: "docs/authored-spec-carves/alpaca.md C-T547a — task 547"
    },
    %{
      venue: :binance,
      methods: [
        :fetch_borrow_interest,
        :fetch_borrow_rate_history,
        :fetch_convert_trade_history,
        :fetch_deposits,
        :fetch_ledger,
        :fetch_margin_adjustment_history,
        :fetch_transfers,
        :fetch_withdrawals
      ],
      reason: "SAPI history has no Binance spot sandbox host",
      tracking: "docs/prod-verification-ledger.md — task 341 Binance SAPI/EAPI production reads"
    },
    %{
      venue: :binance,
      methods: [
        :fetch_canceled_and_closed_orders,
        :fetch_canceled_orders,
        :fetch_closed_orders,
        :fetch_funding_history,
        :fetch_funding_rate_history,
        :fetch_long_short_ratio_history,
        :fetch_my_liquidations,
        :fetch_my_trades,
        :fetch_open_orders,
        :fetch_order_lists,
        :fetch_order_trades
      ],
      reason:
        "these histories do not have a stable populated boundary on the provisioned spot account; " <>
          "fetch_my_trades returned zero rows for BTC, ETH, BNB, LTC, and TRX pairs on 2026-08-14",
      tracking: "docs/prod-verification-ledger.md — task 526 residual oracle critical slots"
    },
    %{
      venue: :binancecoinm,
      methods: [
        :fetch_canceled_orders,
        :fetch_closed_orders,
        :fetch_funding_rate_history,
        :fetch_ledger,
        :fetch_my_trades,
        :fetch_open_orders,
        :fetch_orders
      ],
      reason: "the COIN-M demo wallet does not guarantee populated account-history boundaries",
      tracking: "docs/prod-verification-ledger.md — task 526 residual oracle critical slots"
    },
    %{
      venue: :binanceusdm,
      methods: [
        :fetch_borrow_interest,
        :fetch_borrow_rate_history,
        :fetch_canceled_and_closed_orders,
        :fetch_canceled_orders,
        :fetch_closed_orders,
        :fetch_convert_trade_history,
        :fetch_deposits,
        :fetch_funding_history,
        :fetch_funding_rate_history,
        :fetch_ledger,
        :fetch_long_short_ratio_history,
        :fetch_margin_adjustment_history,
        :fetch_my_liquidations,
        :fetch_open_orders,
        :fetch_order_trades,
        :fetch_transfers,
        :fetch_withdrawals
      ],
      reason: "these demo histories do not guarantee populated rows at both requested boundaries",
      tracking: "docs/prod-verification-ledger.md — tasks 526, 567, and 568"
    },
    %{
      venue: :bybit,
      methods: [
        :fetch_borrow_rate_history,
        :fetch_canceled_and_closed_orders,
        :fetch_canceled_orders,
        :fetch_closed_orders,
        :fetch_convert_trade_history,
        :fetch_deposits,
        :fetch_funding_history,
        :fetch_funding_rate_history,
        :fetch_ledger,
        :fetch_long_short_ratio_history,
        :fetch_my_liquidations,
        :fetch_my_trades,
        :fetch_open_orders,
        :fetch_order_trades,
        :fetch_orders_classic,
        :fetch_positions_history,
        :fetch_transfers,
        :fetch_withdrawals
      ],
      reason: "the read-only testnet key and demo state do not guarantee populated history boundaries",
      tracking: "docs/prod-verification-ledger.md — tasks 526 and 567"
    },
    %{
      venue: :bybit,
      methods: [:fetch_trades],
      reason:
        "public recent-trades read: the authored endpoint (v5/market/recent-trade) carries no time " <>
          "parameters at all, so window translation is unsupported by the venue surface — not account state",
      tracking: "roadmap task 617 — offline since/until read guard enumerates unsupported surfaces"
    },
    %{
      venue: :deribit,
      methods: [
        :fetch_closed_orders,
        :fetch_deposits,
        :fetch_funding_rate_history,
        :fetch_my_liquidations,
        :fetch_my_trades,
        :fetch_open_orders,
        :fetch_order_trades,
        :fetch_transfers,
        :fetch_withdrawals
      ],
      reason: "the test account does not guarantee populated rows for these history windows",
      tracking: "docs/prod-verification-ledger.md — task 526 residual oracle critical slots"
    },
    %{
      venue: :derive,
      methods: [
        :fetch_canceled_orders,
        :fetch_closed_orders,
        :fetch_deposits,
        :fetch_funding_history,
        :fetch_funding_rate_history,
        :fetch_my_trades,
        :fetch_open_orders,
        :fetch_order_trades,
        :fetch_orders,
        :fetch_transfers,
        :fetch_withdrawals
      ],
      reason: "demo portfolio histories are sparse or require populated private account state",
      tracking: "docs/prod-verification-ledger.md — tasks 526 and 594"
    },
    %{
      venue: :hyperliquid,
      methods: [
        :fetch_canceled_and_closed_orders,
        :fetch_canceled_orders,
        :fetch_closed_orders,
        :fetch_deposits,
        :fetch_funding_history,
        :fetch_funding_rate_history,
        :fetch_ledger,
        :fetch_my_trades,
        :fetch_open_orders,
        :fetch_orders,
        :fetch_withdrawals
      ],
      reason: "wallet-scoped histories do not guarantee enough populated testnet rows for two boundaries",
      tracking: "docs/prod-verification-ledger.md — tasks 526 and 568"
    },
    %{
      venue: :lighter,
      methods: [
        :fetch_closed_orders,
        :fetch_deposits,
        :fetch_funding_rate_history,
        :fetch_my_liquidations,
        :fetch_my_trades,
        :fetch_open_orders,
        :fetch_transfers,
        :fetch_withdrawals
      ],
      reason: "testnet account histories do not guarantee populated rows at both boundaries",
      tracking: "docs/prod-verification-ledger.md — task 526 residual oracle critical slots"
    },
    %{
      venue: :okx,
      methods: [
        :fetch_borrow_interest,
        :fetch_borrow_rate_history,
        :fetch_canceled_orders,
        :fetch_closed_orders,
        :fetch_convert_trade_history,
        :fetch_deposits,
        :fetch_funding_history,
        :fetch_funding_rate_history,
        :fetch_ledger,
        :fetch_long_short_ratio_history,
        :fetch_margin_adjustment_history,
        :fetch_my_trades,
        :fetch_open_orders,
        :fetch_order_trades,
        :fetch_positions_history,
        :fetch_transfers,
        :fetch_withdrawals
      ],
      reason: "international demo histories do not guarantee populated rows at both boundaries",
      tracking: "docs/prod-verification-ledger.md — tasks 526, 567, and 568"
    },
    %{
      venue: :okx,
      methods: [:fetch_trades],
      reason:
        "public trades read: the authored fetchTrades request declares only instId " <>
          "(public_get_market_trades), so since/until never reach the wire — an authored-coverage gap, " <>
          "not demo account state",
      tracking: "roadmap task 617 — offline since/until read guard enumerates unmapped reads"
    }
  ]

  @doc "Returns live probes which prove both returned time boundaries."
  @spec probes() :: [probe()]
  def probes, do: @probes

  @doc "Returns every intentionally unprobed venue/method pair with its tracking reference."
  @spec exclusions() :: [exclusion()]
  def exclusions, do: @exclusions
end

defmodule Bourse.TimeWindowProbeInventoryTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Registry
  alias Bourse.Test.RequestCollector
  alias Bourse.Test.TimeWindowProbeMatrix
  alias Bourse.Unified
  alias Bourse.Unified.Descriptor
  alias Bourse.Unified.RequestShape

  @since_ms 1_700_000_000_000
  @until_ms 1_700_003_600_000
  @request_limit 2
  @exclusive_cursor_offset_ms 1

  # Exclusive pagination cursors: the provider documents that the cursor value
  # itself is excluded from the page. Inclusive native time filters are listed
  # with an empty cursor set so a new runtime venue cannot skip confrontation.
  # Authority for each row is that venue's pagination/history contract, indexed
  # from priv/authority/<venue>/manifest.json.
  @exclusive_cursors %{
    "okx" => %{
      "before" => %{unified: "since", offset: -1, transform: "decrement"},
      "after" => %{unified: "until", offset: 1, transform: "increment"}
    }
  }

  @inclusive_bound_venues ~w(
    alpaca binance binancecoinm binanceusdm bybit coinbaseexchange
    deribit derive hyperliquid lighter
  )

  @pinned_live_probes MapSet.new([
                        {:alpaca, :fetch_ohlcv},
                        {:alpaca, :fetch_trades},
                        {:binance, :fetch_ohlcv},
                        {:binance, :fetch_orders},
                        {:binance, :fetch_trades},
                        {:binancecoinm, :fetch_trades},
                        {:binanceusdm, :fetch_my_trades},
                        {:binanceusdm, :fetch_ohlcv},
                        {:binanceusdm, :fetch_orders},
                        {:binanceusdm, :fetch_trades},
                        {:bybit, :fetch_ohlcv},
                        {:coinbaseexchange, :fetch_ohlcv},
                        {:deribit, :fetch_ohlcv},
                        {:deribit, :fetch_trades},
                        {:derive, :fetch_trades},
                        {:hyperliquid, :fetch_ohlcv},
                        {:lighter, :fetch_ohlcv},
                        {:okx, :fetch_ohlcv}
                      ])

  @raw_window_allowlist [
    %{
      venue: :alpaca,
      methods: [:fetch_my_trades],
      raw_keys: ["until"],
      contract:
        "priv/authority/alpaca/manifest.json — Trading API GET /v2/account/activities/{activity_type} names the native upper bound until"
    },
    %{
      venue: :alpaca,
      methods: [:fetch_closed_orders, :fetch_open_orders, :fetch_orders],
      raw_keys: ["since", "until"],
      contract:
        "priv/authority/alpaca/manifest.json — Trading API GET /v2/orders exposes after/until; untranslated unified bounds are an explicit request-side carve"
    },
    %{
      venue: :binance,
      methods: [
        :fetch_borrow_rate_history,
        :fetch_convert_trade_history,
        :fetch_deposits,
        :fetch_funding_history,
        :fetch_funding_rate_history,
        :fetch_ledger,
        :fetch_long_short_ratio_history,
        :fetch_margin_adjustment_history,
        :fetch_my_liquidations,
        :fetch_transfers,
        :fetch_withdrawals
      ],
      raw_keys: ["since", "until"],
      contract:
        "priv/authority/binance/manifest.json — Spot/SAPI and umbrella derivatives history contracts have no authored bound mapping; raw since/until pass through until a method-specific rename or omit is authored"
    },
    %{
      venue: :binancecoinm,
      methods: [:fetch_ledger],
      raw_keys: ["since", "until"],
      contract:
        "priv/authority/binancecoinm/manifest.json — COIN-M income history has no authored bound mapping; raw since/until pass through"
    },
    %{
      venue: :binanceusdm,
      methods: [
        :fetch_borrow_interest,
        :fetch_borrow_rate_history,
        :fetch_convert_trade_history,
        :fetch_deposits,
        :fetch_funding_history,
        :fetch_funding_rate_history,
        :fetch_ledger,
        :fetch_long_short_ratio_history,
        :fetch_margin_adjustment_history,
        :fetch_my_liquidations,
        :fetch_transfers,
        :fetch_withdrawals
      ],
      raw_keys: ["since", "until"],
      contract:
        "priv/authority/binanceusdm/manifest.json — USD-M funding, ledger, deposit, transfer, and ratio history contracts have no authored bound mapping; raw since/until pass through"
    },
    %{
      venue: :bybit,
      methods: [:fetch_deposits, :fetch_orders_classic, :fetch_trades, :fetch_withdrawals],
      raw_keys: ["since", "until"],
      contract:
        "priv/authority/bybit/manifest.json — V5 recent-trade and legacy asset/order history contracts have no authored bound mapping; raw since/until pass through"
    },
    %{
      venue: :deribit,
      methods: [
        :fetch_closed_orders,
        :fetch_deposits,
        :fetch_funding_rate_history,
        :fetch_my_trades,
        :fetch_open_orders,
        :fetch_transfers,
        :fetch_withdrawals
      ],
      raw_keys: ["until"],
      contract:
        "priv/authority/deribit/manifest.json — private order/account histories and public funding history have no authored upper-bound mapping; raw until passes through"
    },
    %{
      venue: :deribit,
      methods: [:fetch_my_liquidations, :fetch_order_trades],
      raw_keys: ["since", "until"],
      contract:
        "priv/authority/deribit/manifest.json — private settlement/user-trade contracts have no authored bound mapping; raw since/until pass through"
    },
    %{
      venue: :derive,
      methods: [
        :fetch_canceled_orders,
        :fetch_closed_orders,
        :fetch_deposits,
        :fetch_funding_history,
        :fetch_funding_rate_history,
        :fetch_my_trades,
        :fetch_open_orders,
        :fetch_order_trades,
        :fetch_orders,
        :fetch_withdrawals
      ],
      raw_keys: ["since", "until"],
      contract:
        "priv/authority/derive/manifest.json — JSON-RPC order/trade/funding/ERC20 history contracts have no authored bound mapping; raw since/until pass through"
    },
    %{
      venue: :hyperliquid,
      methods: [
        :fetch_canceled_and_closed_orders,
        :fetch_canceled_orders,
        :fetch_closed_orders,
        :fetch_deposits,
        :fetch_funding_history,
        :fetch_ledger,
        :fetch_open_orders,
        :fetch_orders,
        :fetch_withdrawals
      ],
      raw_keys: ["since", "until"],
      contract:
        "priv/authority/hyperliquid/manifest.json — POST /info order/funding/ledger history request types have no authored bound mapping; raw since/until pass through"
    },
    %{
      venue: :hyperliquid,
      methods: [:fetch_my_trades],
      raw_keys: ["until"],
      contract:
        "priv/authority/hyperliquid/manifest.json — POST /info userFillsByTime accepts startTime but has no authored upper-bound mapping; raw until passes through"
    },
    %{
      venue: :lighter,
      methods: [
        :fetch_closed_orders,
        :fetch_deposits,
        :fetch_my_liquidations,
        :fetch_my_trades,
        :fetch_open_orders,
        :fetch_transfers,
        :fetch_withdrawals
      ],
      raw_keys: ["since", "until"],
      contract:
        "priv/authority/lighter/manifest.json — account/order/trade/transfer history contracts have no authored bound mapping; raw since/until pass through"
    },
    %{
      venue: :lighter,
      methods: [:fetch_ohlcv],
      raw_keys: ["until"],
      contract:
        "priv/authority/lighter/manifest.json — candle history accepts start_timestamp but has no authored upper-bound mapping; raw until passes through"
    },
    %{
      venue: :okx,
      methods: [
        :fetch_borrow_interest,
        :fetch_borrow_rate_history,
        :fetch_canceled_orders,
        :fetch_closed_orders,
        :fetch_convert_trade_history,
        :fetch_funding_history,
        :fetch_funding_rate_history,
        :fetch_ledger,
        :fetch_long_short_ratio_history,
        :fetch_margin_adjustment_history,
        :fetch_open_orders,
        :fetch_order_trades,
        :fetch_trades,
        :fetch_transfers
      ],
      raw_keys: ["since", "until"],
      contract:
        "priv/authority/okx/manifest.json — V5 market/trade/account/funding history contracts have no authored bound mapping; raw since/until pass through"
    },
    %{
      venue: :okx,
      methods: [:fetch_my_trades],
      raw_keys: ["until"],
      contract:
        "priv/authority/okx/manifest.json — GET /api/v5/trade/fills maps begin but has no authored upper-bound mapping; raw until passes through"
    }
  ]

  test "every supported unified time-window read is probed or explicitly tracked" do
    expected = supported_time_window_reads()
    probe_pairs = Enum.map(TimeWindowProbeMatrix.probes(), &{&1.venue, &1.method})

    exclusion_pairs =
      for exclusion <- TimeWindowProbeMatrix.exclusions(), method <- exclusion.methods, do: {exclusion.venue, method}

    assert length(probe_pairs) == MapSet.size(MapSet.new(probe_pairs)), "duplicate live time-window probe"
    assert length(exclusion_pairs) == MapSet.size(MapSet.new(exclusion_pairs)), "duplicate time-window exclusion"
    assert MapSet.disjoint?(MapSet.new(probe_pairs), MapSet.new(exclusion_pairs))

    assert MapSet.new(probe_pairs) == @pinned_live_probes,
           "live time-window probe set drifted; explicitly re-pin additions or demotions"

    assert expected == MapSet.new(probe_pairs ++ exclusion_pairs),
           "time-window inventory drift: #{inspect(MapSet.symmetric_difference(expected, MapSet.new(probe_pairs ++ exclusion_pairs)))}"
  end

  test "every exclusion names why it cannot be probed and where it is tracked" do
    for %{venue: venue, methods: methods, reason: reason, tracking: tracking} <- TimeWindowProbeMatrix.exclusions() do
      assert methods != [], "#{venue} has an empty exclusion group"
      assert String.trim(reason) != "", "#{venue} exclusion has no reason"
      assert tracking =~ ~r/task(?:s)? \d+/i, "#{venue} exclusion has no task tracking reference"
    end
  end

  test "every time-window read translates or has an exact provider-contract allowlist entry" do
    allowlist = raw_window_allowlist()

    actual =
      supported_time_window_reads()
      |> Enum.map(fn {venue, method} ->
        shaped = shape_window(venue, method)
        raw_keys = Enum.filter(["since", "until"], &Map.has_key?(shaped, &1))
        {{venue, method}, raw_keys}
      end)
      |> Enum.reject(fn {_pair, raw_keys} -> raw_keys == [] end)
      |> Map.new()

    assert actual == Map.new(allowlist, fn {pair, %{raw_keys: raw_keys}} -> {pair, raw_keys} end),
           "raw time-window request-shape allowlist drift: #{inspect(raw_window_drift(actual, allowlist))}"
  end

  test "Binance spot order histories map bounds and open orders drops unsupported bounds" do
    methods = [
      :fetch_closed_orders,
      :fetch_canceled_orders,
      :fetch_canceled_and_closed_orders,
      :fetch_order_trades
    ]

    for method <- methods do
      shaped = shape_window(:binance, method)

      assert shaped["startTime"] == @since_ms
      assert shaped["endTime"] == @until_ms
      refute Map.has_key?(shaped, "since")
      refute Map.has_key?(shaped, "until")
    end

    open_orders = shape_window(:binance, :fetch_open_orders)
    refute Map.has_key?(open_orders, "since")
    refute Map.has_key?(open_orders, "until")
    refute Map.has_key?(open_orders, "startTime")
    refute Map.has_key?(open_orders, "endTime")
  end

  test "Binance USD-M order histories map bounds and open orders drops unsupported bounds" do
    methods = [
      :fetch_closed_orders,
      :fetch_canceled_orders,
      :fetch_canceled_and_closed_orders,
      :fetch_order_trades
    ]

    for method <- methods do
      shaped = shape_window(:binanceusdm, method)

      assert shaped["startTime"] == @since_ms
      assert shaped["endTime"] == @until_ms
      refute Map.has_key?(shaped, "since")
      refute Map.has_key?(shaped, "until")
    end

    open_orders = shape_window(:binanceusdm, :fetch_open_orders)
    refute Map.has_key?(open_orders, "since")
    refute Map.has_key?(open_orders, "until")
    refute Map.has_key?(open_orders, "startTime")
    refute Map.has_key?(open_orders, "endTime")
  end

  test "Binance COIN-M order histories map bounds and open orders drops unsupported bounds" do
    methods = [:fetch_orders, :fetch_my_trades, :fetch_closed_orders, :fetch_canceled_orders]

    for method <- methods do
      shaped = shape_window(:binancecoinm, method)

      assert shaped["startTime"] == @since_ms
      assert shaped["endTime"] == @until_ms
      refute Map.has_key?(shaped, "since")
      refute Map.has_key?(shaped, "until")
    end

    open_orders = shape_window(:binancecoinm, :fetch_open_orders)
    refute Map.has_key?(open_orders, "since")
    refute Map.has_key?(open_orders, "until")
    refute Map.has_key?(open_orders, "startTime")
    refute Map.has_key?(open_orders, "endTime")
  end

  test "emulated futures order histories carry until through to the HTTP request" do
    venues = [
      {:binancecoinm, "BTC/USD:BTC", ["/dapi/v1/allOrders"], [:fetch_closed_orders, :fetch_canceled_orders]},
      {:binanceusdm, "BTC/USDT:USDT", ["/fapi/v1/allAlgoOrders", "/fapi/v1/allOrders"],
       [:fetch_closed_orders, :fetch_canceled_orders, :fetch_canceled_and_closed_orders]}
    ]

    for {venue, symbol, expected_paths, methods} <- venues,
        method <- methods do
      observed = emulated_order_history_requests(venue, method, symbol)

      assert Enum.map(observed, & &1.path) == expected_paths

      assert Enum.all?(observed, fn request ->
               request.query["endTime"] == Integer.to_string(@until_ms)
             end),
             "#{venue}.#{method} did not put endTime on every delegated HTTP request: " <>
               inspect(observed)

      assert Enum.all?(observed, fn request ->
               not Map.has_key?(request.query, "until")
             end)
    end
  end

  test "OKX compensates exclusive pagination cursors for inclusive unified bounds" do
    ohlcv = shape_window(:okx, :fetch_ohlcv)
    deposits = shape_window(:okx, :fetch_deposits)
    withdrawals = shape_window(:okx, :fetch_withdrawals)
    history = shape_window(:okx, :fetch_positions_history)

    assert ohlcv["before"] == @since_ms - @exclusive_cursor_offset_ms
    assert ohlcv["after"] == @until_ms + @exclusive_cursor_offset_ms
    refute Map.has_key?(ohlcv, "since")
    refute Map.has_key?(ohlcv, "until")

    assert deposits["before"] == @since_ms - @exclusive_cursor_offset_ms
    assert deposits["after"] == @until_ms + @exclusive_cursor_offset_ms
    refute Map.has_key?(deposits, "since")
    refute Map.has_key?(deposits, "until")

    assert withdrawals["before"] == @since_ms - @exclusive_cursor_offset_ms
    assert withdrawals["after"] == @until_ms + @exclusive_cursor_offset_ms
    refute Map.has_key?(withdrawals, "since")
    refute Map.has_key?(withdrawals, "until")

    assert history["after"] == @until_ms + @exclusive_cursor_offset_ms
    refute Map.has_key?(history, "before")
    refute Map.has_key?(history, "since")
    refute Map.has_key?(history, "until")
  end

  test "every exclusive-cursor request-shape site compensates inclusive unified bounds" do
    assert exclusive_cursor_venues() == MapSet.new(Registry.exchanges()),
           "confront this venue's pagination contract before adding runtime support: " <>
             inspect(MapSet.difference(MapSet.new(Registry.exchanges()), exclusive_cursor_venues()))

    sites = exclusive_cursor_sites()

    assert sites != [],
           "exclusive-cursor sweep found no sites; OKX still documents exclusive before/after pagination"

    uncompensated =
      Enum.reject(sites, fn %{actual: actual, expected: expected} -> actual == expected end)

    assert uncompensated == [],
           "exclusive cursor missing compensation: #{inspect(uncompensated)}"
  end

  test "exclusive-cursor sweep includes translations that drop unified bounds without emitting native cursors" do
    dropped = %{"ccy" => "USDT"}

    assert exclusive_cursor_site?(:okx, :fetch_withdrawals, dropped, "before", "since")
    assert exclusive_cursor_site?(:okx, :fetch_withdrawals, dropped, "after", "until")

    refute exclusive_cursor_site?(
             :okx,
             :fetch_withdrawals,
             Map.put(dropped, "since", @since_ms),
             "before",
             "since"
           )

    refute exclusive_cursor_site?(:okx, :fetch_positions_history, %{"after" => @until_ms}, "before", "since")
    refute exclusive_cursor_site?(:okx, :fetch_my_trades, %{"begin" => @since_ms}, "before", "since")
  end

  test "authored exclusive-cursor remaps carry the compensating transform" do
    uncompensated = uncompensated_exclusive_spec_remaps()

    assert uncompensated == [],
           "exclusive-cursor spec remap missing compensation: #{inspect(uncompensated)}"
  end

  test "request-shape Elixir does not bare-rename unified bounds onto exclusive cursors" do
    assert uncompensated_exclusive_renames() == [],
           "bare rename onto an exclusive cursor copies the unified bound; compensate instead: " <>
             inspect(uncompensated_exclusive_renames())
  end

  defp exclusive_cursor_venues do
    MapSet.new(Map.keys(@exclusive_cursors) ++ @inclusive_bound_venues)
  end

  defp exclusive_natives do
    @exclusive_cursors
    |> Map.values()
    |> Enum.flat_map(&Map.keys/1)
    |> MapSet.new()
  end

  # Inclusive natives that are not exclusive before/after (OKX begin/end).
  # A consumed unified bound that lands here is a different contract, not a miss.
  @inclusive_window_natives %{"since" => "begin", "until" => "end"}

  # Documented local-only filters: the unified bound is consumed on purpose
  # and is not an exclusive timestamp cursor (C-T434d / C-T635a).
  @exclusive_cursor_local_filters MapSet.new([
                                    {:okx, :fetch_positions_history, "since"}
                                  ])

  defp exclusive_cursor_sites do
    for {venue, method} <- supported_time_window_reads(),
        cursors = Map.get(@exclusive_cursors, Atom.to_string(venue), %{}),
        {native, %{unified: unified, offset: offset}} <- cursors,
        shaped = shape_window(venue, method),
        is_map(shaped),
        exclusive_cursor_site?(venue, method, shaped, native, unified) do
      bound = if unified == "since", do: @since_ms, else: @until_ms

      %{
        venue: venue,
        method: method,
        native: native,
        actual: shaped[native],
        expected: bound + offset
      }
    end
  end

  # Requiring the native cursor to already be present skipped the hole this
  # task closed: a translation that drops since/until without emitting
  # before/after passed both the raw-allowlist and exclusive-cursor sweeps.
  defp exclusive_cursor_site?(venue, method, shaped, native, unified) do
    cond do
      Map.has_key?(shaped, native) ->
        true

      Map.has_key?(shaped, unified) ->
        false

      exclusive_cursor_local_filter?(venue, method, unified) ->
        false

      inclusive_window_native?(shaped, unified) ->
        false

      true ->
        true
    end
  end

  defp exclusive_cursor_local_filter?(venue, method, unified) do
    MapSet.member?(@exclusive_cursor_local_filters, {venue, method, unified})
  end

  defp inclusive_window_native?(shaped, unified) do
    case Map.get(@inclusive_window_natives, unified) do
      nil -> false
      inclusive -> Map.has_key?(shaped, inclusive)
    end
  end

  defp uncompensated_exclusive_spec_remaps do
    for venue <- Registry.exchanges(),
        cursors = Map.get(@exclusive_cursors, venue, %{}),
        {js_name, entries} <- request_shape_methods(venue),
        {native, %{transform: expected_transform}} <- cursors,
        match?(%{"source" => source} when source in ["since", "until"], entries[native]),
        entries[native]["transform"] != expected_transform do
      %{
        venue: venue,
        method: js_name,
        native: native,
        source: entries[native]["source"],
        transform: entries[native]["transform"],
        expected_transform: expected_transform
      }
    end
  end

  defp request_shape_methods(venue) do
    shape = Exchange.new!(venue).request_param_shape

    Enum.flat_map(shape, fn
      {"endpoint_overrides", overrides} ->
        for {js_name, paths} <- overrides,
            {_path, entries} when is_map(entries) <- paths,
            do: {js_name, entries}

      {js_name, entries} when is_map(entries) ->
        [{js_name, entries}]

      _entry ->
        []
    end)
  end

  defp uncompensated_exclusive_renames do
    natives = exclusive_natives()

    for path <- request_shape_paths(),
        ast = path |> File.read!() |> Code.string_to_quoted!(file: path),
        site <- exclusive_rename_sites(ast, path, natives) do
      site
    end
  end

  defp request_shape_paths do
    ["lib/bourse/unified/request_shape.ex" | Path.wildcard("lib/bourse/unified/request_shape/*.ex")]
  end

  defp exclusive_rename_sites(ast, path, natives) do
    {_ast, sites} =
      Macro.prewalk(ast, [], fn
        {:rename, meta, args} = node, acc ->
          case exclusive_rename_args(args, natives) do
            {source, target} ->
              {node, [%{path: path, line: meta[:line], source: source, target: target} | acc]}

            nil ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(sites)
  end

  defp exclusive_rename_args([source, target], natives)
       when is_binary(source) and is_binary(target) and source in ["since", "until"] do
    if MapSet.member?(natives, target), do: {source, target}
  end

  defp exclusive_rename_args([_params, source, target], natives)
       when is_binary(source) and is_binary(target) and source in ["since", "until"] do
    if MapSet.member?(natives, target), do: {source, target}
  end

  defp exclusive_rename_args(_args, _natives), do: nil

  defp supported_time_window_reads do
    window_methods =
      for {method, js_name, required, _description} <- Unified.method_defs(),
          opts = Descriptor.build_api_opts(js_name, required)[:opts] || [],
          Keyword.has_key?(opts, :since),
          into: MapSet.new(),
          do: method

    for venue <- Registry.exchanges(),
        method <- Map.keys(Registry.module_for(venue).__unified_endpoints__()),
        MapSet.member?(window_methods, method),
        into: MapSet.new(),
        do: {String.to_atom(venue), method}
  end

  defp raw_window_allowlist do
    pairs =
      for %{venue: venue, methods: methods, raw_keys: raw_keys, contract: contract} <- @raw_window_allowlist,
          method <- methods do
        assert contract =~ "priv/authority/#{venue}/manifest.json",
               "#{venue}.#{method} raw-window carve does not name its provider authority manifest"

        {{venue, method}, %{raw_keys: raw_keys, contract: contract}}
      end

    assert length(pairs) == map_size(Map.new(pairs)), "duplicate raw time-window allowlist pair"
    Map.new(pairs)
  end

  defp raw_window_drift(actual, allowlist) do
    expected = Map.new(allowlist, fn {pair, %{raw_keys: raw_keys}} -> {pair, raw_keys} end)

    %{
      unexpected: Map.drop(actual, Map.keys(expected)),
      stale: Map.drop(expected, Map.keys(actual)),
      changed: for({pair, keys} <- actual, expected[pair] not in [nil, keys], do: {pair, expected[pair], keys})
    }
  end

  defp emulated_order_history_requests(venue, method, symbol) do
    {:ok, requests} = RequestCollector.start_link()
    stub = make_ref()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, [])
    end)

    exchange =
      Exchange.new!(Atom.to_string(venue),
        api_key: "key",
        secret: "secret",
        sandbox: true
      )

    assert {:ok, []} =
             apply(Bourse, method, [
               exchange,
               [
                 symbol: symbol,
                 until: @until_ms,
                 plug: {Req.Test, stub},
                 timestamp_ms_override: @since_ms
               ]
             ])

    requests
    |> RequestCollector.requests()
    |> Enum.map(fn %{conn: conn} ->
      %{
        path: conn.request_path,
        query:
          conn
          |> RequestCollector.query()
          |> Map.drop(["recvWindow", "signature", "timestamp"])
      }
    end)
    |> Enum.sort_by(& &1.path)
  end

  defp shape_window(venue, method) do
    exchange = window_exchange(venue)
    js_name = Unified.js_name_for!(method)

    params =
      method
      |> Unified.required_params_for()
      |> Map.new(fn param -> {Atom.to_string(param), sample_param(param, venue)} end)
      |> Map.merge(%{
        "l1_address" => "0xabc",
        "limit" => @request_limit,
        "market_id" => 0,
        "since" => @since_ms,
        "until" => @until_ms
      })

    shape_opts = [
      endpoint_path: endpoint_path(venue, method),
      timestamp_ms_override: @since_ms
    ]

    params
    |> RequestShape.apply_premarket(exchange, js_name)
    |> Unified.maybe_denormalize_symbol(exchange)
    |> Unified.maybe_translate_timeframe(exchange)
    |> Unified.maybe_merge_request_defaults(exchange, js_name)
    |> RequestShape.apply(exchange, js_name, shape_opts)
  end

  defp window_exchange(venue) do
    Exchange.new!(Atom.to_string(venue),
      api_key: "key",
      secret: String.duplicate("0", 80),
      password: "password",
      uid: "1",
      options: %{"subaccount_id" => 1}
    )
  end

  defp sample_param(:code, _venue), do: "USDT"
  defp sample_param(:id, _venue), do: "order-1"
  defp sample_param(:timeframe, _venue), do: "1h"
  defp sample_param(:symbol, :alpaca), do: "GLD"
  defp sample_param(:symbol, :binance), do: "BTC/USDT"
  defp sample_param(:symbol, :binancecoinm), do: "BTC/USD:BTC"
  defp sample_param(:symbol, :binanceusdm), do: "BTC/USDT:USDT"
  defp sample_param(:symbol, :bybit), do: "BTC/USDT:USDT"
  defp sample_param(:symbol, :coinbaseexchange), do: "ETH/USD"
  defp sample_param(:symbol, :deribit), do: "BTC/USD:BTC"
  defp sample_param(:symbol, :derive), do: "ETH/USD:USDC"
  defp sample_param(:symbol, :hyperliquid), do: "BTC/USDC:USDC"
  defp sample_param(:symbol, :lighter), do: "ETH/USDC:USDC"
  defp sample_param(:symbol, :okx), do: "BTC/USDT"

  defp endpoint_path(:alpaca, :fetch_ohlcv), do: "v2/stocks/{symbol}/bars"
  defp endpoint_path(:alpaca, :fetch_trades), do: "v2/stocks/{symbol}/trades"
  defp endpoint_path(_venue, _method), do: nil
end

defmodule Bourse.TimeWindowIntegrationTest do
  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper, only: [build_exchange: 2, require_credentials!: 2]

  alias Bourse.Test.TimeWindowProbeMatrix

  @moduletag :integration
  @moduletag :network
  @moduletag :time_window_live

  @discovery_limit 100
  @minimum_distinct_timestamps 4
  @boundary_pad_ms 1

  for probe <- TimeWindowProbeMatrix.probes() do
    @probe probe

    test "#{probe.venue} #{probe.method} honors since and until in returned rows" do
      assert_honored_window(@probe)
    end
  end

  defp assert_honored_window(probe) do
    exchange = build_probe_exchange(probe)
    discovery = probe_call!(probe, exchange, limit: @discovery_limit)
    discovered_timestamps = timestamps!(probe, discovery)

    assert length(discovered_timestamps) >= @minimum_distinct_timestamps,
           "#{probe.venue}.#{probe.method} needs #{@minimum_distinct_timestamps} distinct live timestamps; " <>
             "got #{inspect(discovered_timestamps)}"

    since_boundary = Enum.at(discovered_timestamps, div(length(discovered_timestamps), 3))
    until_boundary = Enum.at(discovered_timestamps, div(length(discovered_timestamps) * 2, 3))
    requested_since = max(since_boundary - @boundary_pad_ms, 0)
    requested_until = until_boundary + @boundary_pad_ms

    since_rows = probe_call!(probe, exchange, since: requested_since, limit: @discovery_limit)
    since_timestamps = timestamps!(probe, since_rows)
    first_timestamp = List.first(since_timestamps)

    assert first_timestamp >= requested_since

    assert first_timestamp <= since_boundary + probe.tolerance_ms,
           "#{probe.venue}.#{probe.method} returned the latest page instead of the since boundary: " <>
             "requested #{requested_since}, first #{first_timestamp}"

    until_rows = probe_call!(probe, exchange, until: requested_until, limit: @discovery_limit)
    until_timestamps = timestamps!(probe, until_rows)
    last_timestamp = List.last(until_timestamps)

    assert last_timestamp <= requested_until

    assert last_timestamp >= until_boundary - probe.tolerance_ms,
           "#{probe.venue}.#{probe.method} did not stop at the until boundary: " <>
             "requested #{requested_until}, last #{last_timestamp}"
  end

  defp build_probe_exchange(%{venue: venue, credentials: true, exchange_opts: exchange_opts}) do
    credentials = require_credentials!(venue, credential_options(venue))
    build_exchange(venue, Keyword.put(exchange_opts, :credentials, credentials))
  end

  defp build_probe_exchange(%{venue: venue, exchange_opts: exchange_opts}) do
    build_exchange(venue, exchange_opts)
  end

  defp credential_options(:alpaca), do: [url: "https://app.alpaca.markets/signup"]
  defp credential_options(:binance), do: [url: "https://testnet.binance.vision"]
  defp credential_options(:binanceusdm), do: [url: "https://demo.binance.com/en/my/settings/api-management"]
  defp credential_options(_venue), do: []

  defp probe_call!(probe, exchange, window_opts) do
    opts = Keyword.merge(probe.opts, window_opts)

    case apply(Bourse, probe.method, [exchange | probe.args] ++ [opts]) do
      {:ok, [_ | _] = rows} -> rows
      {:ok, []} -> flunk("#{probe.venue}.#{probe.method} returned no rows for #{inspect(window_opts)}")
      {:error, error} -> flunk("#{probe.venue}.#{probe.method} failed for #{inspect(window_opts)}: #{inspect(error)}")
    end
  end

  defp timestamps!(probe, rows) do
    timestamps =
      rows
      |> Enum.map(fn
        [timestamp | _values] when is_integer(timestamp) -> timestamp
        %{timestamp: timestamp} when is_integer(timestamp) -> timestamp
        row -> flunk("#{probe.venue}.#{probe.method} returned a row without a timestamp: #{inspect(row)}")
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert timestamps != [], "#{probe.venue}.#{probe.method} returned no timestamped rows"
    timestamps
  end
end
