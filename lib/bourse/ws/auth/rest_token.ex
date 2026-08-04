defmodule Bourse.WS.Auth.RestToken do
  @moduledoc """
  REST Token auth pattern — kraken.

  Similar to `ListenKey` in that the real work happens over REST — the
  adapter calls `privatePostGetWebSocketsToken`, extracts the token from
  the response, and passes it back through `config[:token]` (or an opts
  map; see `Bourse.WS.Auth.build_subscribe_auth/5`) so subscribe frames can
  include `%{"token" => token}`.

  ## Flow

  1. Call REST endpoint from `config[:pre_auth][:endpoint]` → returns
     `%{"result" => %{"token" => "...", "expires" => 900}}`
  2. Connect to WS (no auth frame)
  3. Inject `%{"token" => token}` into each private subscribe frame via
     `Bourse.WS.Auth.build_subscribe_auth(:rest_token, creds, config_with_token, …)`
  4. Token expires (~15 min); adapter refreshes via another REST call

  ## Config

      config = %{
        pre_auth: %{endpoint: "privatePostGetWebSocketsToken"},
        token: "xeAQ/…"  # set by caller after REST round-trip, used for subscribe injection
      }

  ## Returns from `pre_auth/3`

      {:ok, %{endpoint:, credentials:}}
      | {:error, :no_token_endpoint}
  """

  @behaviour Bourse.WS.Auth.Behaviour

  @impl true
  def pre_auth(credentials, config, _opts) do
    case get_in(config, [:pre_auth, :endpoint]) do
      nil -> {:error, :no_token_endpoint}
      endpoint -> {:ok, %{endpoint: endpoint, credentials: credentials}}
    end
  end

  @impl true
  def build_auth_message(_credentials, _config, _opts), do: :no_message

  @impl true
  def handle_auth_response(_response, _state), do: :ok
end
