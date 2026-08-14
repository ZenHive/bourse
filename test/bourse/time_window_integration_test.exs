defmodule Bourse.Test.TimeWindowProbeMatrix do
  @moduledoc """
  Live time-window probes and explicit exclusions for supported unified reads.

  A probe must assert returned timestamps at both requested boundaries. A
  successful response without that timestamp assertion is not coverage.
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
        :fetch_trades,
        :fetch_transfers,
        :fetch_withdrawals
      ],
      reason: "the read-only testnet key and demo state do not guarantee populated history boundaries",
      tracking: "docs/prod-verification-ledger.md — tasks 526 and 567"
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
        :fetch_trades,
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
        :fetch_trades,
        :fetch_transfers,
        :fetch_withdrawals
      ],
      reason: "international demo histories do not guarantee populated rows at both boundaries",
      tracking: "docs/prod-verification-ledger.md — tasks 526, 567, and 568"
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

  alias Bourse.Test.TimeWindowProbeMatrix
  alias Bourse.Unified
  alias Bourse.Unified.Descriptor

  test "every supported unified time-window read is probed or explicitly tracked" do
    expected = supported_time_window_reads()
    probe_pairs = Enum.map(TimeWindowProbeMatrix.probes(), &{&1.venue, &1.method})

    exclusion_pairs =
      for exclusion <- TimeWindowProbeMatrix.exclusions(), method <- exclusion.methods, do: {exclusion.venue, method}

    assert length(probe_pairs) == MapSet.size(MapSet.new(probe_pairs)), "duplicate live time-window probe"
    assert length(exclusion_pairs) == MapSet.size(MapSet.new(exclusion_pairs)), "duplicate time-window exclusion"
    assert MapSet.disjoint?(MapSet.new(probe_pairs), MapSet.new(exclusion_pairs))

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

  defp supported_time_window_reads do
    window_methods =
      for {method, js_name, required, _description} <- Unified.method_defs(),
          opts = Descriptor.build_api_opts(js_name, required)[:opts] || [],
          Keyword.has_key?(opts, :since),
          into: MapSet.new(),
          do: method

    for venue <- Bourse.Registry.exchanges(),
        method <- Map.keys(Bourse.Registry.module_for(venue).__unified_endpoints__()),
        MapSet.member?(window_methods, method),
        into: MapSet.new(),
        do: {String.to_atom(venue), method}
  end
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
