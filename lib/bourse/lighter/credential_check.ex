defmodule Bourse.Lighter.CredentialCheck do
  @moduledoc """
  Confronts a Lighter credential triple with what the venue actually has registered.

  Lighter answers every private read with `20013 "invalid auth: couldnt find
  account"` when the signing key is not registered **at the configured
  `api_key_index` on the configured `account_index`**. The message names the
  account, so the error reads as "the account is gone" when the account is alive
  and funded and only the index is wrong. That misreading has a standing cost:
  the remedy it suggests is `mix bourse.provision_lighter`, which mints a *new*
  key at a *new* index and so invalidates the index every other machine is
  configured with — which produces the same 20013 there, and another
  re-provision. Account 153 carries keys at indices 0 and 10 from two such
  rounds.

  This check answers the question the venue's error does not: is a key
  registered at the index we are configured for, and if not, which indices are
  occupied. It reads two public endpoints and needs no credentials, no
  signature, and no Go toolchain, so every consumer of this library can run it.

  `run/1` is the whole surface. It returns `:ok`, or `{:error, message}` whose
  message is written to be actionable without further investigation.
  """

  @testnet_url "https://testnet.zklighter.elliot.ai"
  @mainnet_url "https://mainnet.zklighter.elliot.ai"

  # The venue lists every registered key when asked for this index, which is
  # outside the valid 0..254 range a key can occupy.
  @list_all_index 255

  @type registered_key :: %{index: non_neg_integer(), public_key: String.t()}

  @type option ::
          {:account_index, non_neg_integer() | String.t()}
          | {:api_key_index, non_neg_integer() | String.t()}
          | {:public_key, String.t() | nil}
          | {:base_url, String.t()}
          | {:sandbox, boolean()}
          | {:receive_timeout, pos_integer()}

  @doc """
  Checks the configured Lighter credential triple against the venue.

  Options: `:account_index` and `:api_key_index` (default to
  `LIGHTER_TESTNET_ACCOUNT_INDEX` / `LIGHTER_TESTNET_API_KEY_INDEX`),
  `:public_key` (the 80-hex zk public key the configured private key derives —
  when given, the check also proves the *key* matches, not just that the slot is
  filled), `:sandbox` (default `true`) or an explicit `:base_url`.
  """
  @spec run([option()]) :: :ok | {:error, String.t()}
  def run(opts \\ []) do
    with {:ok, account_index} <- index(opts, :account_index, "LIGHTER_TESTNET_ACCOUNT_INDEX"),
         {:ok, api_key_index} <- index(opts, :api_key_index, "LIGHTER_TESTNET_API_KEY_INDEX"),
         {:ok, keys} <- registered_keys(base_url(opts), account_index, opts) do
      classify(keys, account_index, api_key_index, public_key(opts))
    end
  end

  @doc """
  Reports where a zk public key is registered on an account, if anywhere.

  `mix bourse.provision_lighter` uses this to refuse to mint a second key for a
  wallet that already has one — the mint is what invalidates every other
  machine's `LIGHTER_TESTNET_API_KEY_INDEX`, so refusing it is what stops the
  re-provisioning loop.
  """
  @spec locate(String.t(), [option()]) ::
          {:ok, non_neg_integer()} | {:error, :not_registered} | {:error, String.t()}
  def locate(public_key, opts \\ []) when is_binary(public_key) do
    with {:ok, account_index} <- index(opts, :account_index, "LIGHTER_TESTNET_ACCOUNT_INDEX"),
         {:ok, keys} <- registered_keys(base_url(opts), account_index, opts) do
      expected = normalize(public_key)

      case Enum.find(keys, &(&1.public_key == expected)) do
        nil -> {:error, :not_registered}
        key -> {:ok, key.index}
      end
    end
  end

  @doc """
  Classifies a configured index pair against the keys an account actually carries.

  Separated from the request so the verdict — which is the part that has to be
  right, because its message is what stops the re-provisioning loop — can be
  exercised over every shape without inventing accounts at the venue. `keys` is
  what `run/1` reads from the venue: one entry per occupied slot, as
  `%{index: non_neg_integer(), public_key: String.t()}`.
  """
  @spec classify([registered_key()], non_neg_integer(), non_neg_integer(), String.t() | nil) ::
          :ok | {:error, String.t()}
  def classify(keys, account_index, api_key_index, public_key \\ nil) do
    case {Enum.find(keys, &(&1.index == api_key_index)), public_key} do
      {nil, _any} -> {:error, empty_slot_message(keys, account_index, api_key_index)}
      {_key, nil} -> :ok
      {key, expected} -> compare_key(key, expected, keys, account_index, api_key_index)
    end
  end

  defp compare_key(key, expected, keys, account_index, api_key_index) do
    expected = normalize(expected)

    cond do
      key.public_key == expected ->
        :ok

      elsewhere = Enum.find(keys, &(&1.public_key == expected)) ->
        {:error, wrong_index_message(account_index, api_key_index, elsewhere.index)}

      true ->
        {:error, foreign_key_message(account_index, api_key_index)}
    end
  end

  @doc """
  The refusal `mix bourse.provision_lighter` prints when the wallet already has a key.

  Kept here rather than in the task because this sentence is the loop-breaker:
  it has to say why a second key is worse than the symptom that prompted it.
  """
  @spec provision_refusal_message(non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          String.t()
  def provision_refusal_message(account_index, registered_index, configured_index) do
    """
    Refusing to provision: LIGHTER_TESTNET_API_PRIVATE_KEY is ALREADY registered
    on account_index #{account_index}, at api_key_index #{registered_index}.

    Provisioning again would mint a second key at a different index and break
    every machine still configured with #{registered_index} — that is the
    re-provisioning loop this guard exists to stop, not a fresh problem to solve.

    #{index_advice(registered_index, configured_index)}

    Change ~/.secrets on every machine that runs this suite, the harness server
    included; its copy is not visible from here.
    """
  end

  defp index_advice(index, index), do: "The configuration already names that index; nothing to change."

  defp index_advice(index, configured_index) do
    """
    The configuration names api_key_index #{configured_index}, which is the wrong
    slot. Point it at the registered one:

            export LIGHTER_TESTNET_API_KEY_INDEX=#{index}
    """
  end

  defp empty_slot_message(keys, account_index, api_key_index) do
    """
    Lighter api_key_index #{api_key_index} is EMPTY on account_index #{account_index}.

    Every private Lighter read will answer 20013 "invalid auth: couldnt find
    account". That message names the account, but the account is not the problem
    — the index is. #{occupied_text(keys)}

    Do NOT run `mix bourse.provision_lighter` to fix this. Provisioning mints a
    new key at a new index and moves the problem to every other machine that is
    configured with the current one. Point the configuration at the registered
    index, or at the account the registered key belongs to:

        export LIGHTER_TESTNET_API_KEY_INDEX=<the registered index above>
        export LIGHTER_TESTNET_ACCOUNT_INDEX=<the account that key is on>

    Both values live in ~/.secrets and must match on every machine that runs
    this suite — including the harness server, whose stale copy is invisible
    from here.

    #{stale_env_note()}
    """
  end

  # A long-lived shell — an agent session in particular — keeps whatever the
  # variables held when it started, and the process environment WINS over
  # ~/.secrets. So a machine whose ~/.secrets is already correct still runs
  # against the old account until the session is restarted, and editing
  # ~/.secrets again does nothing for it. This is the same drift as a stale
  # file, but it is invisible in the file, so it has to be named here.
  defp stale_env_note do
    """
    If ~/.secrets already looks right, this process is probably carrying a stale
    export from before it was fixed. Compare what this process sees against what
    a fresh login shell sees:

        echo "$LIGHTER_TESTNET_ACCOUNT_INDEX"
        zsh -l -c 'echo $LIGHTER_TESTNET_ACCOUNT_INDEX'

    If they differ, restart the session (or re-export) — the file is not the
    problem.
    """
  end

  defp wrong_index_message(account_index, api_key_index, actual_index) do
    """
    The configured Lighter signing key IS registered on account_index
    #{account_index}, but at api_key_index #{actual_index}, not the configured
    #{api_key_index}.

    Nothing is missing and nothing needs provisioning — the configuration points
    at the wrong slot:

        export LIGHTER_TESTNET_API_KEY_INDEX=#{actual_index}

    Update ~/.secrets on every machine that runs this suite, the harness server
    included.
    """
  end

  defp foreign_key_message(account_index, api_key_index) do
    """
    A key is registered at Lighter api_key_index #{api_key_index} on
    account_index #{account_index}, but it is NOT the key that
    LIGHTER_TESTNET_API_PRIVATE_KEY derives.

    Private reads will answer 20013 "invalid auth: couldnt find account". Either
    the private key or the account index is from a different wallet — check
    whether LIGHTER_TESTNET_ACCOUNT_INDEX still names the account this key was
    registered on before provisioning anything. Provisioning mints a new key at
    a new index and invalidates every other machine's configuration.

    #{stale_env_note()}
    """
  end

  defp occupied_text([]), do: "No key is registered on this account at all."

  defp occupied_text(keys) do
    indices = keys |> Enum.map(& &1.index) |> Enum.sort() |> Enum.join(", ")
    "Registered indices on this account: #{indices}."
  end

  defp registered_keys(base_url, account_index, opts) do
    url =
      "#{base_url}/api/v1/apikeys?account_index=#{account_index}&api_key_index=#{@list_all_index}"

    case get_json(url, opts) do
      {:ok, %{"api_keys" => keys}} when is_list(keys) -> {:ok, parse_keys(keys)}
      {:ok, body} -> {:error, "Lighter did not list api keys for account_index #{account_index}: #{inspect(body)}"}
      {:error, reason} -> {:error, "Could not reach Lighter at #{base_url}: #{inspect(reason)}"}
    end
  end

  defp parse_keys(keys) do
    for %{"api_key_index" => index, "public_key" => public_key} <- keys,
        registered?(public_key),
        do: %{index: index, public_key: normalize(public_key)}
  end

  # An unused slot is reported as an all-zero public key rather than omitted.
  defp registered?(public_key) when is_binary(public_key), do: String.trim(public_key, "0") != ""

  defp registered?(_public_key), do: false

  defp normalize(public_key) when is_binary(public_key) do
    public_key |> String.trim() |> String.trim_leading("0x") |> String.downcase()
  end

  defp public_key(opts), do: Keyword.get(opts, :public_key)

  defp base_url(opts) do
    cond do
      url = Keyword.get(opts, :base_url) -> url
      Keyword.get(opts, :sandbox, true) -> @testnet_url
      true -> @mainnet_url
    end
  end

  defp index(opts, key, env_var) do
    opts
    |> Keyword.get(key)
    |> case do
      nil -> System.get_env(env_var)
      value -> value
    end
    |> parse_index(env_var)
  end

  defp parse_index(value, _env_var) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_index(value, env_var) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {index, ""} when index >= 0 -> {:ok, index}
      _other -> {:error, "#{env_var} is #{inspect(value)}; expected a non-negative integer"}
    end
  end

  defp parse_index(_value, env_var), do: {:error, "#{env_var} is not set"}

  defp get_json(url, opts) do
    receive_timeout = Keyword.get(opts, :receive_timeout, 15_000)

    case Req.get(url, receive_timeout: receive_timeout, retry: false) do
      {:ok, %Req.Response{body: body}} when is_map(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
