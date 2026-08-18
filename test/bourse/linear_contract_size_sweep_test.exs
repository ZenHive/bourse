defmodule Bourse.LinearContractSizeSweepTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Spec
  alias Bourse.Unified.ReadParse

  # Venues whose recorded linear (or perp) markets still land `contract_size`
  # nil after parse. The allowlist may only shrink: a newly-nil venue fails
  # the first assertion, and an entry that now populates fails as stale.
  @known_linear_nil_gaps %{
    "binance" =>
      "umbrella sandbox/mainnet fan-out still maps only exchangeInfo.contractSize, which FAPI does not publish; the venue-level unit is authored on dedicated binanceusdm",
    "bybit" =>
      "V5 linear instrument-info rows do not publish contractSize; quantity is already coin-denominated and no venue-level unit is authored yet",
    "derive" =>
      "perp instrument rows publish no contract-size field; market.contractSize stays null and no venue-level unit is authored yet"
  }

  test "every venue's linear markets are populated or recorded as a known gap" do
    observed = Map.new(Spec.exchanges(), &{&1, linear_nils(&1)})

    unexpected =
      observed
      |> Enum.filter(fn {venue, nils} -> nils != [] and not Map.has_key?(@known_linear_nil_gaps, venue) end)
      |> Map.new(fn {venue, nils} -> {venue, Enum.take(nils, 3)} end)

    assert unexpected == %{},
           "linear markets landed contract_size nil without a recorded gap: #{inspect(unexpected)}"

    stale =
      @known_linear_nil_gaps
      |> Map.keys()
      |> Enum.reject(&(observed[&1] != []))

    assert stale == [],
           "known-gap allowlist is stale — these venues now populate linear contract_size: #{inspect(stale)}"
  end

  defp linear_nils(exchange_id) do
    case parse_linear_markets(exchange_id) do
      {:ok, markets} ->
        markets
        |> Enum.filter(&(&1.linear == true and &1.contract == true and is_nil(&1.contract_size)))
        |> Enum.map(& &1.symbol)

      :no_recording ->
        []
    end
  end

  defp parse_linear_markets(exchange_id) do
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

      {:ok, %Bourse.Market{} = market} ->
        [market]

      {:ok, _} ->
        []

      {:error, reason} ->
        flunk("#{exchange_id} fetch_markets fixture failed to parse: #{inspect(reason)}")
    end
  end

  defp parse_body!(_exchange_id, _body), do: []
end
