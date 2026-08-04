defmodule Bourse.Signing.ApiKeySecretHeaders do
  @moduledoc """
  API key and secret header authentication without an HMAC signature.
  """

  @behaviour Bourse.Signing.Behaviour

  alias Bourse.Credentials
  alias Bourse.Signing
  alias Bourse.Signing.SignedRequest

  @impl true
  @spec sign(Signing.request(), Credentials.t(), Signing.config()) :: Signing.signed_request()
  def sign(request, credentials, config) do
    %SignedRequest{
      url: signed_url(request),
      method: request.method,
      headers: [
        {Map.fetch!(config, :api_key_header), credentials.api_key},
        {Map.fetch!(config, :secret_header), credentials.secret}
      ],
      body: request.body
    }
  end

  defp signed_url(%{method: method, path: path, params: params}) when method in [:get, :delete] do
    case Signing.urlencode_raw(params) do
      "" -> path
      query -> path <> "?" <> query
    end
  end

  defp signed_url(%{path: path}), do: path
end
