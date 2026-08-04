defmodule Bourse.WS.Auth.Sha384Nonce do
  @moduledoc """
  SHA384 Nonce auth pattern — bitfinex.

  Signs `"AUTH{nonce}"` (nonce = `timestamp_ms`) with HMAC-SHA384 hex and
  builds a flat auth frame — no nested `args`.

  ## Example Frame (bitfinex)

      %{
        "event" => "auth",
        "apiKey" => "api_key",
        "authSig" => "hex_signature",
        "authNonce" => 1699999999999,
        "authPayload" => "AUTH1699999999999"
      }

  ## Config

  | Key | Default | Purpose |
  |---|---|---|
  | `:event_value` | `"auth"` | Top-level event field |
  | `:timestamp_ms_override` | (unset) | Test-only — freezes the nonce |
  """

  @behaviour Bourse.WS.Auth.Behaviour

  alias Bourse.Signing

  @impl true
  def pre_auth(_credentials, _config, _opts), do: {:ok, %{}}

  @impl true
  def build_auth_message(credentials, config, _opts) do
    api_key = credentials.api_key
    secret = credentials.secret

    nonce = Signing.timestamp_ms_from_config(config)
    payload = "AUTH#{nonce}"
    signature = payload |> Signing.hmac_sha384(secret) |> Signing.encode_hex()

    {:ok,
     %{
       "event" => Map.get(config, :event_value, "auth"),
       "apiKey" => api_key,
       "authSig" => signature,
       "authNonce" => nonce,
       "authPayload" => payload
     }}
  end

  @impl true
  def handle_auth_response(response, _state) do
    cond do
      response["event"] == "auth" and response["status"] == "OK" ->
        :ok

      response["event"] == "auth" and response["status"] == "FAILED" ->
        {:error, {:auth_failed, response["msg"]}}

      true ->
        {:error, {:auth_failed, response}}
    end
  end
end
