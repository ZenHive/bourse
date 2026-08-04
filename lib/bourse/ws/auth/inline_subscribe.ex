defmodule Bourse.WS.Auth.InlineSubscribe do
  @moduledoc """
  Inline Subscribe auth pattern — coinbaseexchange.

  Auth data is attached to each private subscribe frame rather than sent
  as a standalone auth message. `build_auth_message/3` therefore returns
  `:no_message`; the per-subscribe fields come from `build_subscribe_auth/4`.

  ## Payload format

      timestamp_seconds <> "GET" <> "/users/self/verify"

  The secret is base64-decoded before HMAC-SHA256 and the signature is
  base64-encoded. `credentials.password` (passphrase) is included when set.

  ## Example Subscribe with Auth (coinbase)

      %{
        "type" => "subscribe",
        "product_ids" => ["BTC-USD"],
        "channels" => ["level2"],
        "key" => "api_key_here",
        "timestamp" => "1699999999",
        "signature" => "base64_signature",
        "passphrase" => "my_passphrase"
      }
  """

  @behaviour Bourse.WS.Auth.Behaviour

  alias Bourse.Signing

  @verify_path "/users/self/verify"

  @impl true
  def pre_auth(_credentials, _config, _opts), do: {:ok, %{}}

  @impl true
  def build_auth_message(_credentials, _config, _opts), do: :no_message

  @impl true
  def handle_auth_response(_response, _state), do: :ok

  @impl true
  def build_subscribe_auth(credentials, config, _channel, _symbols) do
    api_key = credentials.api_key
    secret = credentials.secret
    passphrase = credentials.password

    timestamp = to_string(Signing.timestamp_seconds_from_config(config))
    payload = timestamp <> "GET" <> @verify_path

    # Coinbase delivers its secret as base64; decode before signing.
    secret_binary = Signing.decode_base64(secret)
    signature = payload |> Signing.hmac_sha256(secret_binary) |> Signing.encode_base64()

    result = %{
      "key" => api_key,
      "timestamp" => timestamp,
      "signature" => signature
    }

    if passphrase, do: Map.put(result, "passphrase", passphrase), else: result
  end
end
