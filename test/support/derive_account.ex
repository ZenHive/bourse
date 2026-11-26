defmodule Bourse.Test.DeriveAccount do
  @moduledoc """
  Resolves the Derive v3 testnet subaccount once per run from the owner wallet.

  v3 numbers subaccounts itself and creates the first one on an L1 deposit, so the
  id is read from `public/get_subaccounts` instead of being configured. The
  verdict is resolved in `test_helper.exs`, the id rides on the registered
  credential's `uid`, and every test reads it from there — one value, never a
  shell export that may be left over from an earlier testnet account.

  A wallet's first deposit creates two subaccounts: the funded one and an empty
  fallback under manager 0 in risk universe 0, where no instrument trades. The
  lanes trade `BTC-PERP`, so the subaccount is the one whose risk universe is
  that instrument's, read from the venue rather than assumed from list order.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @verdict_key {__MODULE__, :verdict}
  @instrument "BTC-PERP"

  @type verdict ::
          {:ok, pos_integer()}
          | {:error, :no_wallet}
          | {:error, {:no_subaccount, String.t()}}
          | {:error, {:no_trading_subaccount, String.t(), non_neg_integer(), [pos_integer()]}}
          | {:error, {:lookup_failed, term()}}

  @doc """
  Reads the wallet's subaccounts from the testnet and picks the one in the risk
  universe of `#{@instrument}`. The private subaccount read needs the wallet's key.
  """
  @spec resolve(String.t() | nil, String.t() | nil) :: verdict()
  def resolve(wallet, _secret) when wallet in [nil, ""], do: {:error, :no_wallet}

  def resolve(wallet, secret) when is_binary(wallet) do
    case Bourse.Exchange.new("derive", sandbox: true) do
      {:ok, public} ->
        public
        |> Bourse.Derive.public_post_get_subaccounts(%{"wallet" => wallet})
        |> classify(wallet)
        |> select_trading(public, wallet, secret)

      other ->
        {:error, {:lookup_failed, other}}
    end
  end

  defp select_trading({:ok, ids}, public, wallet, secret) do
    with {:ok, universe} <- instrument_universe(public),
         {:ok, exchange} <- private_exchange(wallet, secret),
         {:ok, universes} <- subaccount_universes(exchange, ids) do
      case Enum.find(ids, &(Map.fetch!(universes, &1) == universe)) do
        nil -> {:error, {:no_trading_subaccount, wallet, universe, ids}}
        id -> {:ok, id}
      end
    end
  end

  defp select_trading(error, _public, _wallet, _secret), do: error

  defp instrument_universe(public) do
    case Bourse.Derive.public_post_get_instrument(public, %{"instrument_name" => @instrument}) do
      {:ok, %{body: %{"result" => %{"risk_universe_id" => universe}}}} when is_integer(universe) -> {:ok, universe}
      other -> {:error, {:lookup_failed, other}}
    end
  end

  defp private_exchange(wallet, secret) do
    with {:ok, creds} <- Bourse.Credentials.new(api_key: wallet, secret: secret),
         {:ok, exchange} <- Bourse.Exchange.new("derive", credentials: creds, sandbox: true) do
      {:ok, exchange}
    else
      other -> {:error, {:lookup_failed, other}}
    end
  end

  defp subaccount_universes(exchange, ids) do
    Enum.reduce_while(ids, {:ok, %{}}, fn id, {:ok, acc} ->
      case Bourse.Derive.private_post_get_subaccount(exchange, %{"subaccount_id" => id}) do
        {:ok, %{body: %{"result" => %{"risk_universe_id" => universe}}}} when is_integer(universe) ->
          {:cont, {:ok, Map.put(acc, id, universe)}}

        other ->
          {:halt, {:error, {:lookup_failed, other}}}
      end
    end)
  end

  @doc false
  @spec classify(term(), String.t()) ::
          {:ok, [pos_integer()]} | {:error, {:no_subaccount, String.t()}} | {:error, {:lookup_failed, term()}}
  def classify({:ok, %{status: 200, body: %{"result" => %{"subaccount_ids" => [_ | _] = ids}}}}, wallet) do
    if Enum.all?(ids, &(is_integer(&1) and &1 > 0)),
      do: {:ok, ids},
      else: {:error, {:lookup_failed, {:malformed_ids, wallet, ids}}}
  end

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

  def setup_message({:error, {:no_trading_subaccount, wallet, universe, ids}}) do
    """
    The Derive owner wallet #{wallet} owns subaccounts #{inspect(ids)}, but none is in
    risk universe #{universe}, where #{@instrument} trades (a first deposit also creates an
    empty fallback subaccount in universe 0). Operator step: deposit USDC into a new
    subaccount under that universe's standard-margin manager (public/get_risk_universes
    names it) through the testnet ACTION_MANAGER or https://testnet.app.derive.xyz.
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
