defmodule Bourse.WS.Auth.IsoPassphrase do
  @moduledoc """
  ISO Passphrase auth pattern — okx family, kucoin family, bitget.

  Builds a 3-factor login frame: `apiKey`, `passphrase`, and a
  `timestamp+"GET"+"/users/self/verify"` HMAC-SHA256 base64 signature.

  Requires `credentials.password` (the exchange's passphrase). If missing,
  returns `{:error, :passphrase_required}`.

  ## Example Frame (okx)

      %{
        "op" => "login",
        "args" => [
          %{
            "apiKey" => "api_key_here",
            "passphrase" => "passphrase_here",
            "timestamp" => "1699999999",
            "sign" => "base64_signature"
          }
        ]
      }

  ## Config

  | Key | Default | Purpose |
  |---|---|---|
  | `:timestamp_unit` | `:seconds` | `:seconds` or `:milliseconds` |
  | `:op_field` | `"op"` | Top-level field name |
  | `:op_value` | `"login"` | Top-level field value |
  | `:timestamp_ms_override` | (unset) | Test-only — freezes the clock |
  """

  @behaviour Bourse.WS.Auth.Behaviour

  alias Bourse.Signing

  @verify_path "/users/self/verify"

  @impl true
  def pre_auth(_credentials, _config, _opts), do: {:ok, %{}}

  @impl true
  def build_auth_message(credentials, config, _opts) do
    api_key = credentials.api_key
    secret = credentials.secret
    passphrase = credentials.password

    if is_nil(passphrase) do
      {:error, :passphrase_required}
    else
      timestamp =
        case Map.get(config, :timestamp_unit) do
          :milliseconds -> to_string(Signing.timestamp_ms_from_config(config))
          _ -> to_string(Signing.timestamp_seconds_from_config(config))
        end

      payload = timestamp <> "GET" <> @verify_path
      signature_raw = Signing.hmac_sha256(payload, secret)
      signature = Signing.encode_base64(signature_raw)

      op_field = Map.get(config, :op_field, "op")
      op_value = Map.get(config, :op_value, "login")

      {:ok,
       %{
         op_field => op_value,
         "args" => [
           %{
             "apiKey" => api_key,
             "passphrase" => passphrase,
             "timestamp" => timestamp,
             "sign" => signature
           }
         ]
       }}
    end
  end

  @impl true
  def handle_auth_response(response, _state) do
    cond do
      response["event"] == "login" and response["code"] == "0" ->
        :ok

      response["event"] == "error" ->
        {:error, {:auth_failed, response["msg"]}}

      true ->
        {:error, {:auth_failed, response}}
    end
  end
end
