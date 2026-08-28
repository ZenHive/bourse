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
      tracking: "unreachable without populated account state — no ledger entry; the row is the record"
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
      tracking: "unreachable without populated account state — no ledger entry; the row is the record"
    },
    %{
      venue: :binancecoinm,
      methods: [
        :fetch_canceled_orders,
        :fetch_closed_orders,
        :fetch_funding_history,
        :fetch_funding_rate_history,
        :fetch_ledger,
        :fetch_margin_adjustment_history,
        :fetch_my_trades,
        :fetch_open_orders,
        :fetch_orders
      ],
      reason:
        "the COIN-M demo wallet does not guarantee populated account-history boundaries; " <>
          "the restored reads stay labelled raw until task 550 completes their mappings",
      tracking: "unreachable without populated account state — no ledger entry; the row is the record"
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
      tracking: "unreachable without populated account state — no ledger entry; the row is the record"
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
      tracking: "unreachable without populated account state — no ledger entry; the row is the record"
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

defmodule Bourse.TimeWindowIntegrationTest do
  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper, only: [build_exchange: 2, require_credentials!: 2]

  alias Bourse.Test.LiveLane
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

    case probe_rows(probe, exchange, limit: @discovery_limit) do
      {:ok, []} ->
        accept_unexercised!(probe, :empty_collection, empty_rows_message(probe, limit: @discovery_limit))

      {:ok, discovery} ->
        assert_window_from_discovery(probe, exchange, discovery)

      {:error, error} ->
        flunk("#{probe.venue}.#{probe.method} failed for [limit: #{@discovery_limit}]: #{inspect(error)}")
    end
  end

  defp assert_window_from_discovery(probe, exchange, discovery) do
    discovered_timestamps = timestamps!(probe, discovery)

    if length(discovered_timestamps) >= @minimum_distinct_timestamps do
      assert_window_bounds(probe, exchange, discovered_timestamps)
    else
      accept_unexercised!(
        probe,
        :sparse_history,
        "#{probe.venue}.#{probe.method} needs #{@minimum_distinct_timestamps} distinct live timestamps; " <>
          "got #{inspect(discovered_timestamps)}"
      )
    end
  end

  defp assert_window_bounds(probe, exchange, discovered_timestamps) do
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

  defp accept_unexercised!(probe, observed, message) do
    LiveLane.accept_or_flunk!(probe.venue, probe.method, observed, message, "time_window")
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
    case probe_rows(probe, exchange, window_opts) do
      {:ok, [_ | _] = rows} -> rows
      {:ok, []} -> flunk(empty_rows_message(probe, window_opts))
      {:error, error} -> flunk("#{probe.venue}.#{probe.method} failed for #{inspect(window_opts)}: #{inspect(error)}")
    end
  end

  defp probe_rows(probe, exchange, window_opts) do
    opts = Keyword.merge(probe.opts, window_opts)
    apply(Bourse, probe.method, [exchange | probe.args] ++ [opts])
  end

  defp empty_rows_message(probe, window_opts) do
    "#{probe.venue}.#{probe.method} returned no rows for #{inspect(window_opts)}"
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
