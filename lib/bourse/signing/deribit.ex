defmodule Bourse.Signing.Deribit do
  @moduledoc """
  Deribit-style HMAC-SHA256 signing with custom Authorization header.

  ## How it works

  1. Generate timestamp (ms) and nonce (ms)
  2. Build request data: `METHOD\\npath?query\\nbody\\n`
  3. Build auth string: `timestamp\\nnonce\\nrequest_data`
  4. Sign with HMAC-SHA256 (hex encoded)
  5. Set Authorization: `deri-hmac-sha256 id={key},ts={ts},sig={sig},nonce={nonce}`

  ## Configuration

      signing: %{pattern: :deribit}

  No additional configuration needed — format is fixed.
  """

  @behaviour Bourse.Signing.Behaviour

  alias Bourse.Credentials
  alias Bourse.Signing
  alias Bourse.Signing.SignedRequest

  @impl true
  @spec sign(Signing.request(), Credentials.t(), Signing.config()) :: Signing.signed_request()
  def sign(request, credentials, config) do
    timestamp = to_string(Signing.timestamp_ms_from_config(config))

    nonce =
      to_string(
        Signing.nonce_from_config(config, fn ->
          :erlang.unique_integer([:positive, :monotonic])
        end)
      )

    query_string = encode_query(request.params, config[:query_encoder] || "urlencode")

    path_with_query =
      if query_string == "", do: request.path, else: request.path <> "?" <> query_string

    method_upper = request.method |> to_string() |> String.upcase()
    body = request.body || ""
    request_data = "#{method_upper}\n#{path_with_query}\n#{body}\n"
    auth = "#{timestamp}\n#{nonce}\n#{request_data}"

    signature =
      auth
      |> Signing.hmac_sha256(credentials.secret)
      |> Signing.encode_hex()

    auth_header =
      "deri-hmac-sha256 id=#{credentials.api_key},ts=#{timestamp},sig=#{signature},nonce=#{nonce}"

    %SignedRequest{
      url: path_with_query,
      method: request.method,
      headers: [{"Authorization", auth_header}],
      body: request.body
    }
  end

  defp encode_query(params, "urlencode"), do: Signing.urlencode(params)

  defp encode_query(_params, encoder) do
    raise ArgumentError, "unsupported Deribit query encoder #{inspect(encoder)}"
  end
end
