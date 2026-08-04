defmodule Bourse.Signing.HmacSha256Query do
  @moduledoc """
  HMAC-SHA256 query string signing pattern (Binance-style).

  Used by: Binance, MEXC, Huobi, and ~40 other exchanges.

  ## How it works

  1. Add timestamp to query parameters
  2. URL-encode all parameters (sorted alphabetically)
  3. Sign the query string with HMAC-SHA256
  4. Append signature to URL as `&signature=...`
  5. API key sent in header

  ## Configuration

      signing: %{
        pattern: :hmac_sha256_query,
        api_key_header: "X-MBX-APIKEY",
        timestamp_key: "timestamp",
        signature_key: "signature",
        recv_window_key: "recvWindow",
        recv_window: 5000,
        signature_encoding: :hex,
        post_as_json: false
      }

  Optional: set `post_as_json: true` to send POST params as JSON body
  instead of query string (used by some Binance-derivative exchanges).
  """

  @behaviour Bourse.Signing.Behaviour

  alias Bourse.Credentials
  alias Bourse.Defaults
  alias Bourse.Signing
  alias Bourse.Signing.SignedRequest

  @impl true
  @spec sign(Signing.request(), Credentials.t(), Signing.config()) :: Signing.signed_request()
  def sign(request, credentials, config) do
    timestamp_key = Map.get(config, :timestamp_key, "timestamp")
    signature_key = Map.get(config, :signature_key, "signature")

    params = build_params(request.params, timestamp_key, config, Signing.timestamp_ms_from_config(config))
    query_string = Signing.urlencode(params)
    signature = sign_payload(query_string, credentials.secret, config)
    final_query = query_string <> "&" <> signature_key <> "=" <> signature

    {url, body} =
      case request.method do
        method when method in [:get, :delete] ->
          {request.path <> "?" <> final_query, nil}

        _post_or_put ->
          if Map.get(config, :post_as_json, false) do
            {request.path, Jason.encode!(Map.put(params, signature_key, signature))}
          else
            {request.path, final_query}
          end
      end

    headers = build_headers(credentials, config)

    %SignedRequest{url: url, method: request.method, headers: headers, body: body}
  end

  # Builds params with timestamp and optional recvWindow.
  defp build_params(params, timestamp_key, config, timestamp_ms) do
    params
    |> Map.put(timestamp_key, timestamp_ms)
    |> maybe_add_recv_window(config)
  end

  # Adds recvWindow only if configured, auto_recv_window is true, and not already present.
  # Checks both string and atom key variants to prevent duplicate query params.
  defp maybe_add_recv_window(params, config) do
    recv_window_key = Map.get(config, :recv_window_key)
    auto = Map.get(config, :auto_recv_window, false)

    cond do
      is_nil(recv_window_key) -> params
      has_key_any_type?(params, recv_window_key) -> params
      not auto -> params
      true -> Map.put(params, recv_window_key, Map.get(config, :recv_window, Defaults.recv_window_ms()))
    end
  end

  # Checks for a key as both string and atom, since callers may use either.
  # Uses Enum.any? to check all keys converted to string, avoiding String.to_atom.
  defp has_key_any_type?(params, key) when is_binary(key) do
    Map.has_key?(params, key) or Enum.any?(Map.keys(params), fn k -> to_string(k) == key end)
  end

  defp has_key_any_type?(params, key), do: Map.has_key?(params, key)

  defp sign_payload(query_string, secret, config) do
    signature_bytes = Signing.hmac_sha256(query_string, secret)

    case Map.get(config, :signature_encoding, :hex) do
      :hex -> Signing.encode_hex(signature_bytes)
      :base64 -> Signing.encode_base64(signature_bytes)
    end
  end

  defp build_headers(credentials, config) do
    api_key_header = Map.get(config, :api_key_header, "X-MBX-APIKEY")

    [
      {api_key_header, credentials.api_key},
      {"Content-Type", "application/x-www-form-urlencoded"}
    ]
  end
end
