defmodule Bourse.Test.DeriveAccount do
  @moduledoc """
  Resolves the Derive v3 testnet subaccount once per run from the owner wallet.

  v3 numbers subaccounts itself and creates the first one on an L1 deposit, so the
  id is read from `public/get_subaccounts` instead of being configured. The
  verdict is resolved in `test_helper.exs`, the id rides on the registered
  credential's `uid`, and every test reads it from there — one value, never a
  shell export that may be left over from an earlier testnet account.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @verdict_key {__MODULE__, :verdict}

  @type verdict ::
          {:ok, pos_integer()}
          | {:error, :no_wallet}
          | {:error, {:no_subaccount, String.t()}}
          | {:error, {:lookup_failed, term()}}

  @doc "Reads the wallet's subaccounts from the testnet and classifies the answer."
  @spec resolve(String.t() | nil) :: verdict()
  def resolve(wallet) when wallet in [nil, ""], do: {:error, :no_wallet}

  def resolve(wallet) when is_binary(wallet) do
    case Bourse.Exchange.new("derive", sandbox: true) do
      {:ok, exchange} ->
        exchange
        |> Bourse.Derive.public_post_get_subaccounts(%{"wallet" => wallet})
        |> classify(wallet)

      other ->
        {:error, {:lookup_failed, other}}
    end
  end

  @doc false
  @spec classify(term(), String.t()) :: verdict()
  def classify({:ok, %{status: 200, body: %{"result" => %{"subaccount_ids" => [id | _]}}}}, _wallet)
      when is_integer(id) and id > 0, do: {:ok, id}

  def classify({:ok, %{status: 200, body: %{"result" => %{"subaccount_ids" => []}}}}, wallet),
    do: {:error, {:no_subaccount, wallet}}

  def classify(other, _wallet), do: {:error, {:lookup_failed, other}}

  @doc "Stores the run's verdict for `id!/0` and `setup_message/0`."
  @spec put_verdict(verdict()) :: :ok
  def put_verdict(verdict), do: :persistent_term.put(@verdict_key, verdict)

  @doc "The run's verdict; `{:error, {:lookup_failed, :not_resolved}}` before `test_helper.exs` ran."
  @spec verdict() :: verdict()
  def verdict, do: :persistent_term.get(@verdict_key, {:error, {:lookup_failed, :not_resolved}})

  @doc "The resolved subaccount id, or a flunk carrying the operator step."
  @spec id!() :: pos_integer()
  def id! do
    case verdict() do
      {:ok, id} -> id
      _error -> flunk(setup_message())
    end
  end

  @doc "Operator-facing text for the current verdict."
  @spec setup_message() :: String.t()
  def setup_message, do: setup_message(verdict())

  @spec setup_message(verdict()) :: String.t()
  def setup_message({:ok, id}), do: "Derive v3 testnet subaccount #{id} resolved from the owner wallet."

  def setup_message({:error, :no_wallet}) do
    """
    DERIVE_TESTNET_API_KEY is not set. Export the Derive owner wallet address as
    DERIVE_TESTNET_API_KEY and its private key, or a session key it registered, as
    DERIVE_TESTNET_API_SECRET.
    """
  end

  def setup_message({:error, {:no_subaccount, wallet}}) do
    """
    The Derive owner wallet #{wallet} owns no v3 testnet subaccount
    (public/get_subaccounts answered subaccount_ids: []). v3 creates the account and
    its first subaccount on an L1 deposit; there is no private/create_subaccount.
    Operator step: on https://testnet.app.derive.xyz connect that wallet, fund it with
    Sepolia ETH for gas, mint testnet USDC and deposit it. Then register a session key
    with private/set_session_key or export the owner key as DERIVE_TESTNET_API_SECRET.
    """
  end

  def setup_message({:error, {:lookup_failed, other}}) do
    """
    The Derive subaccount lookup (public/get_subaccounts on the v3 testnet) failed, so
    no account id is known: #{inspect(other, limit: 8)}
    This is a lookup failure, not an empty wallet: check the testnet host before
    provisioning anything.
    """
  end
end
