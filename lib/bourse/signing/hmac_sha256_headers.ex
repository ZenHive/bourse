defmodule Bourse.Signing.HmacSha256Headers do
  @moduledoc """
  HMAC-SHA256 headers signing pattern (Bybit-style).

  Used by: Bybit, Bitget, Phemex, Poloniex, and ~30 other exchanges.

  ## How it works

  1. Create payload: `timestamp + apiKey + recvWindow + body_or_query`
  2. Sign with HMAC-SHA256
  3. Add signature and auth headers to request

  ## Configuration

      signing: %{
        pattern: :hmac_sha256_headers,
        api_key_header: "X-BAPI-API-KEY",
        timestamp_header: "X-BAPI-TIMESTAMP",
        signature_header: "X-BAPI-SIGN",
        recv_window_header: "X-BAPI-RECV-WINDOW",
        recv_window: 5000,
        signature_encoding: :hex
      }
  """

  @behaviour Bourse.Signing.Behaviour

  alias Bourse.Credentials
  alias Bourse.Defaults
  alias Bourse.Signing
  alias Bourse.Signing.SignedRequest

  @impl true
  @spec sign(Signing.request(), Credentials.t(), Signing.config()) :: Signing.signed_request()
  def sign(request, credentials, config) do
    timestamp = to_string(Signing.timestamp_ms_from_config(config))
    recv_window = config |> Map.get(:recv_window, Defaults.recv_window_ms()) |> to_string()

    {query_string, body} = build_query_and_body(request)

    payload =
      case request.method do
        method when method in [:get, :delete] ->
          timestamp <> credentials.api_key <> recv_window <> query_string

        _post_or_put ->
          timestamp <> credentials.api_key <> recv_window <> (body || "")
      end

    signature = sign_payload(payload, credentials.secret, config)
    headers = build_headers(credentials, timestamp, signature, recv_window, config)

    url =
      case request.method do
        method when method in [:get, :delete] and query_string != "" ->
          request.path <> "?" <> query_string

        _ ->
          request.path
      end

    %SignedRequest{url: url, method: request.method, headers: headers, body: body}
  end

  defp build_query_and_body(%{params: params, body: body, method: method}) do
    cond do
      method in [:get, :delete] ->
        {Signing.urlencode_raw(params), nil}

      body != nil ->
        {"", body}

      params != %{} ->
        {"", Jason.encode!(params)}

      true ->
        {"", nil}
    end
  end

  defp sign_payload(payload, secret, config) do
    signature_bytes = Signing.hmac_sha256(payload, secret)

    case Map.get(config, :signature_encoding, :hex) do
      :hex -> Signing.encode_hex(signature_bytes)
      :base64 -> Signing.encode_base64(signature_bytes)
    end
  end

  defp build_headers(credentials, timestamp, signature, recv_window, config) do
    api_key_header = Map.get(config, :api_key_header, "X-BAPI-API-KEY")
    timestamp_header = Map.get(config, :timestamp_header, "X-BAPI-TIMESTAMP")
    signature_header = Map.get(config, :signature_header, "X-BAPI-SIGN")

    headers = [
      {api_key_header, credentials.api_key},
      {timestamp_header, timestamp},
      {signature_header, signature},
      {"Content-Type", "application/json"}
    ]

    case Map.get(config, :recv_window_header) do
      nil -> headers
      header_name -> [{header_name, recv_window} | headers]
    end
  end
end
