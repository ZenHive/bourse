# reach:disable-for-this-file behaviour_candidate — modules already implement Bourse.WS.Auth.Behaviour; false positive
defmodule Bourse.WS.Auth.DirectHmacExpiry do
  @moduledoc """
  Direct HMAC Expiry auth pattern — bybit, bitmex, and htx/huobi families.

  Signs `"GET/realtime{expires}"` with HMAC-SHA256, encodes the signature
  as hex (default) or base64, and wraps in an `op: "auth"` frame.

  ## Example Frame (bybit)

      %{
        "op" => "auth",
        "args" => ["apiKey123", 1699999999999, "signature_hex"]
      }

  ## Config

  | Key | Default | Purpose |
  |---|---|---|
  | `:expires_offset_ms` | `10_000` | Window added to current `timestamp_ms` |
  | `:encoding` | `:hex` | `:hex` or `:base64` signature encoding |
  | `:op_field` | `"op"` | Top-level field name (some variants use `"type"`) |
  | `:op_value` | `"auth"` | Top-level field value |
  | `:timestamp_ms_override` | (unset) | Test-only — freezes the clock |
  """

  @behaviour Bourse.WS.Auth.Behaviour

  alias Bourse.Signing

  @default_expires_offset_ms 10_000

  @impl true
  def pre_auth(_credentials, _config, _opts), do: {:ok, %{}}

  @impl true
  def build_auth_message(credentials, config, _opts) do
    api_key = credentials.api_key
    secret = credentials.secret

    expires_offset = Map.get(config, :expires_offset_ms, @default_expires_offset_ms)
    expires = Signing.timestamp_ms_from_config(config) + expires_offset

    payload = "GET/realtime#{expires}"
    signature_raw = Signing.hmac_sha256(payload, secret)

    signature =
      case Map.get(config, :encoding) do
        :base64 -> Signing.encode_base64(signature_raw)
        _ -> Signing.encode_hex(signature_raw)
      end

    op_field = Map.get(config, :op_field, "op")
    op_value = Map.get(config, :op_value, "auth")

    {:ok,
     %{
       op_field => op_value,
       "args" => [api_key, expires, signature]
     }}
  end

  @impl true
  def handle_auth_response(response, _state) do
    cond do
      response["success"] == true ->
        :ok

      is_binary(response["ret_msg"]) and String.contains?(response["ret_msg"], "error") ->
        {:error, {:auth_failed, response["ret_msg"]}}

      true ->
        {:error, {:auth_failed, response}}
    end
  end
end
