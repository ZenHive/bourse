defmodule Bourse.Signing.HmacSha256Iso do
  @moduledoc """
  HMAC-SHA256 with ISO timestamp and passphrase (OKX-style).

  Used by: OKX, Coinbase, and ~10 other exchanges.

  ## How it works

  1. Create ISO8601 timestamp
  2. Build payload: `timestamp + METHOD + path + body`
  3. Sign with HMAC-SHA256, encode as Base64
  4. Send signature, API key, timestamp, and passphrase in headers

  ## Configuration

      signing: %{
        pattern: :hmac_sha256_iso_passphrase,
        api_key_header: "OK-ACCESS-KEY",
        timestamp_header: "OK-ACCESS-TIMESTAMP",
        signature_header: "OK-ACCESS-SIGN",
        passphrase_header: "OK-ACCESS-PASSPHRASE",
        signature_encoding: :base64
      }
  """

  @behaviour Bourse.Signing.Behaviour

  alias Bourse.Credentials
  alias Bourse.Signing
  alias Bourse.Signing.SignedRequest

  @impl true
  @spec sign(Signing.request(), Credentials.t(), Signing.config()) :: Signing.signed_request()
  def sign(request, credentials, config) do
    timestamp = Signing.timestamp_iso8601_from_config(config)
    method_string = request.method |> Atom.to_string() |> String.upcase()

    {path, body} = build_path_and_body(request)
    payload = timestamp <> method_string <> path <> (body || "")
    signature = sign_payload(payload, credentials.secret, config)
    headers = build_headers(credentials, timestamp, signature, config, request.method)

    %SignedRequest{url: path, method: request.method, headers: headers, body: body}
  end

  defp build_path_and_body(%{method: method, path: path, params: params, body: body}) do
    cond do
      method in [:get, :delete] and params != %{} ->
        {path <> "?" <> Signing.urlencode(params), nil}

      method in [:get, :delete] ->
        {path, nil}

      body != nil ->
        {path, body}

      params != %{} ->
        {path, Jason.encode!(params)}

      true ->
        {path, nil}
    end
  end

  defp sign_payload(payload, secret, config) do
    signature_bytes = Signing.hmac_sha256(payload, secret)

    case Map.get(config, :signature_encoding, :base64) do
      :hex -> Signing.encode_hex(signature_bytes)
      :base64 -> Signing.encode_base64(signature_bytes)
    end
  end

  defp build_headers(credentials, timestamp, signature, config, method) do
    api_key_header = Map.get(config, :api_key_header, "OK-ACCESS-KEY")
    timestamp_header = Map.get(config, :timestamp_header, "OK-ACCESS-TIMESTAMP")
    signature_header = Map.get(config, :signature_header, "OK-ACCESS-SIGN")
    passphrase_header = Map.get(config, :passphrase_header, "OK-ACCESS-PASSPHRASE")

    base = [
      {api_key_header, credentials.api_key},
      {timestamp_header, timestamp},
      {signature_header, signature},
      {passphrase_header, credentials.password || ""}
    ]

    if method in [:get, :delete], do: base, else: base ++ [{"Content-Type", "application/json"}]
  end
end
