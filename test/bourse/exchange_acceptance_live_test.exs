defmodule Bourse.ExchangeAcceptanceLiveTest do
  use ExUnit.Case, async: false

  alias Bourse.ExchangeAcceptanceFixtures

  @moduletag :dangerous
  @moduletag :network

  @credential_env_names ~w(
    ALPACA_API_KEY
    ALPACA_API_SECRET
    BINANCE_TESTNET_API_KEY
    BINANCE_TESTNET_API_SECRET
    BINANCE_FUTURES_TEST_API_KEY
    BINANCE_FUTURES_TEST_API_SECRET
    BYBIT_DEMO_API_KEY
    BYBIT_DEMO_API_SECRET
    DERIBIT_TESTNET_API_KEY
    DERIBIT_TESTNET_API_SECRET
    OKX_INTL_API_KEY
    OKX_INTL_API_SECRET
    OKX_INTL_PASSPHRASE
    HYPERLIQUID_TESTNET_API_KEY
    HYPERLIQUID_TESTNET_API_SECRET
    LIGHTER_TESTNET_API_KEY_INDEX
    LIGHTER_TESTNET_ACCOUNT_INDEX
    LIGHTER_TESTNET_API_PRIVATE_KEY
    DERIVE_TESTNET_API_KEY
    DERIVE_TESTNET_API_SECRET
  )

  test "every configured signed profile earns a live accepted request" do
    require_credentials!()

    for venue <- ExchangeAcceptanceFixtures.authenticated_venues() do
      assert {:ok, goldens} = ExchangeAcceptanceFixtures.record_all(venue)
      assert goldens != []

      for %{"acceptance" => %{"venue" => ^venue, "http_status" => status}} <- goldens do
        assert status in 200..299
      end
    end
  end

  test "a venue rejection cannot become accepted-request evidence" do
    variables = ~w(BINANCE_TESTNET_API_KEY BINANCE_TESTNET_API_SECRET)
    previous = Map.new(variables, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)
    end)

    System.put_env("BINANCE_TESTNET_API_KEY", "invalid-key")
    System.put_env("BINANCE_TESTNET_API_SECRET", "invalid-secret")

    assert {:error, {:fetch_balance, {:live_call_failed, type, code}}} =
             ExchangeAcceptanceFixtures.record_all("binance")

    assert type in [:authentication_error, :permission_denied]
    refute code in [nil, ""]
  end

  defp require_credentials! do
    missing = Enum.reject(@credential_env_names, &present?/1)

    if missing != [] do
      flunk("""
      Missing exchange-acceptance credentials: #{Enum.join(missing, ", ")}

      Set every variable named above from the venue testnet/demo credentials
      documented in CLAUDE.md, then rerun this live acceptance test.
      """)
    end
  end

  defp present?(name) do
    case System.get_env(name) do
      value when is_binary(value) -> String.trim(value) != ""
      nil -> false
    end
  end
end
