defmodule Bourse.HTTP.Retry do
  @moduledoc """
  Req retry predicate for Bourse HTTP.

  Same GET/HEAD safe-transient surface as Req's `:safe_transient`, except an
  HTTP 429 without `Retry-After` is not retried. OKX answers 429 with no
  retry-after (body code `50011`); Req would otherwise spend four exponential
  backoff attempts (~7s) instead of returning the venue's informative error.
  A 429 that names `Retry-After` is still retried, and that header drives the delay.
  """

  @transient_statuses [408, 500, 502, 503, 504]
  @transient_transport_reasons [:timeout, :econnrefused, :closed]
  @transient_http2_reasons [:unprocessed, :pool_not_available]

  @doc """
  Returns whether Req should retry this GET/HEAD response or transport error.
  """
  @spec safe_transient?(Req.Request.t(), Req.Response.t() | Exception.t()) :: boolean()
  def safe_transient?(request, response_or_exception) do
    request.method in [:get, :head] and retry_response?(response_or_exception)
  end

  @spec retry_response?(Req.Response.t() | Exception.t()) :: boolean()
  defp retry_response?(%Req.Response{status: 429} = response) do
    not is_nil(Req.Response.get_retry_after(response))
  end

  defp retry_response?(%Req.Response{status: status}) when status in @transient_statuses, do: true

  defp retry_response?(%Req.TransportError{reason: reason}) when reason in @transient_transport_reasons do
    true
  end

  defp retry_response?(%Req.HTTPError{protocol: :http2, reason: reason}) when reason in @transient_http2_reasons do
    true
  end

  defp retry_response?(_response_or_exception), do: false
end
