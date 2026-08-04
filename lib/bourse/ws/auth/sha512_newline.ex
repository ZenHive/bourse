defmodule Bourse.WS.Auth.Sha512Newline do
  @moduledoc """
  SHA512 Newline auth pattern — gate, gateio.

  Signs `"{event}\\n{channel}\\n{req_params_json}\\n{time_s}"` with
  HMAC-SHA512 hex and wraps in a two-level frame (outer envelope +
  inner `payload` map).

  ## Example Frame (gate)

      %{
        "id" => "request_id",
        "time" => 1699999999,
        "channel" => "spot.login",
        "event" => "api",
        "payload" => %{
          "req_id" => "request_id",
          "timestamp" => "1699999999",
          "api_key" => "api_key",
          "signature" => "hex_signature",
          "req_param" => %{}
        }
      }

  ## Config / opts

  | Key | Location | Default | Purpose |
  |---|---|---|---|
  | `:channel` | `config` | `"spot.login"` | Login channel (per-market override) |
  | `:request_id` | `opts` | `to_string(System.unique_integer([:positive]))` | Correlation id |
  | `:timestamp_ms_override` | `config` | (unset) | Test-only — freezes the clock |
  """

  @behaviour Bourse.WS.Auth.Behaviour

  alias Bourse.Signing

  @impl true
  def pre_auth(_credentials, _config, _opts), do: {:ok, %{}}

  @impl true
  def build_auth_message(credentials, config, opts) do
    api_key = credentials.api_key
    secret = credentials.secret

    time = Signing.timestamp_seconds_from_config(config)
    request_id = opts[:request_id] || to_string(System.unique_integer([:positive]))

    channel = Map.get(config, :channel, "spot.login")
    event = "api"
    req_params = %{}
    req_params_json = Jason.encode!(req_params)

    payload = "#{event}\n#{channel}\n#{req_params_json}\n#{time}"
    signature = payload |> Signing.hmac_sha512(secret) |> Signing.encode_hex()

    {:ok,
     %{
       "id" => request_id,
       "time" => time,
       "channel" => channel,
       "event" => event,
       "payload" => %{
         "req_id" => request_id,
         "timestamp" => to_string(time),
         "api_key" => api_key,
         "signature" => signature,
         "req_param" => req_params
       }
     }}
  end

  @impl true
  def handle_auth_response(response, _state) do
    cond do
      response["error"] ->
        {:error, {:auth_failed, response["error"]}}

      is_map(response["result"]) and response["result"]["status"] == "success" ->
        :ok

      # Gate sometimes returns a bare result map without a status field on success.
      is_map(response["result"]) and is_nil(response["result"]["status"]) ->
        :ok

      # result present with a non-success status — surface as auth failure.
      is_map(response["result"]) ->
        {:error, {:auth_failed, response}}

      true ->
        {:error, {:auth_failed, response}}
    end
  end
end
