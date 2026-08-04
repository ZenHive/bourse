defmodule Bourse.Testnet do
  @moduledoc """
  ETS-backed credential registry for integration testing.

  Supports multiple credential sets per exchange for multi-API exchanges
  (e.g., Binance spot vs futures testnets require separate credentials).

  Credentials are registered once at test startup (in `test_helper.exs`),
  then retrieved by generated tests at runtime. ETS with `read_concurrency: true`
  allows lock-free reads from any process; the table is `:protected`, so writes
  serialize through the owning GenServer (no foreign process can mutate or
  overwrite registered credentials).

  Not an application child: only test and recording harnesses use it, so callers
  start it explicitly rather than every consumer paying for it at boot.

  ## Usage

      # In test_helper.exs - start the registry, then register each sandbox
      {:ok, _} = Bourse.Testnet.start_link([])

      Bourse.Testnet.register_all_from_env([
        {:bybit, testnet: true},
        {:binance, testnet: true},
        {:binance, :futures, testnet: true}
      ])

      # In tests - retrieve credentials for specific sandbox
      creds = Bourse.Testnet.creds(:bybit)             # default sandbox
      creds = Bourse.Testnet.creds(:binance, :futures) # futures sandbox

  ## Sandbox Keys

  Multi-API exchanges have different testnets per API section:

  | Sandbox Key | Env Var Infix | Example Hostname           |
  |-------------|---------------|----------------------------|
  | `:default`  | (none)        | testnet.binance.vision     |
  | `:futures`  | `_FUTURES`    | demo-fapi.binance.com      |
  | `:coinm`    | `_COINM`      | demo-dapi.binance.com      |

  ## Env Var Convention

  - `{EXCHANGE}[_{SANDBOX}]_TESTNET_API_KEY`
  - `{EXCHANGE}[_{SANDBOX}]_TESTNET_API_SECRET`
  - `{EXCHANGE}_PASSPHRASE` (if `passphrase: true`)

  OKX is an explicit exception: integration tests use the international demo
  credentials `OKX_INTL_API_KEY`, `OKX_INTL_API_SECRET`, and
  `OKX_INTL_PASSPHRASE` against `www.okx.com`.

  When `:testnet` is true, the `_TEST_` infix is accepted as a silent fallback
  (e.g. `BINANCE_FUTURES_TEST_API_KEY` is treated as an alias for
  `BINANCE_FUTURES_TESTNET_API_KEY`). The canonical `_TESTNET_` name remains
  preferred and is the one surfaced in `creds!/2` error messages.
  """

  use GenServer

  @table :bourse_testnet_registry

  @typedoc "Options for register_from_env/2,3"
  @type register_opts :: [
          testnet: boolean(),
          passphrase: boolean(),
          sandbox: boolean(),
          secret_suffix: String.t()
        ]

  @typedoc "Config entry for register_all_from_env/1"
  @type config_entry ::
          {atom(), register_opts()}
          | {atom(), atom(), register_opts()}

  # =============================================================================
  # Client API
  # =============================================================================

  @doc "Starts the Testnet registry GenServer (owns the ETS table)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register credentials directly.

  Returns `:ok` if credentials validate, `:skipped` if required fields are missing.
  """
  @spec register(atom(), atom() | keyword(), keyword()) :: :ok | :skipped
  def register(exchange, sandbox_key_or_opts, opts \\ [])

  def register(exchange, sandbox_key, opts) when is_atom(exchange) and is_atom(sandbox_key) and is_list(opts) do
    case Bourse.Credentials.new(opts) do
      {:ok, credentials} ->
        GenServer.call(__MODULE__, {:put, {exchange, sandbox_key}, credentials})

      # Absent required fields → :skipped (env vars not set is a normal case)
      {:error, :missing_api_key} ->
        :skipped

      {:error, :missing_secret} ->
        :skipped

      # Malformed input (wrong type, unknown key) is a setup bug — fail loudly
      {:error, reason} ->
        raise ArgumentError,
              "Bourse.Testnet.register/3 got invalid credentials for " <>
                "#{inspect({exchange, sandbox_key})}: #{inspect(reason)}"
    end
  end

  def register(exchange, opts, []) when is_atom(exchange) and is_list(opts) do
    register(exchange, :default, opts)
  end

  @doc """
  Register credentials from environment variables.

  Env var pattern: `{EXCHANGE}[_{SANDBOX}][_TESTNET]_API_KEY|_API_SECRET`.

  ## Options

  - `:testnet` - Include `_TESTNET` in env var names (default: `false`)
  - `:passphrase` - Also load passphrase from `{EXCHANGE}_PASSPHRASE` (default: `false`)
  - `:sandbox` - Value for `credentials.sandbox` (default: value of `:testnet`)
  - `:secret_suffix` - Override secret env var suffix (default: `"API_SECRET"`)

  Returns `:ok` on success, `:skipped` when required env vars are absent.
  """
  @spec register_from_env(atom(), atom() | register_opts(), register_opts()) ::
          :ok | :skipped
  def register_from_env(exchange, sandbox_key_or_opts \\ :default, opts \\ [])

  def register_from_env(exchange, sandbox_key, opts) when is_atom(exchange) and is_atom(sandbox_key) and is_list(opts) do
    case read_env_credentials(exchange, sandbox_key, opts) do
      :skipped -> :skipped
      creds -> register(exchange, sandbox_key, creds)
    end
  end

  def register_from_env(exchange, opts, []) when is_atom(exchange) and is_list(opts) do
    register_from_env(exchange, :default, opts)
  end

  defp read_env_credentials(exchange, sandbox_key, opts) do
    prefix = exchange |> Atom.to_string() |> String.upcase()
    sandbox_infix = sandbox_key_to_infix(sandbox_key)
    testnet = Keyword.get(opts, :testnet, false)
    testnet_parts = if testnet, do: ["_TESTNET", "_TEST"], else: [""]
    secret_suffix = Keyword.get(opts, :secret_suffix, "API_SECRET")
    passphrase_opt = Keyword.get(opts, :passphrase, false)

    {key_var, api_key} = resolve_env(prefix, sandbox_infix, testnet_parts, "API_KEY")
    {secret_var, secret} = resolve_env(prefix, sandbox_infix, testnet_parts, secret_suffix)
    password = if passphrase_opt, do: System.get_env("#{prefix}_PASSPHRASE")

    build_env_credentials(
      %{api_key: api_key, secret: secret, password: password},
      %{
        prefix: prefix,
        key_var: key_var,
        secret_var: secret_var,
        passphrase_opt: passphrase_opt,
        sandbox: Keyword.get(opts, :sandbox, testnet)
      }
    )
  end

  # Resolve an env var by trying each testnet_part in order. Returns
  # `{var_name, value}` where `var_name` is the canonical (first) candidate
  # — used for error/:skipped messaging — and `value` is the first non-nil
  # `System.get_env/1` hit across candidates, or `nil` when none are set.
  defp resolve_env(prefix, sandbox_infix, testnet_parts, suffix) do
    candidates =
      Enum.map(testnet_parts, fn part ->
        "#{prefix}#{sandbox_infix}#{part}_#{suffix}"
      end)

    case Enum.find_value(candidates, &fetch_env/1) do
      nil -> {hd(candidates), nil}
      {_var, value} -> {hd(candidates), value}
    end
  end

  defp fetch_env(var) do
    case System.get_env(var) do
      nil -> nil
      value -> {var, value}
    end
  end

  defp build_env_credentials(%{api_key: nil}, _ctx), do: :skipped
  defp build_env_credentials(%{secret: nil}, _ctx), do: :skipped

  defp build_env_credentials(%{password: nil}, %{passphrase_opt: true} = ctx) do
    raise ArgumentError,
          "Bourse.Testnet: #{ctx.key_var} and #{ctx.secret_var} are set but " <>
            "#{ctx.prefix}_PASSPHRASE is missing. " <>
            "Either set #{ctx.prefix}_PASSPHRASE or omit passphrase: true."
  end

  defp build_env_credentials(%{api_key: k, secret: s, password: p}, %{sandbox: sandbox}) do
    [api_key: k, secret: s, password: p, sandbox: sandbox]
  end

  @doc """
  Register credentials for multiple exchanges from environment variables.

  Returns the list of successfully registered `{exchange, sandbox_key}` tuples.
  """
  @spec register_all_from_env([config_entry()]) :: [{atom(), atom()}]
  def register_all_from_env(configs) when is_list(configs) do
    for config <- configs,
        result = register_config(config),
        result != :skipped do
      result
    end
  end

  defp register_config({exchange, sandbox_key, opts}) when is_atom(exchange) and is_atom(sandbox_key) and is_list(opts) do
    case register_from_env(exchange, sandbox_key, opts) do
      :ok -> {exchange, sandbox_key}
      :skipped -> :skipped
    end
  end

  defp register_config({exchange, opts}) when is_atom(exchange) and is_list(opts) do
    case register_from_env(exchange, :default, opts) do
      :ok -> {exchange, :default}
      :skipped -> :skipped
    end
  end

  @doc """
  Get credentials for an exchange/sandbox. Returns `nil` if unregistered.
  """
  @spec creds(atom(), atom()) :: Bourse.Credentials.t() | nil
  def creds(exchange, sandbox_key \\ :default) when is_atom(exchange) and is_atom(sandbox_key) do
    case :ets.lookup(@table, {exchange, sandbox_key}) do
      [{_key, credentials}] -> credentials
      [] -> nil
    end
  end

  @doc """
  Get credentials or raise `ArgumentError` with a helpful message.
  """
  @spec creds!(atom(), atom()) :: Bourse.Credentials.t()
  def creds!(exchange, sandbox_key \\ :default) when is_atom(exchange) and is_atom(sandbox_key) do
    case creds(exchange, sandbox_key) do
      nil ->
        key_str =
          if sandbox_key == :default, do: "#{exchange}", else: "#{exchange}/#{sandbox_key}"

        prefix = env_var_prefix(exchange, sandbox_key)

        raise ArgumentError,
              "No credentials registered for #{key_str}. " <>
                "Set #{prefix}_API_KEY and #{prefix}_API_SECRET."

      credentials ->
        credentials
    end
  end

  @doc "Returns `true` when credentials are registered for the given exchange/sandbox."
  @spec registered?(atom(), atom()) :: boolean()
  def registered?(exchange, sandbox_key \\ :default) when is_atom(exchange) and is_atom(sandbox_key) do
    :ets.member(@table, {exchange, sandbox_key})
  end

  @doc """
  Removes the credentials registered for a single `{exchange, sandbox_key}`.

  Returns `:ok` whether or not an entry existed. Unlike direct `:ets.delete/2`,
  this serializes through the owning GenServer, so it is the correct way to
  clean up a single registration from a foreign process (e.g. an ExUnit
  `on_exit` callback, which runs outside the test process). Use this instead of
  `clear/0` when concurrent (`async: true`) tests share the registry and a
  full wipe would clobber their registrations.
  """
  @spec unregister(atom(), atom()) :: :ok
  def unregister(exchange, sandbox_key \\ :default) when is_atom(exchange) and is_atom(sandbox_key) do
    GenServer.call(__MODULE__, {:delete, {exchange, sandbox_key}})
  end

  @doc "Clears all registered credentials (for test isolation)."
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc "List all registered `{exchange, sandbox_key}` tuples."
  @spec registered_exchanges() :: [{atom(), atom()}]
  def registered_exchanges do
    :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])
  end

  @doc "List unique exchange atoms with any registered credentials."
  @spec exchanges_with_creds() :: [atom()]
  def exchanges_with_creds do
    registered_exchanges()
    |> Enum.map(fn {exchange, _sandbox_key} -> exchange end)
    |> Enum.uniq()
  end

  # =============================================================================
  # Sandbox Key Detection
  # =============================================================================

  @doc """
  Derive sandbox_key from a sandbox URL's hostname/path.

  ## Examples

      iex> Bourse.Testnet.sandbox_key_from_url("https://testnet.binance.vision/api/v3")
      :default

      iex> Bourse.Testnet.sandbox_key_from_url("https://demo-fapi.binance.com/fapi/v1")
      :futures

      iex> Bourse.Testnet.sandbox_key_from_url("https://demo-dapi.binance.com/dapi/v1")
      :coinm
  """
  @spec sandbox_key_from_url(String.t() | nil) :: atom()
  def sandbox_key_from_url(nil), do: :default

  def sandbox_key_from_url(url) when is_binary(url) do
    uri = URI.parse(url)
    host = uri.host || ""
    path = uri.path || ""

    cond do
      String.contains?(path, "/dapi") -> :coinm
      String.contains?(path, "/fapi") or String.contains?(host, "future") -> :futures
      true -> :default
    end
  end

  @doc """
  Env var prefix for a given exchange + sandbox combination.

  ## Examples

      iex> Bourse.Testnet.env_var_prefix(:binance, :default)
      "BINANCE_TESTNET"

      iex> Bourse.Testnet.env_var_prefix(:binance, :futures)
      "BINANCE_FUTURES_TESTNET"
  """
  @spec env_var_prefix(atom(), atom()) :: String.t()
  def env_var_prefix(exchange, sandbox_key) do
    prefix = exchange |> Atom.to_string() |> String.upcase()
    infix = sandbox_key_to_infix(sandbox_key)
    "#{prefix}#{infix}_TESTNET"
  end

  defp sandbox_key_to_infix(:default), do: ""
  defp sandbox_key_to_infix(:futures), do: "_FUTURES"
  defp sandbox_key_to_infix(:coinm), do: "_COINM"

  defp sandbox_key_to_infix(key) when is_atom(key), do: "_" <> (key |> Atom.to_string() |> String.upcase())

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, key, credentials}, _from, state) do
    :ets.insert(@table, {key, credentials})
    {:reply, :ok, state}
  end

  def handle_call({:delete, key}, _from, state) do
    :ets.delete(@table, key)
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end
end
