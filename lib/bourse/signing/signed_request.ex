defmodule Bourse.Signing.SignedRequest do
  @moduledoc """
  The signed, transport-ready request a signing pattern returns.

  This is the output half of the `Bourse.Signing.Behaviour` contract. `:url` is
  absolute, and credentials may live in `:url`, `:headers`, or `:body` depending
  on the venue's scheme — which is why this struct has a custom `Inspect`
  implementation that redacts them.
  """

  alias Bourse.Signing.Request

  @type t :: %__MODULE__{
          url: String.t(),
          method: Request.method(),
          headers: [{String.t(), String.t()}],
          body: String.t() | nil
        }

  @enforce_keys [:url, :method, :headers]
  defstruct [:url, :method, :headers, :body]

  defimpl Inspect do
    import Inspect.Algebra

    # A signed request is replayable within the exchange's recv_window: header
    # values carry API keys/signatures, query-signed exchanges (e.g. Binance)
    # embed the signature in the URL query string, and body-signed exchanges
    # embed it in the body — mask all three, keep names/method/path visible.
    def inspect(request, opts) do
      fields = [
        url: redact_query(request.url),
        method: request.method,
        headers: Enum.map(request.headers, fn {name, _value} -> {name, "***"} end),
        body: redact(request.body)
      ]

      container_doc("#Bourse.Signing.SignedRequest<", fields, ">", opts, fn {key, value}, opts ->
        concat("#{key}: ", to_doc(value, opts))
      end)
    end

    defp redact_query(url) do
      case String.split(url, "?", parts: 2) do
        [base] -> base
        [base, _query] -> base <> "?***"
      end
    end

    defp redact(nil), do: nil
    defp redact(body) when is_binary(body), do: "***"
  end
end
