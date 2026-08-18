defmodule Bourse.LinearContractSizeSweepTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.Spec
  alias Bourse.Unified.ReadParse

  # Venues whose recorded linear (non-option) markets still land `contract_size`
  # nil after parse. The allowlist may only shrink: a newly-nil venue fails
  # the first assertion, and an entry that now populates fails as stale.
  # Empty after the remaining first-class linear recipes were authored; option
  # multipliers stay on OptionQuantity (task 397) and are not this ratchet.
  @known_linear_nil_gaps %{}

  # Missing fetch_markets recordings must be named. Treating them as an empty
  # nil list would let a silent-nil venue skip the sweep.
  @no_fetch_markets_recording %{
    "coinbaseexchange" => "public-only spot (candles + ticker); no linear markets and no fetch_markets recording"
  }

  test "every venue's linear markets are populated or recorded as a known gap" do
    observed = Map.new(Spec.exchanges(), &{&1, linear_nils(&1)})

    missing_recording =
      observed
      |> Enum.filter(fn {venue, result} ->
        result == :no_recording and not Map.has_key?(@no_fetch_markets_recording, venue)
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    assert missing_recording == [],
           "venues with no fetch_markets recording must be listed: #{inspect(missing_recording)}"

    stale_no_recording =
      @no_fetch_markets_recording
      |> Map.keys()
      |> Enum.reject(&(observed[&1] == :no_recording))

    assert stale_no_recording == [],
           "no-recording allowlist is stale: #{inspect(stale_no_recording)}"

    unexpected =
      observed
      |> Enum.reject(fn {_venue, result} -> result == :no_recording end)
      |> Enum.filter(fn {venue, nils} -> nils != [] and not Map.has_key?(@known_linear_nil_gaps, venue) end)
      |> Map.new(fn {venue, nils} -> {venue, Enum.take(nils, 3)} end)

    assert unexpected == %{},
           "linear markets landed contract_size nil without a recorded gap: #{inspect(unexpected)}"

    stale =
      @known_linear_nil_gaps
      |> Map.keys()
      |> Enum.reject(fn venue -> match?([_ | _], observed[venue]) end)

    assert stale == [],
           "known-gap allowlist is stale — these venues now populate linear contract_size: #{inspect(stale)}"
  end

  defp linear_nils(exchange_id) do
    case parse_linear_markets(exchange_id) do
      {:ok, markets} ->
        markets
        |> Enum.filter(&(&1.linear == true and &1.contract == true and &1.option != true and is_nil(&1.contract_size)))
        |> Enum.map(& &1.symbol)

      :no_recording ->
        :no_recording
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
