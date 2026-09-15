defmodule Bourse.Hyperliquid.EmulatedOrderStatusLimitTest do
  # Live pin for the emulated order-status reads hyperliquid delegates to
  # fetchOrders (fetchClosedOrders / fetchCanceledOrders /
  # fetchCanceledAndClosedOrders — the only `_delegate` entries in the authored
  # surface). The delegate's parse layer applies `limit` itself
  # (Bourse.Unified.ReadParse.maybe_take_limit/3), so forwarding `limit` to it
  # truncated the raw order history BEFORE the emulated status filter ran: the
  # wallet's newest rows are open/canceled events, so `limit: 10` answered with
  # zero closed orders while 137 existed. `since`/`limit` are now declared
  # consumed for those handlers and applied once, locally, after the filter.
  #
  # Semantic authority: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint
  @moduledoc false

  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper, only: [build_exchange: 2, require_credentials!: 1]

  alias Bourse.Test.LiveGateIsolation

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_hyperliquid

  @limit 10

  setup do
    LiveGateIsolation.isolate!("hyperliquid")
    :ok
  end

  test "limit selects N status-matching orders instead of truncating before the status filter" do
    exchange = build_exchange(:hyperliquid, sandbox: true, credentials: require_credentials!(:hyperliquid))

    assert {:ok, all_closed} = Bourse.fetch_closed_orders(exchange)
    assert is_list(all_closed)

    if length(all_closed) <= @limit do
      flunk("""
      hyperliquid testnet wallet holds #{length(all_closed)} closed orders, which does not
      exceed the probed limit of #{@limit} — the truncation this test pins cannot be observed.
      Place and fill orders on the wallet behind HYPERLIQUID_TESTNET_API_KEY, then re-run.
      """)
    end

    assert {:ok, limited} = Bourse.fetch_closed_orders(exchange, limit: @limit)

    assert length(limited) == @limit,
           "limit must yield #{@limit} closed orders, got #{length(limited)} of #{length(all_closed)} available"

    assert Enum.all?(limited, &(&1.status == "closed"))

    # The delegate returns history ascending by timestamp and no `since` is set,
    # so the limit takes the newest rows.
    newest = all_closed |> Enum.map(& &1.timestamp) |> Enum.sort() |> Enum.take(-@limit)
    assert limited |> Enum.map(& &1.timestamp) |> Enum.sort() == newest
  end

  test "since anchors the limit to the oldest matching orders" do
    exchange = build_exchange(:hyperliquid, sandbox: true, credentials: require_credentials!(:hyperliquid))

    assert {:ok, all_closed} = Bourse.fetch_closed_orders(exchange)
    timestamps = all_closed |> Enum.map(& &1.timestamp) |> Enum.sort()

    if length(timestamps) <= @limit do
      flunk("""
      hyperliquid testnet wallet holds #{length(timestamps)} closed orders — too few to
      anchor a `since` window. Populate the wallet behind HYPERLIQUID_TESTNET_API_KEY.
      """)
    end

    since = Enum.at(timestamps, div(length(timestamps), 2))

    assert {:ok, windowed} = Bourse.fetch_closed_orders(exchange, since: since)
    assert windowed != []
    assert Enum.all?(windowed, &(&1.timestamp >= since))

    assert {:ok, windowed_limited} = Bourse.fetch_closed_orders(exchange, since: since, limit: 5)
    assert length(windowed_limited) == 5

    oldest_in_window =
      windowed |> Enum.map(& &1.timestamp) |> Enum.sort() |> Enum.take(5)

    assert windowed_limited |> Enum.map(& &1.timestamp) |> Enum.sort() == oldest_in_window
  end

  test "canceled and merged canceled-and-closed reads honour limit the same way" do
    exchange = build_exchange(:hyperliquid, sandbox: true, credentials: require_credentials!(:hyperliquid))

    assert {:ok, canceled} = Bourse.fetch_canceled_orders(exchange)

    if length(canceled) <= 5 do
      flunk("""
      hyperliquid testnet wallet holds #{length(canceled)} canceled orders — too few to prove
      the limit is applied after the status filter. Populate the wallet behind
      HYPERLIQUID_TESTNET_API_KEY.
      """)
    end

    assert {:ok, canceled_limited} = Bourse.fetch_canceled_orders(exchange, limit: 5)
    assert length(canceled_limited) == 5
    assert Enum.all?(canceled_limited, &(&1.status == "canceled"))

    # The merged read deliberately carries rejected orders alongside canceled and
    # closed ones (Emulation.handle_fetch_canceled_and_closed_orders/4).
    assert {:ok, merged} = Bourse.fetch_canceled_and_closed_orders(exchange, limit: 7)
    assert length(merged) == 7
    assert Enum.all?(merged, &(&1.status in ["closed", "canceled", "rejected"]))
  end
end
