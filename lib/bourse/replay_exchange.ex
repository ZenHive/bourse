defmodule Bourse.ReplayExchange do
  @moduledoc """
  Offline replay exchange construction backed by the vendored reference caches.

  Accepted-request reconstruction and focused parser tests need an `Bourse.Exchange`
  whose market and currency caches are already populated, without making a live
  call. This module builds one from the vendored market/currency corpus under
  `static_root/0`.

  The market and currency directories under `priv/reference_cache/` form a vendored
  slice for the venues exercised by the replay harnesses. It is compatibility
  reference material only — it never establishes venue semantics, and no runtime
  path reads it. Keeping its access in one module is what bounds the dependency:
  only recording and replay harnesses reach it, and the slice stays ~1 MB rather
  than the full vendored corpus.

  This slice deliberately cannot be replaced by the manifest-registered response
  recordings. Those recordings preserve provider transport envelopes; replay needs
  normalized compatibility fields such as contract size, precision, asset indexes,
  and currency-network metadata. Deriving those fields would require rerunning the
  reference implementation and would no longer be byte replay. Tracking the slice
  also keeps every replay and recording test available offline from a fresh clone.
  """

  alias Bourse.Credentials
  alias Bourse.Exchange
  alias Bourse.JsonDocument
  alias Bourse.Spec

  @fixture_file_venue %{"binanceusdm" => "binance"}

  @test_credentials [
    api_key: "key",
    secret: "secretsecret",
    password: "password",
    uid: "uid"
  ]

  # Derive (and other secp256k1 DEXes) sign with a real EVM private key. The
  # generic HMAC fixture secret is not valid hex and raises in Base.decode16!
  # before the request can be captured or the response stub returned.
  @dex_test_credentials [
    api_key: "0x0000000000000000000000000000000000000000",
    secret: "0x0123456789012345678901234567890123456789012345678901234567890123",
    password: "password",
    uid: "uid"
  ]

  # Lighter uses a 40-byte API signing key (not an EVM key) plus numeric
  # api_key_index / account_index. These values let offline request reconstruction
  # resolve account_index without using live credentials.
  @lighter_test_credentials [
    api_key: "30",
    secret: "e6b975b33b81e53fb5333bd84553f12b3b5327ce5b1595139f49e8bebf734d9b1b81d3351b487d1b",
    password: "password",
    uid: "715085"
  ]

  @doc "Root for the vendored market and currency reference cache slice."
  @spec static_root() :: String.t()
  def static_root do
    __DIR__
    |> Path.join("../../priv/reference_cache")
    |> Path.expand()
  end

  @doc "Directory for vendored markets caches."
  @spec markets_root() :: String.t()
  def markets_root, do: Path.join(static_root(), "markets")

  @doc "Directory for vendored currencies caches."
  @spec currencies_root() :: String.t()
  def currencies_root, do: Path.join(static_root(), "currencies")

  @doc "Absolute path to a venue's static markets cache."
  @spec markets_fixture_path(String.t()) :: String.t()
  def markets_fixture_path(exchange_id), do: Path.join(markets_root(), "#{fixture_file_id(exchange_id)}.json")

  @doc "Absolute path to a venue's static currencies cache."
  @spec currencies_fixture_path(String.t()) :: String.t()
  def currencies_fixture_path(exchange_id), do: Path.join(currencies_root(), "#{fixture_file_id(exchange_id)}.json")

  @doc "Returns the on-disk fixture filename id for a venue."
  @spec fixture_file_id(String.t()) :: String.t()
  def fixture_file_id(exchange_id) do
    Map.get(@fixture_file_venue, exchange_id, exchange_id)
  end

  @doc """
  Builds an offline replay exchange with fixture case options merged.

  The market and currency reference caches supply cache-derived fields needed
  by accepted-request reconstruction and focused parser tests.

  > #### Raw replay market cache {: .info}
  >
  > `:markets` is populated with raw reference maps. `Bourse.Exchange` declares
  > this replay shape alongside `%Bourse.Market{}` so callers can distinguish the
  > two cache representations.
  """
  @spec build!(String.t(), map(), map()) :: Exchange.t()
  def build!(exchange_id, case_data, file_options \\ %{}) when is_binary(exchange_id) and is_map(case_data) do
    case_options = Map.get(case_data, "options", %{})

    exchange_id
    |> Exchange.new!(credentials: Credentials.new!(test_credentials_for(exchange_id)))
    |> Map.put(:markets, markets_cache!(exchange_id))
    |> Map.put(:currencies, currencies_cache!(exchange_id))
    |> Map.update!(:options, fn opts -> Map.merge(opts, stringify_keys(file_options)) end)
    |> Map.update!(:options, fn opts -> Map.merge(opts, stringify_keys(case_options)) end)
  end

  defp markets_cache!(exchange_id) do
    exchange_id
    |> markets_fixture_path()
    |> cache_document!(exchange_id, "fetchMarkets")
    |> Map.values()
    |> maybe_inject_hyperliquid_asset_index(exchange_id)
  end

  # RequestShape.Hyperliquid reads only explicit asset_index. The reference
  # market cache stores the same integer under baseId, so promote it without
  # overloading identity fields on the live Market path.
  defp maybe_inject_hyperliquid_asset_index(markets, "hyperliquid") when is_list(markets) do
    Enum.map(markets, &inject_hyperliquid_asset_index/1)
  end

  defp maybe_inject_hyperliquid_asset_index(markets, _exchange_id), do: markets

  defp inject_hyperliquid_asset_index(market) when is_map(market) do
    case Map.get(market, "asset_index") || Map.get(market, "assetIndex") do
      idx when is_integer(idx) ->
        Map.put(market, "asset_index", idx)

      idx when is_binary(idx) ->
        case Integer.parse(idx) do
          {int, ""} -> Map.put(market, "asset_index", int)
          _ -> inject_hyperliquid_asset_index_from_base_id(market)
        end

      _ ->
        inject_hyperliquid_asset_index_from_base_id(market)
    end
  end

  defp inject_hyperliquid_asset_index(market), do: market

  defp inject_hyperliquid_asset_index_from_base_id(market) do
    case Map.get(market, "baseId") || Map.get(market, "base_id") do
      idx when is_integer(idx) ->
        Map.put(market, "asset_index", idx)

      idx when is_binary(idx) ->
        case Integer.parse(idx) do
          {int, ""} -> Map.put(market, "asset_index", int)
          _ -> market
        end

      _ ->
        market
    end
  end

  defp currencies_cache!(exchange_id) do
    exchange_id
    |> currencies_fixture_path()
    |> cache_document!(exchange_id, "fetchCurrencies")
  end

  defp cache_document!(path, exchange_id, capability) do
    if File.regular?(path) do
      JsonDocument.decode_file!(path)
    else
      spec = Spec.load!(exchange_id)

      if get_in(spec, ["capabilities", "has", capability]) == false do
        %{}
      else
        JsonDocument.decode_file!(path)
      end
    end
  end

  defp test_credentials_for("derive"), do: @dex_test_credentials
  defp test_credentials_for("hyperliquid"), do: @dex_test_credentials
  defp test_credentials_for("lighter"), do: @lighter_test_credentials
  defp test_credentials_for(_exchange_id), do: @test_credentials

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
