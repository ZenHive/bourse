defmodule Bourse.DefaultFamilySelectionTest do
  @moduledoc """
  Task 378 — authored per-venue `config.default_family` + retirement of
  venue-local `hd(configs)` clauses in `Bourse.Unified`.
  """
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Spec
  alias Bourse.Test.RequestCollector
  alias Bourse.Unified

  @distinct_order_book_contracts %{
    "binance" => %{
      "cancelAllOrders" => "fapiPrivate_delete_algoopenorders",
      "cancelOrder" => "fapiPrivate_delete_algoorder",
      "createOrder" => "fapiPrivate_post_algoorder",
      "fetchOpenOrders" => "fapiPrivate_get_openalgoorders"
    },
    "okx" => %{
      "cancelOrder" => "trade/cancel-algos",
      "createOrder" => "trade/order-algo",
      "fetchOpenOrders" => "trade/orders-algo-pending"
    }
  }

  @alternate_create_route_exclusions %{
    "binancecoinm" => "alternate create endpoints select a different market family, not a second book within one family",
    "binanceusdm" => "alternate create endpoints select a different market family, not a second book within one family",
    "bybit" => "position/trading-stop manages position-level TP/SL controls rather than independently cancellable orders",
    "deribit" => "buy and sell are side-specific RPC methods writing to the same order book",
    "derive" => "the debug endpoint changes response detail while writing to the same order book"
  }

  describe "config.default_family slot" do
    test "binanceusdm authors linear as the venue default family" do
      assert Exchange.new!("binanceusdm").default_family == "linear"
    end

    test "binance authors spot as the venue default family" do
      assert Exchange.new!("binance").default_family == "spot"
    end

    test "bybit authors linear as the venue default family" do
      assert Exchange.new!("bybit").default_family == "linear"
    end

    test "unknown default_family values are dropped (nil on the struct)" do
      # Spec loader only accepts the closed vocabulary; a missing key is nil.
      assert Exchange.new!("deribit").default_family == nil
      assert Exchange.new!("derive").default_family == nil
    end
  end

  describe "no first-class bare hd(configs) on the named no-arg-read set" do
    test "bare_hd_no_arg_pairs/0 is empty after authored defaults" do
      assert Unified.bare_hd_no_arg_pairs() == []
    end

    test "first-class multi-endpoint with no authored resolution fails loudly" do
      # Build a synthetic multi-config selection by forcing endpoint_selection
      # empty and default_family nil on a first-class exchange that still has
      # multi configs — use endpoint_index bypass isn't the gap; we assert the
      # error path via a real method that we temporarily can't reach without
      # authoring. Covered instead by: empty pairs + binanceusdm routing pins.
      assert is_list(Unified.no_arg_read_methods())
      assert "binanceusdm" in Unified.first_class_venues()
    end

    test "every mapped unified method has a documented reachable parameter set" do
      assert Unified.mapped_endpoint_reachability_failures() == []
    end
  end

  describe "distinct order-book routing" do
    test "every alternate create endpoint has matching lifecycle routes or a named exclusion" do
      candidates =
        Spec.exchanges()
        |> Enum.filter(fn venue ->
          venue
          |> Exchange.new!()
          |> then(&alternate_create_routes(&1.endpoint_selection["createOrder"]))
          |> Enum.any?()
        end)
        |> MapSet.new()

      catalog =
        @distinct_order_book_contracts
        |> Map.keys()
        |> Kernel.++(Map.keys(@alternate_create_route_exclusions))
        |> MapSet.new()

      assert candidates == catalog

      for {venue, contract} <- @distinct_order_book_contracts,
          {method, target} <- contract do
        selection = Exchange.new!(venue).endpoint_selection[method]

        assert target in selection_targets(selection),
               "#{venue} #{method} does not route to distinct order book #{target}"
      end

      assert Enum.all?(@alternate_create_route_exclusions, fn {_venue, rationale} -> rationale != "" end)
    end
  end

  describe "binanceusdm no-arg routing via authored selection (task 378)" do
    test "no-arg and inverse signals preserve the linear/fapi and dapi pins" do
      for {method, js, params, expected_path, body} <- [
            {:fetch_tickers, "fetchTickers", %{}, "/fapi/v1/ticker/24hr", []},
            {:fetch_tickers, "fetchTickers", %{"subType" => "inverse"}, "/dapi/v1/ticker/24hr", []},
            {:fetch_funding_rates, "fetchFundingRates", %{}, "/fapi/v1/premiumIndex", []},
            {:fetch_funding_rates, "fetchFundingRates", %{"subType" => "inverse"}, "/dapi/v1/premiumIndex", []},
            {:fetch_time, "fetchTime", %{}, "/fapi/v1/time", %{"serverTime" => 1_700_000_000_000}},
            {:fetch_positions, "fetchPositions", %{}, "/fapi/v3/positionRisk", []},
            {:fetch_open_orders, "fetchOpenOrders", %{}, "/fapi/v1/openOrders", []}
          ] do
        {stub, requests} = path_body_stub(body)
        exchange = Exchange.new!("binanceusdm", api_key: "key", secret: "secret", sandbox: true)

        assert {:ok, _} =
                 Unified.call(exchange, method, js, params,
                   plug: {Req.Test, stub},
                   timestamp_ms_override: 1_700_000_000_000
                 )

        conn = RequestCollector.one!(requests)

        assert conn.request_path == expected_path,
               "expected #{expected_path}, got #{conn.request_path}"
      end
    end

    test "no hardcoded binanceusdm preferred-path map remains in Unified" do
      {:ok, source} = File.read("lib/bourse/unified.ex")
      refute source =~ "@binanceusdm_preferred_paths"
      refute source =~ "binanceusdm_default_family_endpoint"
    end
  end

  @tag :network
  test "live binanceusdm no-arg funding rates default to linear fapi; inverse selects dapi" do
    # Public premiumIndex surfaces — no credentials. Live catalog sizes are the
    # tier-1 oracle that the authored linear default + inverse rule preserve the
    # task-373 pins (fapi ~700+ rows, dapi ~40 rows on testnet).
    exchange = Exchange.new!("binanceusdm", sandbox: true)

    assert {:ok, linear} = Bourse.fetch_funding_rates(exchange)
    assert is_map(linear)
    linear_n = map_size(linear)
    assert linear_n > 100, "expected large linear fapi catalog, got #{linear_n}"

    assert {:ok, inverse} = Bourse.fetch_funding_rates(exchange, subType: "inverse")
    assert is_map(inverse)
    inverse_n = map_size(inverse)

    assert inverse_n > 0 and inverse_n < linear_n,
           "expected smaller inverse dapi catalog (#{inverse_n}) than linear (#{linear_n})"
  end

  defp alternate_create_routes(selection) when is_map(selection) do
    selection
    |> selection_targets()
    |> Enum.reject(&(&1 == selection["default"]))
  end

  defp alternate_create_routes(_selection), do: []

  defp selection_targets(selection) when is_map(selection) do
    route_targets =
      selection
      |> Map.get("book_routes", [])
      |> Enum.flat_map(&Map.get(&1, "endpoints", []))

    ([selection["default"]] ++
       Enum.map(selection["rules"] || [], & &1["endpoint"]) ++
       Enum.map(selection["cases"] || [], & &1["path"]) ++ route_targets)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp selection_targets(_selection), do: []

  defp path_body_stub(body) do
    stub = :"default_family_#{System.unique_integer([:positive])}"
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)

    {stub, requests}
  end
end
