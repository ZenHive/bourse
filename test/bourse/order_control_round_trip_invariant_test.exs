defmodule Bourse.OrderControlRoundTripInvariantTest do
  @moduledoc false
  # Whole-surface invariant (task 700): a unified order control the write path
  # accepts must map back on the order read side. The control set is derived from
  # OrderOptions.aliases/0 plus authored create/edit request sources that name an
  # Order slot — never a hand-maintained field list. That is the class 622
  # (client identifier) and 632 (Binance-family order type) each fenced off
  # for one field.

  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Order
  alias Bourse.Spec
  alias Bourse.Unified.OrderOptions

  @order_write_methods ~w(createOrder editOrder createOrders)
  @prepare_types ~w(market limit stop stop_limit stop_market take_market take_limit)

  # Governed, exact, intended only to shrink. Each entry names one slot whose
  # provider contract does not publish a readable counterpart distinct from
  # another already-mapped field.
  @return_exemptions %{
    {"binance", "stopLossPrice"} => %{
      reason:
        "Spot and futures order objects publish stopPrice/triggerPrice; the protective leg is the order type (STOP_LOSS / STOP / STOP_MARKET), not a distinct stopLossPrice field.",
      source:
        "https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade",
      tracking: "Task 700; docs/authored-spec-carves/binance.md C-T700a"
    },
    {"binance", "takeProfitPrice"} => %{
      reason:
        "Spot and futures order objects publish stopPrice/triggerPrice; the protective leg is the order type (TAKE_PROFIT / TAKE_PROFIT_MARKET), not a distinct takeProfitPrice field.",
      source:
        "https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade",
      tracking: "Task 700; docs/authored-spec-carves/binance.md C-T700a"
    },
    {"binanceusdm", "stopLossPrice"} => %{
      reason:
        "USD-M algo and regular order objects publish triggerPrice; STOP vs TAKE_PROFIT is the type, not a distinct stopLossPrice field.",
      source:
        "https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade",
      tracking: "Task 700; docs/authored-spec-carves/binanceusdm.md C-T700a"
    },
    {"binanceusdm", "takeProfitPrice"} => %{
      reason:
        "USD-M algo and regular order objects publish triggerPrice; STOP vs TAKE_PROFIT is the type, not a distinct takeProfitPrice field.",
      source:
        "https://developers.binance.com/en/docs/catalog/core-trading-derivatives-trading-usd-s-m-futures/api/rest-api/trade",
      tracking: "Task 700; docs/authored-spec-carves/binanceusdm.md C-T700a"
    },
    {"binancecoinm", "stopLossPrice"} => %{
      reason:
        "COIN-M algo and regular order objects publish triggerPrice; STOP vs TAKE_PROFIT is the type, not a distinct stopLossPrice field.",
      source: "https://developers.binance.com/en/docs/derivatives/coin-margined-futures/trade/rest-api",
      tracking: "Task 700; docs/authored-spec-carves/binancecoinm.md C-T700a"
    },
    {"binancecoinm", "takeProfitPrice"} => %{
      reason:
        "COIN-M algo and regular order objects publish triggerPrice; STOP vs TAKE_PROFIT is the type, not a distinct takeProfitPrice field.",
      source: "https://developers.binance.com/en/docs/derivatives/coin-margined-futures/trade/rest-api",
      tracking: "Task 700; docs/authored-spec-carves/binancecoinm.md C-T700a"
    }
  }

  test "every write-side order control maps back on the order, or is exempted" do
    used = MapSet.new()

    used =
      Enum.reduce(Spec.exchanges(), used, fn venue, acc ->
        spec = Spec.load!(venue)
        maps = order_field_maps(spec)

        if maps == [] do
          acc
        else
          mapped = mapped_slots(maps)
          write_slots = write_slots(venue, spec)

          Enum.reduce(write_slots, acc, fn slot, inner ->
            case Map.fetch(@return_exemptions, {venue, slot}) do
              {:ok, _exemption} ->
                MapSet.put(inner, {venue, slot})

              :error ->
                assert slot in mapped,
                       "#{venue} accepts unified control #{slot} on write but order field map does not map it back"

                inner
            end
          end)
        end
      end)

    unused = MapSet.difference(MapSet.new(Map.keys(@return_exemptions)), used)

    assert MapSet.size(unused) == 0,
           "stale order-control exemptions are unused: #{inspect(MapSet.to_list(unused))}"
  end

  test "the derived write set includes the previously field-scoped round-trips" do
    # Task 622: client identifier. Task 632: order type. A newly authored write
    # control is the same class and must appear here without editing this list.
    deribit = write_slots("deribit", Spec.load!("deribit"))
    assert "clientOrderId" in deribit
    assert "type" in deribit
    assert "triggerPrice" in deribit
    assert "reduceOnly" in deribit

    binance = write_slots("binanceusdm", Spec.load!("binanceusdm"))
    assert "type" in binance
    assert "triggerPrice" in binance
    assert "stopLossPrice" in binance
    assert "takeProfitPrice" in binance
  end

  test "each exemption cites a provider contract" do
    for {{venue, slot}, exemption} <- @return_exemptions do
      assert is_binary(venue) and venue != ""
      assert slot in OrderOptions.canonical_slots()
      assert nonempty?(exemption.reason), "#{inspect({venue, slot})} exemption is missing a reason"
      assert nonempty?(exemption.source), "#{inspect({venue, slot})} exemption is missing a provider source"
      assert exemption.source =~ ~r/^https?:\/\//
      assert nonempty?(exemption.tracking)
    end
  end

  test "a mapped control stays nil when the provider omits it; no info fallback" do
    assert {:ok, %Order{trigger_price: nil, reduce_only: nil}} =
             Bourse.Deribit.parse_order(%{
               "amount" => 10,
               "direction" => "sell",
               "instrument_name" => "BTC-PERPETUAL",
               "order_id" => "SLTS-omit",
               "order_state" => "open",
               "order_type" => "stop_market"
             })

    assert {:ok, %Order{trigger_price: 65_525.0, reduce_only: false}} =
             Bourse.Deribit.parse_order(%{
               "amount" => 10,
               "direction" => "sell",
               "instrument_name" => "BTC-PERPETUAL",
               "order_id" => "SLTS-11018249",
               "order_state" => "untriggered",
               "order_type" => "stop_market",
               "reduce_only" => false,
               "trigger_price" => 65_525.0
             })

    # A similarly named info-only key is not a substitute for the mapped field.
    assert {:ok, %Order{trigger_price: nil, reduce_only: nil}} =
             Bourse.Deribit.parse_order(%{
               "amount" => 10,
               "direction" => "sell",
               "instrument_name" => "BTC-PERPETUAL",
               "order_id" => "SLTS-other-key",
               "order_state" => "open",
               "order_type" => "stop_market",
               "triggerPrice" => 65_525.0,
               "reduceOnly" => false
             })
  end

  test "truthy spellings are not guessed; empty provider zeros stay nil" do
    assert {:ok, %Order{reduce_only: nil}} =
             Bourse.Deribit.parse_order(%{
               "amount" => 10,
               "direction" => "sell",
               "instrument_name" => "BTC-PERPETUAL",
               "order_id" => "SLTS-yes",
               "order_state" => "open",
               "order_type" => "limit",
               "reduce_only" => "yes"
             })

    assert {:ok, %Order{trigger_price: nil, stop_loss_price: nil, take_profit_price: nil}} =
             Bourse.Bybit.parse_order(%{
               "orderId" => "zero",
               "orderStatus" => "New",
               "orderType" => "Limit",
               "qty" => "0.001",
               "side" => "Sell",
               "stopLoss" => "0.00",
               "takeProfit" => "",
               "triggerPrice" => "0.00"
             })

    assert {:ok, %Order{trigger_price: 65_500.7, reduce_only: false, stop_loss_price: nil}} =
             Bourse.Bybit.parse_order(%{
               "orderId" => "621de10e-13cf-475c-a3b4-a80b5ce7a41e",
               "orderStatus" => "Untriggered",
               "orderType" => "Market",
               "qty" => "0.001",
               "reduceOnly" => false,
               "side" => "Sell",
               "stopLoss" => "",
               "takeProfit" => "",
               "triggerPrice" => "65500.7"
             })

    assert {:ok, %Order{trigger_price: 65_520.55, reduce_only: false}} =
             Bourse.Okx.parse_order(%{
               "instId" => "BTC-USDT-SWAP",
               "ordId" => "3924794877069905920",
               "ordType" => "conditional",
               "reduceOnly" => "false",
               "side" => "sell",
               "state" => "live",
               "sz" => "0.01",
               "triggerPx" => "65520.55"
             })
  end

  defp write_slots(venue, spec) do
    alias_pairs = OrderOptions.aliases()
    order_slots = order_slot_names()

    MapSet.new()
    |> MapSet.union(accepted_option_slots(venue, alias_pairs))
    |> MapSet.union(spec_write_slots(spec, alias_pairs, order_slots))
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp accepted_option_slots(venue, alias_pairs) do
    exchange = Exchange.new!(venue)

    for {canonical, slot} <- alias_pairs,
        option_accepted?(exchange, canonical, sample_value(canonical)),
        into: MapSet.new() do
      slot
    end
  end

  defp option_accepted?(exchange, canonical, value) do
    Enum.any?(@prepare_types, fn type ->
      params =
        %{
          "amount" => 1,
          "price" => 40_000,
          "side" => "sell",
          "symbol" => "BTC/USDT",
          "type" => type,
          canonical => value
        }
        |> maybe_put_symbol(exchange.id)
        |> maybe_put_trigger(exchange.id)

      match?({:ok, _}, OrderOptions.prepare(exchange, :create_order, params))
    end)
  end

  defp maybe_put_symbol(params, "deribit"), do: Map.put(params, "symbol", "BTC/USD:BTC")
  defp maybe_put_symbol(params, "alpaca"), do: Map.merge(params, %{"symbol" => "AAPL", "time_in_force" => "gtc"})
  defp maybe_put_symbol(params, _venue), do: params

  defp maybe_put_trigger(params, "deribit"), do: Map.put(params, "trigger", "index_price")
  defp maybe_put_trigger(params, _venue), do: params

  defp sample_value("reduce_only"), do: true
  defp sample_value("time_in_force"), do: "GTC"
  defp sample_value(_price), do: 40_000

  defp spec_write_slots(spec, alias_pairs, order_slots) do
    alias_map =
      Map.new(Enum.flat_map(alias_pairs, fn {canonical, slot} -> [{canonical, slot}, {slot, slot}] end))

    for {_native, sources} <- spec_request_sources(spec),
        source <- sources,
        slot = source_to_slot(source, alias_map, order_slots),
        not is_nil(slot),
        into: MapSet.new() do
      slot
    end
  end

  defp spec_request_sources(spec) do
    defaults = get_in(spec, ["endpoints", "request", "defaults"]) || %{}
    overrides = get_in(spec, ["endpoints", "request", "endpoint_overrides"]) || %{}

    default_entries =
      Enum.flat_map(@order_write_methods, fn method ->
        case Map.get(defaults, method) do
          %{} = entries -> collect_sources(entries)
          _missing -> []
        end
      end)

    override_entries =
      Enum.flat_map(@order_write_methods, fn method ->
        case Map.get(overrides, method) do
          %{} = paths -> Enum.flat_map(Map.values(paths), &collect_sources/1)
          _missing -> []
        end
      end)

    default_entries ++ override_entries
  end

  defp collect_sources(entries) when is_map(entries) do
    Enum.flat_map(entries, fn
      {"_omit", _value} ->
        []

      {native, entry} when is_map(entry) ->
        sources = Enum.reject([entry["source"] | List.wrap(entry["fallback_sources"])], &is_nil/1)
        [{native, sources} | nested_sources(entry)]

      _other ->
        []
    end)
  end

  defp collect_sources(_entries), do: []

  defp nested_sources(%{"cases" => cases}) when is_list(cases) do
    Enum.flat_map(cases, fn
      %{"when" => %{} = when_clause} -> [{nil, Map.keys(when_clause)}]
      _other -> []
    end)
  end

  defp nested_sources(_entry), do: []

  defp source_to_slot(source, alias_map, order_slots) when is_binary(source) do
    cond do
      Map.has_key?(alias_map, source) -> alias_map[source]
      source in order_slots -> source
      snake_to_camel(source) in order_slots -> snake_to_camel(source)
      true -> nil
    end
  end

  defp source_to_slot(_source, _alias_map, _order_slots), do: nil

  defp order_slot_names do
    %Order{}
    |> Map.from_struct()
    |> Map.keys()
    |> Enum.map(&Atom.to_string/1)
    |> MapSet.new(&snake_to_camel/1)
  end

  defp snake_to_camel(key) do
    [first | rest] = String.split(key, "_")
    first <> Enum.map_join(rest, &String.capitalize/1)
  end

  defp order_field_maps(spec) do
    case get_in(spec, ["normalization", "field_maps", "order"]) do
      %{"field_map" => field_map} when is_map(field_map) ->
        [field_map]

      %{"branches" => branches} when is_list(branches) ->
        for %{"field_map" => field_map} <- branches, is_map(field_map), do: field_map

      _missing ->
        []
    end
  end

  defp mapped_slots(maps) do
    maps
    |> Enum.flat_map(fn field_map ->
      Enum.flat_map(field_map, fn
        {slot, rule} when is_map(rule) -> [slot]
        _other -> []
      end)
    end)
    |> MapSet.new()
  end

  defp nonempty?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty?(_value), do: false
end
