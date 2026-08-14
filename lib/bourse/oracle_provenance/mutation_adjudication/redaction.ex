defmodule Bourse.OracleProvenance.MutationAdjudication.Redaction do
  @moduledoc """
  Redacts credential material carried by raw provider-operation requests.

  `Bourse.RecordedResponseFixtures.safety_violations/1` masks sensitive *map
  keys*, so it cannot see a credential that travels as the value of a
  `%{"name" => ..., "value" => ...}` header pair — which is exactly how a signed
  Deribit request carries its api key, signature and nonce. This module closes
  that shape: it masks the value of every sensitive header, records which header
  names were masked so the evidence still shows the request was authenticated,
  and reports any capture that still carries an unmasked one.
  """

  @mask "***REDACTED***"
  @sensitive_headers ~w(authorization cookie proxy-authorization set-cookie x-api-key x-api-secret)

  @doc "Returns the mask written in place of credential material."
  @spec mask() :: String.t()
  def mask, do: @mask

  @doc "Returns the header names whose values are credential material."
  @spec sensitive_headers() :: [String.t()]
  def sensitive_headers, do: @sensitive_headers

  @doc """
  Masks every sensitive header value in a raw request and records what was masked.

      iex> alias Bourse.OracleProvenance.MutationAdjudication.Redaction
      iex> Redaction.redact_request(%{
      ...>   "method" => "GET",
      ...>   "headers" => [%{"name" => "authorization", "value" => "deri-hmac-sha256 id=k,sig=s"}]
      ...> })
      %{
        "method" => "GET",
        "headers" => [%{"name" => "authorization", "value" => "***REDACTED***"}],
        "redacted_headers" => ["authorization"]
      }
  """
  @spec redact_request(map()) :: map()
  def redact_request(%{"headers" => headers} = request) when is_list(headers) do
    redacted = Enum.map(headers, &redact_header/1)

    names =
      headers
      |> Enum.flat_map(fn
        %{"name" => name} -> [normalize(name)]
        _other -> []
      end)
      |> Enum.filter(&(&1 in @sensitive_headers))
      |> Enum.uniq()
      |> Enum.sort()

    request
    |> Map.put("headers", redacted)
    |> Map.put("redacted_headers", names)
  end

  def redact_request(request) when is_map(request), do: Map.put(request, "redacted_headers", [])

  @doc """
  Returns the JSON paths of header values that still carry unmasked credential material.

      iex> alias Bourse.OracleProvenance.MutationAdjudication.Redaction
      iex> Redaction.violations(%{"request" => %{"headers" => [%{"name" => "Authorization", "value" => "secret"}]}})
      ["$.request.headers[0]"]
  """
  @spec violations(term()) :: [String.t()]
  def violations(value), do: value |> find(value_path()) |> Enum.sort()

  defp value_path, do: "$"

  defp redact_header(%{"name" => name, "value" => _value} = header) do
    if normalize(name) in @sensitive_headers, do: Map.put(header, "value", @mask), else: header
  end

  defp redact_header(header), do: header

  defp find(%{"name" => name, "value" => value} = header, path) when is_binary(name) do
    if normalize(name) in @sensitive_headers and value != @mask do
      [path]
    else
      find_children(header, path)
    end
  end

  defp find(map, path) when is_map(map), do: find_children(map, path)

  defp find(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> find(item, "#{path}[#{index}]") end)
  end

  defp find(_value, _path), do: []

  defp find_children(map, path) do
    Enum.flat_map(map, fn {key, value} -> find(value, "#{path}.#{key}") end)
  end

  defp normalize(name) when is_binary(name), do: String.downcase(name)
  defp normalize(_name), do: ""
end
