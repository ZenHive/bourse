defmodule Bourse.OptionReadiness.Credentials do
  @moduledoc """
  Credential and environment resolution for the four option readiness venues.

  Missing credentials fail loudly with exact setup instructions. Bybit uses
  demo-trading keys (not the read-only testnet key); OKX uses international
  demo credentials against `www.okx.com`.
  """

  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.Exchange

  @derive_subaccount_id 144_422
  @bybit_demo_url "https://api-demo.bybit.com"

  @type resolved :: {Exchange.t(), String.t(), keyword()}

  @doc "Default environment label for a venue."
  @spec default_environment(String.t()) :: String.t()
  def default_environment("deribit"), do: "deribit-testnet"
  def default_environment("okx"), do: "okx-international-demo"
  def default_environment("bybit"), do: "bybit-demo"
  def default_environment("derive"), do: "derive-demo"
  def default_environment(other), do: other

  @doc "Default per-call request opts (e.g. Bybit demo base_url)."
  @spec default_request_opts(String.t()) :: keyword()
  def default_request_opts("bybit"), do: [base_url: @bybit_demo_url]
  def default_request_opts(_venue), do: []

  @doc "Builds a sandbox/demo exchange or returns a loud missing-credentials error."
  @spec build_exchange(String.t()) :: {:ok, Exchange.t(), String.t(), keyword()} | {:error, Error.t()}
  def build_exchange(venue) when is_binary(venue) do
    with {:ok, credentials} <- load_credentials(venue),
         {:ok, exchange} <- new_exchange(venue, credentials) do
      {:ok, exchange, default_environment(venue), default_request_opts(venue)}
    end
  end

  @doc "Exact setup instructions for a venue's option readiness credentials."
  @spec setup_instructions(String.t()) :: String.t()
  def setup_instructions("deribit") do
    """
    Missing Deribit testnet credentials for option readiness.

      export DERIBIT_TESTNET_API_KEY="your_key"
      export DERIBIT_TESTNET_API_SECRET="your_secret"

    Create keys at: https://test.deribit.com
    Exchange is built with sandbox: true → test.deribit.com
    """
  end

  def setup_instructions("okx") do
    """
    Missing OKX international demo credentials for option readiness.

      export OKX_INTL_API_KEY="your_key"
      export OKX_INTL_API_SECRET="your_secret"
      export OKX_INTL_PASSPHRASE="your_passphrase"

    Host: www.okx.com with sandbox: true (x-simulated-trading: 1).
    Do not use OKX_TESTNET_* or my.okx.com for option work.
    """
  end

  def setup_instructions("bybit") do
    """
    Missing Bybit DEMO-trading credentials for option readiness.
    The testnet key is read-only (business error 10024) and is not option evidence.

      export BYBIT_DEMO_API_KEY="your_demo_api_key"
      export BYBIT_DEMO_API_SECRET="your_demo_api_secret"

    Create a demo-trading key from a bybit.com account (Demo Trading):
      https://www.bybit.com/app/user/api-management
    Calls must pass base_url: "https://api-demo.bybit.com"
    """
  end

  def setup_instructions("derive") do
    """
    Missing Derive testnet credentials for option readiness.

      export DERIVE_TESTNET_API_KEY="your_derive_wallet"
      export DERIVE_TESTNET_API_SECRET="your_session_key_private_key"

    API key is the Derive smart-contract wallet (X-LyraWallet), secret is a
    registered Admin session key. Host: api-demo.lyra.finance (sandbox: true).
    Docs: https://docs.derive.xyz/
    """
  end

  def setup_instructions(venue) do
    "Missing credentials for unknown option readiness venue #{venue}"
  end

  defp load_credentials("deribit") do
    require_pair("DERIBIT_TESTNET_API_KEY", "DERIBIT_TESTNET_API_SECRET", "deribit")
  end

  defp load_credentials("okx") do
    with api_key when is_binary(api_key) and api_key != "" <- System.get_env("OKX_INTL_API_KEY"),
         secret when is_binary(secret) and secret != "" <- System.get_env("OKX_INTL_API_SECRET"),
         password when is_binary(password) and password != "" <- System.get_env("OKX_INTL_PASSPHRASE") do
      {:ok, Credentials.new!(api_key: api_key, secret: secret, password: password)}
    else
      _missing -> {:error, missing_error("okx")}
    end
  end

  defp load_credentials("bybit") do
    require_pair("BYBIT_DEMO_API_KEY", "BYBIT_DEMO_API_SECRET", "bybit")
  end

  defp load_credentials("derive") do
    require_pair("DERIVE_TESTNET_API_KEY", "DERIVE_TESTNET_API_SECRET", "derive")
  end

  defp load_credentials(venue) do
    {:error, Error.exception(type: :invalid_parameters, message: "unknown venue #{venue}")}
  end

  defp require_pair(key_var, secret_var, venue) do
    api_key = System.get_env(key_var)
    secret = System.get_env(secret_var)

    if present?(api_key) and present?(secret) do
      {:ok, Credentials.new!(api_key: api_key, secret: secret)}
    else
      {:error, missing_error(venue)}
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp missing_error(venue) do
    Error.exception(type: :authentication_error, message: String.trim(setup_instructions(venue)))
  end

  defp new_exchange("deribit", credentials) do
    Exchange.new("deribit", credentials: credentials, sandbox: true)
  end

  defp new_exchange("okx", credentials) do
    Exchange.new("okx", credentials: credentials, sandbox: true)
  end

  defp new_exchange("bybit", credentials) do
    # Demo host is not sandbox: true; request opts carry base_url.
    Exchange.new("bybit", credentials: credentials)
  end

  defp new_exchange("derive", credentials) do
    Exchange.new("derive",
      credentials: credentials,
      sandbox: true,
      options: %{"subaccount_id" => @derive_subaccount_id}
    )
  end
end
