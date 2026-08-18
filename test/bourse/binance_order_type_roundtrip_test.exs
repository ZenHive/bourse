defmodule Bourse.BinanceOrderTypeRoundtripTest do
  @moduledoc false
  # Suite-level invariant: Binance-family native→unified order-type reads invert
  # the authored write mapping. A newly authored write type without a matching
  # read counterpart fails here rather than collapsing to market/limit or a
  # silent downcase (task 632).

  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Spec
  alias Bourse.Unified.ReadParse

  @binance_family ~w(binance binanceusdm binancecoinm)
  @batch_source "lib/bourse/unified/request_shape/binance.ex"
  @external_resource @batch_source

  # Spot New Order `type` enum:
  # https://developers.binance.com/en/docs/catalog/core-trading-spot-trading/api/rest-api/trade
  @spot_documented_types %{
    "LIMIT" => "limit",
    "LIMIT_MAKER" => "limit",
    "MARKET" => "market",
    "STOP_LOSS" => "stop_loss",
    "STOP_LOSS_LIMIT" => "stop_loss_limit",
    "TAKE_PROFIT" => "take_profit",
    "TAKE_PROFIT_LIMIT" => "take_profit_limit"
  }

  # Regular LIMIT/MARKET plus algoType=CONDITIONAL types from
  # https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade
  # and the COIN-M sibling enum (same literals).
  @futures_documented_types %{
    "LIMIT" => "limit",
    "MARKET" => "market",
    "STOP" => "stop",
    "STOP_MARKET" => "stop_market",
    "TAKE_PROFIT" => "take_profit",
    "TAKE_PROFIT_MARKET" => "take_profit_market",
    "TRAILING_STOP_MARKET" => "trailing_stop_market"
  }

  # Options EAPI New Order documents LIMIT only:
  # https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-options/api/rest-api/trade
  @option_documented_types %{"LIMIT" => "limit"}

  @required_write_types ~w(stop stop_market take_profit take_profit_market trailing_stop_market)

  test "every authored Binance-family write type reads back as itself" do
    pairs = authored_write_types()
    authored_unified = MapSet.new(Enum.map(pairs, &elem(&1, 0)))

    assert pairs != [], "no authored Binance-family write types found — invariant is vacuous"

    for required <- @required_write_types do
      assert required in authored_unified,
             "write path no longer authors unified type #{required}; the round-trip invariant would miss it"
    end

    for {unified, native} <- pairs,
        {exchange_id, module, params} <- futures_read_contexts() do
      assert {:ok, %Bourse.Order{type: ^unified}} =
               parse_order(exchange_id, module, native, params),
             "#{exchange_id} wrote #{inspect(unified)} as #{inspect(native)} but read-back differed"
    end
  end

  test "spot and futures documented native enums map on their own product" do
    for {native, unified} <- @spot_documented_types do
      assert {:ok, %Bourse.Order{type: ^unified}} =
               parse_order("binance", Bourse.Binance, native, %{"symbol" => "ETH/USDT"})
    end

    for {native, unified} <- @futures_documented_types,
        {exchange_id, module, params} <- futures_read_contexts() do
      assert {:ok, %Bourse.Order{type: ^unified}} =
               parse_order(exchange_id, module, native, params)
    end

    assert {:ok, %Bourse.Order{type: "limit"}} =
             parse_order("binance", Bourse.Binance, "LIMIT", %{
               "symbol" => "ETH/USDT:USDT-260814-66-P",
               "_bourse_endpoint_market_type" => :option
             })
  end

  test "a native type that only one product documents is not accepted on the other" do
    assert {:error, %Error{type: :exchange_error} = error} =
             parse_order("binance", Bourse.Binance, "STOP_MARKET", %{"symbol" => "ETH/USDT"})

    assert error.raw == %{venue: "binance", product: :spot, field: "type", raw_value: "STOP_MARKET"}

    assert {:error, %Error{type: :exchange_error} = futures_error} =
             parse_order("binanceusdm", Bourse.Binanceusdm, "STOP_LOSS", %{
               "symbol" => "ETH/USDT:USDT"
             })

    assert futures_error.raw == %{
             venue: "binanceusdm",
             product: :futures,
             field: "type",
             raw_value: "STOP_LOSS"
           }

    assert {:error, %Error{type: :exchange_error} = option_error} =
             parse_order("binance", Bourse.Binance, "TAKE_PROFIT", %{
               "symbol" => "ETH/USDT:USDT-260814-66-P",
               "_bourse_endpoint_market_type" => :option
             })

    assert option_error.raw.product == :option
    assert option_error.raw.raw_value == "TAKE_PROFIT"
  end

  test "an undocumented native order type fails instead of being downcased" do
    for {exchange_id, module, params, product} <- [
          {"binance", Bourse.Binance, %{"symbol" => "ETH/USDT"}, :spot},
          {"binanceusdm", Bourse.Binanceusdm, %{"symbol" => "ETH/USDT:USDT"}, :futures},
          {"binancecoinm", Bourse.Binancecoinm, %{"symbol" => "BTC/USD:BTC"}, :futures}
        ] do
      assert {:error, %Error{type: :exchange_error} = error} =
               parse_order(exchange_id, module, "PROVIDER_ADDED_TYPE", params)

      assert error.raw == %{
               venue: exchange_id,
               product: product,
               field: "type",
               raw_value: "PROVIDER_ADDED_TYPE"
             }

      refute error.message =~ "provider_added_type"
    end
  end

  test "documented product enums have no silent-downcase leftovers" do
    documented = %{
      spot: MapSet.new(Map.keys(@spot_documented_types)),
      futures: MapSet.new(Map.keys(@futures_documented_types)),
      option: MapSet.new(Map.keys(@option_documented_types))
    }

    futures_only = MapSet.difference(documented.futures, documented.spot)
    spot_only = MapSet.difference(documented.spot, documented.futures)

    assert "STOP_MARKET" in futures_only
    assert "TRAILING_STOP_MARKET" in futures_only
    assert "STOP_LOSS" in spot_only
    assert "TAKE_PROFIT_LIMIT" in spot_only
    assert "LIMIT" in documented.option
  end

  test "an unmapped type in a list fails the whole parse rather than downcasing one row" do
    assert {:error, %Error{type: :exchange_error} = error} =
             ReadParse.parse(
               Exchange.new!("binanceusdm"),
               Bourse.Binanceusdm,
               :fetch_orders,
               "fetchOrders",
               [
                 %{"orderId" => "1", "type" => "LIMIT", "status" => "NEW", "symbol" => "ETHUSDT"},
                 %{"orderId" => "2", "type" => "PROVIDER_ADDED_TYPE", "status" => "NEW", "symbol" => "ETHUSDT"}
               ],
               %{"symbol" => "ETH/USDT:USDT"},
               :parse_order,
               true
             )

    assert error.raw == %{
             venue: "binanceusdm",
             product: :futures,
             field: "type",
             raw_value: "PROVIDER_ADDED_TYPE"
           }
  end

  test "umbrella product falls back to market family, dated futures, and endpoint identity" do
    assert {:ok, %Bourse.Order{type: "stop_market"}} =
             parse_order("binance", Bourse.Binance, "STOP_MARKET", %{"market_family" => "linear"})

    assert {:ok, %Bourse.Order{type: "stop"}} =
             parse_order("binance", Bourse.Binance, "STOP", %{"market_family" => "inverse"})

    assert {:ok, %Bourse.Order{type: "stop_loss"}} =
             parse_order("binance", Bourse.Binance, "STOP_LOSS", %{"market_family" => "spot"})

    assert {:ok, %Bourse.Order{type: "limit"}} =
             parse_order("binance", Bourse.Binance, "LIMIT", %{"market_family" => "option"})

    assert {:ok, %Bourse.Order{type: "stop"}} =
             parse_order("binance", Bourse.Binance, "STOP", %{
               "_bourse_endpoint_market_type" => :future
             })

    assert {:ok, %Bourse.Order{type: "take_profit_market"}} =
             parse_order("binance", Bourse.Binance, "TAKE_PROFIT_MARKET", %{
               "_bourse_endpoint_id" => "fapiPrivate/post/fapi/v1/algoOrder"
             })

    assert {:ok, %Bourse.Order{type: "trailing_stop_market"}} =
             parse_order("binance", Bourse.Binance, "TRAILING_STOP_MARKET", %{
               "_bourse_endpoint_route" => "/dapi/v1/algoOrder"
             })

    assert {:error, %Error{type: :exchange_error} = error} =
             parse_order("binance", Bourse.Binance, "STOP_MARKET", %{
               "_bourse_endpoint_id" => "eapiPrivate/post/eapi/v1/order"
             })

    assert error.raw.product == :option
  end

  test "a missing native type is left unset rather than rejected" do
    assert {:ok, %Bourse.Order{type: nil}} =
             ReadParse.parse(
               Exchange.new!("binance"),
               Bourse.Binance,
               :fetch_order,
               "fetchOrder",
               %{"orderId" => "1", "status" => "NEW", "symbol" => "ETHUSDT"},
               %{"symbol" => "ETH/USDT"},
               :parse_order,
               false
             )
  end

  defp authored_write_types do
    spec_pairs =
      @binance_family
      |> Enum.flat_map(&explicit_create_order_type_cases/1)
      |> Enum.uniq()

    Enum.uniq(spec_pairs ++ batch_write_types())
  end

  defp explicit_create_order_type_cases(venue) do
    venue
    |> Spec.load!()
    |> get_in(~w(endpoints request defaults endpoint_overrides createOrder algoOrder type cases))
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"value" => native, "when" => %{"type" => unified} = when_clause}
      when is_binary(native) and is_binary(unified) and map_size(when_clause) == 1 ->
        [{unified, native}]

      _other ->
        []
    end)
  end

  defp batch_write_types do
    source = File.read!(@batch_source)
    [_, inner] = Regex.run(~r/@all_order_types ~w\(([^)]+)\)/, source)

    for native <- String.split(inner), native != "" do
      {String.downcase(native), native}
    end
  end

  defp futures_read_contexts do
    [
      {"binance", Bourse.Binance, %{"symbol" => "ETH/USDT:USDT"}},
      {"binanceusdm", Bourse.Binanceusdm, %{"symbol" => "ETH/USDT:USDT"}},
      {"binancecoinm", Bourse.Binancecoinm, %{"symbol" => "BTC/USD:BTC"}}
    ]
  end

  defp parse_order(exchange_id, module, native_type, params) do
    ReadParse.parse(
      Exchange.new!(exchange_id),
      module,
      :fetch_order,
      "fetchOrder",
      %{
        "orderId" => "1",
        "type" => native_type,
        "status" => "NEW",
        "symbol" => params["symbol"] || "ETHUSDT"
      },
      params,
      :parse_order,
      false
    )
  end
end
