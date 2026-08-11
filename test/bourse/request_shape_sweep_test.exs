defmodule Bourse.RequestShapeSweepTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Registry
  alias Bourse.Spec
  alias Bourse.Unified
  alias Bourse.Unified.RequestShape

  @moduletag :request_shape_sweep

  @timestamp_ms 1_700_000_000_000
  @dex_credentials [
    api_key: "0x0000000000000000000000000000000000000000",
    secret: "0x0123456789012345678901234567890123456789012345678901234567890123",
    password: "password"
  ]
  # Lighter API signing key is 40 bytes (not EVM); api_key is the key index and
  # uid is the account index (matches the pinned CCXT compatibility fixture).
  @lighter_credentials [
    api_key: "30",
    secret: "e6b975b33b81e53fb5333bd84553f12b3b5327ce5b1595139f49e8bebf734d9b1b81d3351b487d1b",
    password: "password",
    uid: "715085"
  ]
  @credentials [api_key: "key", secret: "secretsecret", password: "password", uid: "uid"]
  @time_window_contracts [
    {"alpaca", "fetchOHLCV", "start", "2023-11-14T22:13:20.000Z",
     %{"symbol" => "GLD", "timeframe" => "1d", "since" => @timestamp_ms, "limit" => 2},
     [endpoint_path: "v2/stocks/{symbol}/bars"]},
    {"binance", "fetchOrders", "startTime", @timestamp_ms,
     %{"symbol" => "BTCUSDT", "since" => @timestamp_ms, "limit" => 2}, []},
    {"binancecoinm", "fetchFundingRateHistory", "startTime", @timestamp_ms,
     %{"symbol" => "BTCUSD_PERP", "since" => @timestamp_ms, "limit" => 2}, []},
    {"binanceusdm", "fetchOrders", "startTime", @timestamp_ms,
     %{"symbol" => "BTCUSDT", "since" => @timestamp_ms, "limit" => 2}, []},
    {"bybit", "fetchOHLCV", "start", @timestamp_ms,
     %{"symbol" => "BTCUSDT", "timeframe" => "1h", "since" => @timestamp_ms, "limit" => 2}, []},
    {"deribit", "fetchTrades", "start_timestamp", @timestamp_ms,
     %{"symbol" => "BTC-PERPETUAL", "since" => @timestamp_ms, "limit" => 2}, []},
    {"derive", "fetchTrades", "from_timestamp", @timestamp_ms,
     %{"symbol" => "ETH-PERP", "since" => @timestamp_ms, "limit" => 2}, []},
    {"hyperliquid", "fetchMyTrades", "startTime", @timestamp_ms, %{"since" => @timestamp_ms, "limit" => 2}, []},
    {"lighter", "fetchOHLCV", "start_timestamp", @timestamp_ms,
     %{"market_id" => 0, "timeframe" => "1h", "since" => @timestamp_ms, "limit" => 2}, []},
    {"okx", "fetchMyTrades", "begin", @timestamp_ms, %{"symbol" => "BTC-USDT", "since" => @timestamp_ms, "limit" => 2},
     []}
  ]
  @required_params_by_js_name Map.new(Unified.method_defs(), fn {_name, js_name, params, _description} ->
                                {js_name, params}
                              end)
  @sample_required_params %{
    address: "0x0000000000000000000000000000000000000001",
    amount: 1,
    code: "USDT",
    cost: 1,
    duration: 60_000,
    from_account: "spot",
    from_code: "USDT",
    hedge_mode: true,
    id: "order-1",
    ids: ["order-1"],
    leverage: 1,
    margin_mode: "cross",
    orders: [
      %{
        "symbol" => "BTC/USDT:USDT",
        "type" => "limit",
        "side" => "buy",
        "amount" => 1,
        "price" => 10_000
      }
    ],
    portfolio_id: "portfolio-1",
    side: "buy",
    state: "open",
    status: "open",
    sub_type: "linear",
    symbol: "BTC/USDT:USDT",
    timeframe: "1h",
    timeout: 0,
    to_account: "swap",
    to_code: "USDC",
    type: "market"
  }

  # Entries still owned by an OPEN task, each naming its task id. Empty is the
  # goal state and the current one. The allowlist may only shrink: a new
  # unresolved reference fails the first assertion, and an entry that has since
  # been authored fails the staleness assertion below rather than lingering as a
  # silently-vacuous exemption (same discipline as the fixture-replay baseline).
  @allowlist %{}

  test "every builder in the compiled corpus resolves to supported behavior" do
    contracts =
      for exchange_id <- Registry.exchanges(),
          exchange = Exchange.new!(exchange_id),
          {js_name, builder} <- builders(exchange.request_param_shape) do
        assert Spec.resolve_request_builder!(exchange_id, js_name, builder) in [:binance, :bybit]
        {exchange_id, js_name, builder}
      end

    assert contracts != [], "compiled corpus contains no request-shape builder contracts"
  end

  defp builders(shape) do
    Enum.flat_map(shape, fn
      {"endpoint_overrides", overrides} ->
        for {js_name, paths} <- overrides,
            {_path, %{"_builder" => builder}} <- paths,
            do: {js_name, builder}

      {js_name, %{"_builder" => builder}} ->
        [{js_name, builder}]

      _entry ->
        []
    end)
  end

  test "first-class request shapes have no unowned unresolved identifier references" do
    unresolved =
      Spec.exchanges()
      |> Enum.flat_map(&unresolved_methods/1)
      |> MapSet.new()

    allowed = MapSet.new(Map.keys(@allowlist))

    assert MapSet.subset?(unresolved, allowed),
           "new unresolved identifier references: #{inspect(MapSet.difference(unresolved, allowed))}"

    stale = MapSet.difference(allowed, unresolved)

    assert MapSet.equal?(stale, MapSet.new()),
           "allowlist is stale — these entries now resolve and must be removed: #{inspect(MapSet.to_list(stale))}"
  end

  test "unexpected builder exceptions fail the sweep" do
    assert_raise ArgumentError, "unexpected builder failure", fn ->
      unresolved_methods("bybit", fn _params, _exchange, _js_name, _opts ->
        raise ArgumentError, "unexpected builder failure"
      end)
    end
  end

  test "every documented venue time window reaches a provider-native parameter" do
    for {exchange_id, js_name, native_key, expected, params, opts} <- @time_window_contracts do
      shaped = RequestShape.apply(params, sweep_exchange(exchange_id), js_name, opts)

      assert shaped[native_key] == expected,
             "#{exchange_id}.#{js_name} must map since to #{native_key}, got: #{inspect(shaped)}"

      refute Map.has_key?(shaped, "since"),
             "#{exchange_id}.#{js_name} leaked unified since: #{inspect(shaped)}"
    end
  end

  test "no unified read request shape serializes nil optionals as empty query values" do
    for exchange_id <- Registry.exchanges(),
        {js_name, configs, shaped} <- shaped_reads(exchange_id) do
      nil_keys = nil_paths(shaped)

      assert nil_keys == [],
             "#{exchange_id}.#{js_name} retained nil optionals: #{inspect(nil_keys)}"

      empty_keys = for {key, ""} <- shaped, do: key

      if Enum.any?(configs, &(&1.method in [:get, :head])) do
        assert empty_keys == [],
               "#{exchange_id}.#{js_name} serialized empty query values: #{inspect(empty_keys)}"
      end
    end
  end

  defp unresolved_methods(exchange_id, apply_request_shape \\ &RequestShape.apply/4) do
    exchange = sweep_exchange(exchange_id)

    exchange.request_param_shape
    |> Map.keys()
    |> Enum.flat_map(fn js_name ->
      try do
        apply_request_shape.(params_for(exchange_id, js_name), exchange, js_name, timestamp_ms_override: @timestamp_ms)

        []
      rescue
        error ->
          case error do
            %ArgumentError{message: "unresolved identifier_reference " <> _details} ->
              [{exchange_id, js_name}]

            _unexpected ->
              reraise error, __STACKTRACE__
          end
      end
    end)
  end

  defp shaped_reads(exchange_id) do
    exchange = sweep_exchange(exchange_id)

    exchange.module.__unified_endpoints__()
    |> Enum.filter(fn {method, _configs} -> method |> Unified.js_name_for!() |> String.starts_with?("fetch") end)
    |> Enum.map(fn {method, configs} ->
      js_name = Unified.js_name_for!(method)
      params = Map.merge(%{"limit" => nil, "since" => nil, "until" => nil}, params_for(exchange_id, js_name))
      {js_name, configs, RequestShape.apply(params, exchange, js_name, timestamp_ms_override: @timestamp_ms)}
    end)
  end

  defp nil_paths(value, path \\ [])

  defp nil_paths(map, path) when is_map(map) do
    Enum.flat_map(map, fn
      {key, nil} -> [Enum.reverse([key | path])]
      {key, value} -> nil_paths(value, [key | path])
    end)
  end

  defp nil_paths(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> nil_paths(value, [index | path]) end)
  end

  defp nil_paths(_value, _path), do: []

  defp sweep_exchange(exchange_id) do
    exchange_id
    |> then(&Exchange.new!(&1, options_for(&1) ++ credentials_for(&1)))
    |> put_sweep_markets(exchange_id)
  end

  defp credentials_for(exchange_id) when exchange_id in ["derive", "hyperliquid"], do: @dex_credentials
  defp credentials_for("lighter"), do: @lighter_credentials
  defp credentials_for(_exchange_id), do: @credentials

  # Derive's private methods carry a caller-owned `subaccount_id` that task 416
  # defaults from exchange-level options. Sweeping without it measures that
  # deliberate fail-loud path rather than an authoring gap, so the sweep
  # configures the venue the way a real caller does.
  defp options_for("derive"), do: [options: %{"subaccount_id" => 144_422}]
  defp options_for(_exchange_id), do: []

  defp put_sweep_markets(exchange, "derive") do
    Exchange.put_markets(exchange, [
      %Market{
        id: "ETH-PERP",
        symbol: "ETH/USD:USDC",
        info: %{
          "base_asset_address" => "0x0000000000000000000000000000000000000001",
          "base_asset_sub_id" => "0"
        }
      }
    ])
  end

  defp put_sweep_markets(exchange, "hyperliquid") do
    Exchange.put_markets(exchange, [%Market{symbol: "BTC/USDC:USDC", asset_index: 7}])
  end

  # Lighter order builders resolve market_index from the loaded market id and
  # scale amount/price by market precision (task 501 fixture-venue expansion).
  defp put_sweep_markets(exchange, "lighter") do
    Exchange.put_markets(exchange, [
      %Market{
        id: "0",
        symbol: "ETH/USDC:USDC",
        precision: %{amount: 0.001, price: 0.01}
      }
    ])
  end

  defp put_sweep_markets(exchange, _exchange_id), do: exchange

  defp params_for("derive", js_name) when js_name in ["createOrder", "editOrder"] do
    %{
      "id" => "order-1",
      "symbol" => "ETH/USD:USDC",
      "type" => "limit",
      "side" => "buy",
      "amount" => 1,
      "price" => 100,
      "max_fee" => 2
    }
  end

  defp params_for("derive", "cancelOrder"), do: %{"id" => "order-1", "symbol" => "ETH/USD:USDC"}

  # cancel_order's unified required set is only [:id]; Lighter's builder also
  # needs symbol + a caller-supplied nonce (zk write path).
  defp params_for("lighter", "cancelOrder") do
    %{"id" => "1", "symbol" => "ETH/USDC:USDC", "nonce" => 0}
  end

  defp params_for("lighter", "createOrder") do
    %{
      "symbol" => "ETH/USDC:USDC",
      "type" => "limit",
      "side" => "buy",
      "amount" => 1,
      "price" => 100,
      "client_order_index" => 1,
      "nonce" => 0
    }
  end

  # lighter deposit/history marks l1_address required (see RequestShape.Lighter);
  # supply it so the whole-venue sweep can build the shape.
  defp params_for("lighter", "fetchDeposits"), do: %{"l1_address" => "0xabc"}

  defp params_for("hyperliquid", "createTwapOrder") do
    %{"symbol" => "BTC/USDC:USDC", "side" => "buy", "amount" => 1, "duration" => 60_000}
  end

  defp params_for(_exchange_id, "createOrders") do
    %{
      "orders" => [
        %{
          "symbol" => "BTC/USDT:USDT",
          "type" => "limit",
          "side" => "buy",
          "amount" => 1,
          "price" => 10_000
        }
      ]
    }
  end

  defp params_for(_exchange_id, "editOrders") do
    %{
      "orders" => [
        %{
          "id" => "order-1",
          "symbol" => "BTC/USDT:USDT",
          "type" => "limit",
          "side" => "buy",
          "amount" => 1,
          "price" => 10_000
        }
      ]
    }
  end

  defp params_for(_exchange_id, "cancelAllOrdersAfter"), do: %{"timeout" => 0}

  defp params_for(exchange_id, "modifyMarginHelper") when exchange_id in ["binance", "binanceusdm"],
    do: %{"symbol" => "BTC/USDT", "amount" => 1, "type" => "add"}

  defp params_for(exchange_id, "redeemGiftCode") when exchange_id in ["binance", "binanceusdm"], do: %{"code" => "code"}

  defp params_for("okx", js_name) when js_name in ["fetchBorrowRateHistory", "fetchCrossBorrowRate"],
    do: %{"code" => "USDT"}

  defp params_for("okx", "fetchOptionChain"), do: %{"symbol" => "BTC"}

  defp params_for(_exchange_id, js_name) do
    @required_params_by_js_name
    |> Map.get(js_name, [])
    |> Map.new(fn param -> {Atom.to_string(param), Map.fetch!(@sample_required_params, param)} end)
  end
end
