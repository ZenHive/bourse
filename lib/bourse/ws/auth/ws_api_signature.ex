defmodule Bourse.WS.Auth.WsApiSignature do
  @moduledoc """
  Signed WebSocket-API request that opens binance's spot user data stream.

  Binance removed the spot and margin listen key endpoints on 2026-02-20 —
  `POST /api/v3/userDataStream` answers HTTP 410 Gone (observed on
  `testnet.binance.vision` 2026-08-06). The replacement is a request on the
  WebSocket API host: `userDataStream.subscribe.signature`, carrying the API
  key, a timestamp and an HMAC-SHA256 signature over the sorted parameters.

  The venue offers a second route — `session.logon` followed by an unsigned
  `userDataStream.subscribe` — but that one requires Ed25519 keys, which this
  client's credentials are not. The signature variant is the HMAC path and
  needs no session of its own.

  ## The frame both authenticates and subscribes

  There is no separate channel to subscribe to afterwards: the accepted request
  *is* the user data stream. That is why it runs as the private section's
  handshake — `Bourse.WS.connect/3` returning an accepted socket means the
  stream is live. Verified differentially against
  `ws-api.testnet.binance.vision` 2026-08-06: with the request sent, an order
  placed on the same account produced `executionReport` and
  `outboundAccountPosition`; on a connection that skipped it, the identical
  order produced nothing.

  ## Response

      %{"id" => "…", "status" => 200, "result" => %{"subscriptionId" => 0}}

  Any other `status` is the venue's rejection and carries `error.msg`.
  """

  @behaviour Bourse.WS.Auth.Behaviour

  alias Bourse.Credentials
  alias Bourse.Signing

  @default_method "userDataStream.subscribe.signature"

  @impl true
  def pre_auth(_credentials, _config, _opts), do: {:ok, %{}}

  @impl true
  def build_auth_message(%Credentials{} = credentials, config, opts) do
    api_key = credentials.api_key
    secret = credentials.secret

    if is_binary(api_key) and is_binary(secret) do
      params = %{
        "apiKey" => api_key,
        "timestamp" => opts[:timestamp_ms] || Signing.timestamp_ms()
      }

      {:ok,
       %{
         "id" => to_string(opts[:request_id] || Signing.timestamp_ms()),
         "method" => Map.get(config, :method, @default_method),
         "params" => Map.put(params, "signature", sign(params, secret))
       }}
    else
      {:error, :missing_credentials}
    end
  end

  def build_auth_message(_credentials, _config, _opts), do: {:error, :missing_credentials}

  # Binance signs the parameters sorted by name and joined as a query string —
  # the same rule as its REST surface, minus the transport.
  defp sign(params, secret) do
    params
    |> Enum.sort_by(fn {name, _value} -> name end)
    |> Enum.map_join("&", fn {name, value} -> "#{name}=#{value}" end)
    |> Signing.hmac_sha256(secret)
    |> Signing.encode_hex()
  end

  @impl true
  def handle_auth_response(%{"status" => 200}, _state), do: :ok

  def handle_auth_response(%{"error" => %{"msg" => msg}}, _state), do: {:error, {:auth_failed, msg}}

  def handle_auth_response(%{"status" => status}, _state), do: {:error, {:auth_failed, status}}

  def handle_auth_response(response, _state), do: {:error, {:auth_failed, response}}
end
