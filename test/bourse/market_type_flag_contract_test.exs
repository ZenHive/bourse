defmodule Bourse.MarketTypeFlagContractTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Spec
  alias Bourse.Unified.ReadParse

  # Rows that declare a type without the matching flag, or an option flag
  # without type "option". Values are per-row reasons. The allowlist may only
  # shrink: a newly-mismatched row fails the first assertion, and an entry that
  # now agrees fails as stale. Empty after carve C-T626 stopped Deribit combos
  # borrowing a single-leg type they do not satisfy.
  @type_flag_allowlist %{}

  @no_fetch_markets_recording %{
    "coinbaseexchange" => "public-only spot (candles + ticker); no fetch_markets recording"
  }

  # Recorded Deribit combo rows, one per shape. Re-mapping them to type "option"
  # without option: true (the reported divergence) turns the suite red.
  @combo_shape_pins [
    {"BTC-CS-18JUL26-65000_66000", "option_combo", :spread},
    {"BTC-PCAL-28AUG26_31JUL26-62000", "option_combo", :calendar},
    {"BTC_USDC-STRD-31JUL26-63000", "option_combo", :straddle},
    {"BTC-ICOND-16JUL26-63000_63500_65500_66000", "option_combo", :iron_condor}
  ]

  @inverse_seed_cases [
    {"BTC-PERPETUAL", true},
    {"ETH_USDC-PERPETUAL", false},
    {"BTC-31JUL26-65000-C", false},
    {"BTC-FS-31JUL26_17JUL26", true},
    {"BTC-CS-18JUL26-65000_66000", false},
    {"BTC-REV-17JUL26-65500", false}
  ]

  test "every recorded market's type and capability flags agree, or is allowlisted" do
    observed =
      Map.new(Spec.exchanges(), fn venue ->
        {venue, type_flag_mismatches(venue)}
      end)

    missing_recording =
      observed
      |> Enum.filter(fn {venue, result} ->
        result == :no_recording and not Map.has_key?(@no_fetch_markets_recording, venue)
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    assert missing_recording == [],
           "venues with no fetch_markets recording must be listed: #{inspect(missing_recording)}"

    assert Enum.all?(@type_flag_allowlist, fn {{venue, id}, reason} ->
             is_binary(venue) and is_binary(id) and is_binary(reason) and String.trim(reason) != ""
           end),
           "type/flag allowlist entries must carry a per-row reason"

    stale_no_recording =
      @no_fetch_markets_recording
      |> Map.keys()
      |> Enum.reject(&(observed[&1] == :no_recording))

    assert stale_no_recording == [],
           "no-recording allowlist is stale: #{inspect(stale_no_recording)}"

    unexpected =
      observed
      |> Enum.reject(fn {_venue, result} -> result == :no_recording end)
      |> Enum.flat_map(fn {venue, mismatches} ->
        Enum.reject(mismatches, &Map.has_key?(@type_flag_allowlist, {venue, &1.id}))
      end)

    assert unexpected == [],
           "type/flag contract broken: #{inspect(Enum.map(unexpected, &{&1.id, &1.type, &1.option, &1.contract}))}"

    stale =
      @type_flag_allowlist
      |> Map.keys()
      |> Enum.reject(fn {venue, id} ->
        case observed[venue] do
          mismatches when is_list(mismatches) -> Enum.any?(mismatches, &(&1.id == id))
          _ -> false
        end
      end)

    assert stale == [],
           "type/flag allowlist is stale — these rows now agree: #{inspect(stale)}"
  end

  test "recorded combo rows keep venue kind as type and are not quantity-resolvable" do
    markets = parse_markets!("deribit")

    for {id, type, shape} <- @combo_shape_pins do
      market = Enum.find(markets, &(&1.id == id))
      assert %Market{} = market, "missing recorded #{shape} combo #{id}"
      assert market.type == type
      assert market.option == false
      assert market.future == false
      assert get_in(market.info, ["kind"]) == type
      assert Market.combo?(market)
      refute Market.quantity_resolvable?(market)
    end
  end

  test "deribit inverse classifier and loaded markets agree on the recorded corpus" do
    markets = parse_markets!("deribit")

    disagreed =
      Enum.reject(markets, fn market ->
        ReadParse.deribit_inverse_instrument_id?(market.id) == (market.inverse == true)
      end)

    assert disagreed == [],
           "inverse mismatch: #{inspect(Enum.map(disagreed, &{&1.id, &1.inverse, get_in(&1.info, ["kind"])}))}"
  end

  test "deribit inverse seed cases stay pinned on the degradation path" do
    for {id, inverse?} <- @inverse_seed_cases do
      assert ReadParse.deribit_inverse_instrument_id?(id) == inverse?,
             "#{id} expected inverse=#{inverse?}"
    end
  end

  test "a shape the id parser cannot identify as inverse answers false" do
    refute ReadParse.deribit_inverse_instrument_id?("BTC-UNKNOWNSTRATEGY-18AUG26-1")
    refute ReadParse.deribit_inverse_instrument_id?("not-an-instrument")
    refute ReadParse.deribit_inverse_instrument_id?("BTC")
  end

  defp type_flag_mismatches(exchange_id) do
    case parse_markets(exchange_id) do
      {:ok, markets} ->
        Enum.filter(markets, &type_flag_mismatch?/1)

      :no_recording ->
        :no_recording
    end
  end

  defp type_flag_mismatch?(%Market{type: "option", option: option}), do: option != true
  defp type_flag_mismatch?(%Market{option: true, type: type}), do: type != "option"
  defp type_flag_mismatch?(%Market{type: type, contract: contract}) when type in ["swap", "future"], do: contract != true
  defp type_flag_mismatch?(_market), do: false

  defp parse_markets!(exchange_id) do
    case parse_markets(exchange_id) do
      {:ok, markets} -> markets
      :no_recording -> flunk("expected #{exchange_id} fetch_markets recording")
    end
  end

  defp parse_markets(exchange_id) do
    path = Path.join(["test/fixtures/responses", exchange_id, "fetch_markets.json"])

    if File.exists?(path) do
      {:ok, parse_fixture!(exchange_id, Jason.decode!(File.read!(path)))}
    else
      :no_recording
    end
  end

  defp parse_fixture!(exchange_id, %{"body" => body}) when is_map(body) do
    parse_body!(exchange_id, body)
  end

  defp parse_fixture!(exchange_id, %{"responses" => responses}) when is_list(responses) do
    Enum.flat_map(responses, &parse_body!(exchange_id, &1["body"]))
  end

  defp parse_body!(exchange_id, body) when is_map(body) do
    exchange = Exchange.new!(exchange_id)

    case ReadParse.parse(
           exchange,
           exchange.module,
           :fetch_markets,
           "fetchMarkets",
           body,
           %{},
           :parse_market,
           true
         ) do
      {:ok, markets} when is_list(markets) ->
        markets

      {:ok, %Market{} = market} ->
        [market]

      {:ok, other} ->
        flunk("#{exchange_id} fetch_markets parsed unexpected #{inspect(other)}")

      {:error, reason} ->
        flunk("#{exchange_id} fetch_markets fixture failed to parse: #{inspect(reason)}")
    end
  end

  defp parse_body!(_exchange_id, _body), do: []
end
