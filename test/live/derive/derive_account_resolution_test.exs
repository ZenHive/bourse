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
    assert DeriveAccount.resolve(@empty_wallet) == {:error, {:no_subaccount, @empty_wallet}}
  end

  test "the owner wallet resolves to an account state, not a lookup failure" do
    wallet = System.get_env("DERIVE_TESTNET_API_KEY")

    case DeriveAccount.resolve(wallet) do
      {:ok, id} ->
        assert id > 0
        assert DeriveAccount.id!() == id
        assert Bourse.Testnet.creds(:derive).uid == Integer.to_string(id)

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
