defmodule Bourse.Live.Derive.AccountResolutionTest do
  @moduledoc """
  The v3 subaccount lookup `test_helper.exs` runs, against the testnet host:
  an empty wallet must classify as `:no_subaccount`, never as a lookup failure,
  and the configured owner wallet must classify as one of the two account states.
  """
  use ExUnit.Case, async: true

  alias Bourse.Test.DeriveAccount

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_derive

  # An address no one can hold a key for; it never owns a Derive account.
  @empty_wallet "0x0000000000000000000000000000000000000001"

  test "an unfunded wallet answers an empty subaccount list" do
    assert DeriveAccount.resolve(@empty_wallet, nil) == {:error, {:no_subaccount, @empty_wallet}}
  end

  test "the owner wallet resolves to an account state, not a lookup failure" do
    wallet = System.get_env("DERIVE_TESTNET_API_KEY")

    case DeriveAccount.resolve(wallet, System.get_env("DERIVE_TESTNET_API_SECRET")) do
      {:ok, id} ->
        assert id > 0
        assert DeriveAccount.id!() == id
        assert Bourse.Testnet.creds(:derive).uid == Integer.to_string(id)

        # A first deposit also creates an empty fallback subaccount in universe 0;
        # the resolved one must sit in the universe where the lanes' perp trades.
        {:ok, public} = Bourse.Exchange.new("derive", sandbox: true)
        {:ok, exchange} = Bourse.Exchange.new("derive", credentials: Bourse.Testnet.creds(:derive), sandbox: true)

        assert {:ok, %{body: %{"result" => %{"risk_universe_id" => universe}}}} =
                 Bourse.Derive.public_post_get_instrument(public, %{"instrument_name" => "BTC-PERP"})

        assert {:ok, %{body: %{"result" => %{"risk_universe_id" => ^universe, "subaccount_id" => ^id} = subaccount}}} =
                 Bourse.Derive.private_post_get_subaccount(exchange, %{"subaccount_id" => id})

        # v3 changed `currency` from one string to the list of collateral
        # currencies the subaccount accepts (OpenAPI `Subaccount.currency: string[]`).
        assert [_ | _] = currencies = subaccount["currency"]
        assert Enum.all?(currencies, &is_binary/1)
        assert "USDC" in currencies

      {:error, {:no_subaccount, ^wallet}} = verdict ->
        assert DeriveAccount.verdict() == verdict
        assert Bourse.Testnet.creds(:derive).uid == nil
        assert DeriveAccount.setup_message() =~ "testnet.app.derive.xyz"

      other ->
        flunk(DeriveAccount.setup_message(other))
    end
  end

  test "an uncallable envelope is a lookup failure, not an empty wallet" do
    assert {:error, {:lookup_failed, {:error, :timeout}}} = DeriveAccount.classify({:error, :timeout}, @empty_wallet)
    assert {:error, {:lookup_failed, _}} = DeriveAccount.classify({:ok, %{status: 200, body: %{}}}, @empty_wallet)
  end
end
