defmodule Bourse.WS.Auth.JsonrpcLinebreak do
  @moduledoc """
  JSON-RPC Linebreak auth pattern — deribit.

  Signs `"{timestamp_ms}\\n{nonce}\\n"` with HMAC-SHA256 hex and wraps the
  signature in a JSON-RPC 2.0 `public/auth` frame with
  `grant_type: "client_signature"`.

  `handle_auth_response/2` extracts `result.expires_in` (seconds) and returns
  `{:ok, %{ttl_ms: N}}` so the adapter can schedule re-auth via
  `Bourse.WS.Auth.Expiry`.

  ## Example Frame (deribit)

      %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "public/auth",
        "params" => %{
          "grant_type" => "client_signature",
          "client_id" => "api_key",
          "timestamp" => 1699999999999,
          "signature" => "hex_signature",
          "nonce" => "1699999999999",
          "data" => ""
        }
      }

  ## Config / opts

  | Key | Location | Default | Purpose |
  |---|---|---|---|
  | `:method_value` | `config` | `"public/auth"` | RPC method override |
  | `:nonce` | `opts` | `to_string(timestamp)` | Explicit nonce |
  | `:request_id` | `opts` | `System.unique_integer([:positive])` | RPC `id` |
  | `:timestamp_ms_override` | `config` | (unset) | Test-only — freezes the clock |
  | `:nonce_override` | `config` | (unset) | Test-only — freezes the nonce |
  """

  @behaviour Bourse.WS.Auth.Behaviour

  alias Bourse.Signing

  @impl true
  def pre_auth(_credentials, _config, _opts), do: {:ok, %{}}

  @impl true
  def build_auth_message(credentials, config, opts) do
    api_key = credentials.api_key
    secret = credentials.secret

    timestamp = Signing.timestamp_ms_from_config(config)

    nonce =
      case opts[:nonce] do
        nil -> to_string(Signing.nonce_from_config(config, fn -> timestamp end))
        explicit -> to_string(explicit)
      end

    payload = "#{timestamp}\n#{nonce}\n"
    signature = payload |> Signing.hmac_sha256(secret) |> Signing.encode_hex()

    request_id = opts[:request_id] || System.unique_integer([:positive])

    {:ok,
     %{
       "jsonrpc" => "2.0",
       "id" => request_id,
       "method" => Map.get(config, :method_value, "public/auth"),
       "params" => %{
         "grant_type" => "client_signature",
         "client_id" => api_key,
         "timestamp" => timestamp,
         "signature" => signature,
         "nonce" => nonce,
         "data" => ""
       }
     }}
  end

  @impl true
  def handle_auth_response(response, _state) do
    cond do
      response["result"] && response["result"]["access_token"] ->
        case parse_expires_in(response["result"]["expires_in"]) do
          ttl_ms when is_integer(ttl_ms) and ttl_ms > 0 -> {:ok, %{ttl_ms: ttl_ms}}
          _ -> :ok
        end

      response["error"] ->
        {:error, {:auth_failed, response["error"]}}

      true ->
        {:error, {:auth_failed, response}}
    end
  end

  @ms_per_second 1_000

  # Parses deribit's `expires_in` (seconds) into milliseconds.
  # Accepts integer or numeric string; returns `nil` otherwise.
  defp parse_expires_in(seconds) when is_integer(seconds), do: seconds * @ms_per_second

  defp parse_expires_in(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {value, ""} -> value * @ms_per_second
      _ -> nil
    end
  end

  defp parse_expires_in(_), do: nil
end
