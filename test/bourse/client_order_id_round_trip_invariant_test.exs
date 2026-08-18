defmodule Bourse.ClientOrderIdRoundTripInvariantTest do
  @moduledoc false
  # Whole-surface invariant (task 622): a venue may map a client identifier in both
  # directions or in neither. Mapping unified clientOrderId onto a native request key
  # without mapping that identifier back on order *and* trade fails here, unless a
  # named exemption cites the provider contract for a surface that has no returnable id.

  use ExUnit.Case, async: true

  @order_write_methods ~w(createOrder editOrder createOrders)
  @unified_client_id_sources ~w(clientOrderId client_order_id)

  # Elixir request builders that rename unified clientOrderId onto a native key
  # without an authored createOrder reference entry. Add a venue here when a
  # RequestShape.* module starts mapping the unified id; do not add venues that
  # only echo a caller-supplied native key.
  @elixir_request_mapped_venues MapSet.new(~w(
    binance
    binanceusdm
    bybit
    derive
    hyperliquid
    lighter
    okx
  ))

  # Governed, exact, intended only to shrink. Each entry names one surface whose
  # provider contract does not echo a client identifier.
  @return_exemptions %{
    {"binance", :trade} => %{
      reason: "Spot Account Trade List returns orderId and does not echo clientOrderId or newClientOrderId.",
      source:
        "https://developers.binance.com/docs/binance-spot-api-docs/rest-api/account-endpoints#account-trade-list-user_data",
      tracking: "Task 622; docs/authored-spec-carves/global.md C-T622a"
    },
    {"binanceusdm", :trade} => %{
      reason: "USD-M Account Trade List returns orderId and does not echo clientOrderId or newClientOrderId.",
      source: "https://developers.binance.com/docs/derivatives/usds-margined-futures/trade/rest-api/Account-Trade-List",
      tracking: "Task 622; docs/authored-spec-carves/global.md C-T622a"
    },
    {"derive", :trade} => %{
      reason: "Derive get_trade_history fill rows expose trade_id and order_id and do not echo label.",
      source: "https://docs.derive.xyz/",
      tracking: "Task 622; docs/authored-spec-carves/global.md C-T622a"
    },
    {"hyperliquid", :trade} => %{
      reason: "userFills carry oid (exchange order id) and do not echo cloid.",
      source: "https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#user-fills",
      tracking: "Task 622; docs/authored-spec-carves/global.md C-T622a"
    },
    {"lighter", :trade} => %{
      reason:
        "Lighter trade rows carry ask_client_id and bid_client_id for the two sides of a match, not the placing account's client_order_index.",
      source: "https://apidocs.lighter.xyz/",
      tracking: "Task 622; docs/authored-spec-carves/global.md C-T622a"
    }
  }

  test "every request-side client-id mapping round-trips on order and trade, or is exempted" do
    used_exemptions = MapSet.new()

    used_exemptions =
      Enum.reduce(Bourse.Spec.exchanges(), used_exemptions, fn venue, acc ->
        spec = Bourse.Spec.load!(venue)
        check_venue(venue, spec, acc)
      end)

    unused = MapSet.difference(MapSet.new(Map.keys(@return_exemptions)), used_exemptions)

    assert MapSet.size(unused) == 0,
           "stale client-id exemptions are unused: #{inspect(MapSet.to_list(unused))}"
  end

  test "each exemption cites a provider contract" do
    for {{venue, surface}, exemption} <- @return_exemptions do
      assert is_binary(venue) and venue != ""
      assert surface in [:order, :trade]
      assert nonempty?(exemption.reason), "#{inspect({venue, surface})} exemption is missing a reason"
      assert nonempty?(exemption.source), "#{inspect({venue, surface})} exemption is missing a provider source"
      assert exemption.source =~ ~r/^https?:\/\// or exemption.source =~ ~r/\b(API|docs|contract)\b/i
      assert nonempty?(exemption.tracking)
    end
  end

  defp check_venue(venue, spec, used_exemptions) do
    if request_maps_unified_client_id?(venue, spec) do
      used_exemptions
      |> then(&assert_return_map(venue, spec, :order, &1))
      |> then(&assert_return_map(venue, spec, :trade, &1))
    else
      used_exemptions
    end
  end

  defp request_maps_unified_client_id?(venue, spec) do
    venue in @elixir_request_mapped_venues or spec_request_maps_unified_client_id?(spec)
  end

  defp spec_request_maps_unified_client_id?(spec) do
    Enum.any?(@order_write_methods, fn method ->
      spec
      |> request_entries(method)
      |> Enum.any?(&maps_unified_client_id?/1)
    end)
  end

  defp request_entries(spec, method) do
    case get_in(spec, ["endpoints", "request", "defaults", method]) do
      entries when is_map(entries) -> Map.values(entries)
      _missing -> []
    end
  end

  defp maps_unified_client_id?(entry) when is_map(entry) do
    sources = [entry["source"] | List.wrap(entry["fallback_sources"])]
    Enum.any?(sources, &(&1 in @unified_client_id_sources))
  end

  defp maps_unified_client_id?(_entry), do: false

  defp assert_return_map(venue, spec, surface, used_exemptions) do
    case Map.fetch(@return_exemptions, {venue, surface}) do
      {:ok, _exemption} ->
        MapSet.put(used_exemptions, {venue, surface})

      :error ->
        slot = get_in(spec, ["normalization", "field_maps", Atom.to_string(surface)])
        maps = field_maps_in(slot)

        assert maps != [],
               "#{venue} maps a unified client id on the request but authors no #{surface} field map"

        missing =
          Enum.reject(maps, fn field_map ->
            match?(%{"clientOrderId" => rule} when is_map(rule), field_map)
          end)

        assert missing == [],
               "#{venue} maps a unified client id on the request but #{surface} field map(s) do not map it back"

        used_exemptions
    end
  end

  defp field_maps_in(%{"field_map" => field_map}) when is_map(field_map), do: [field_map]

  defp field_maps_in(%{"branches" => branches}) when is_list(branches) do
    Enum.flat_map(branches, fn
      %{"field_map" => field_map} when is_map(field_map) -> [field_map]
      _branch -> []
    end)
  end

  defp field_maps_in(_slot), do: []

  defp nonempty?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty?(_value), do: false
end
