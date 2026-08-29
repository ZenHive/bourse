defmodule Bourse.HTTP.RetryTest do
  use ExUnit.Case, async: true

  alias Bourse.HTTP.Retry

  @moduletag trace_messages: true

  defp get_request, do: Req.Request.new(method: :get, url: URI.parse("https://example.test/"))
  defp head_request, do: Req.Request.new(method: :head, url: URI.parse("https://example.test/"))
  defp post_request, do: Req.Request.new(method: :post, url: URI.parse("https://example.test/"))

  describe "safe_transient?/2" do
    test "does not retry a 429 that carries no Retry-After" do
      response = Req.Response.new(status: 429)
      refute Retry.safe_transient?(get_request(), response)
      assert is_nil(Req.Response.get_retry_after(response))
    end

    test "retries a 429 that names Retry-After" do
      response =
        [status: 429]
        |> Req.Response.new()
        |> Req.Response.put_header("retry-after", "1")

      assert Retry.safe_transient?(get_request(), response)
      assert Req.Response.get_retry_after(response) == 1_000
    end

    test "retries GET/HEAD 500-class statuses the same as Req safe_transient" do
      for status <- [408, 500, 502, 503, 504] do
        response = Req.Response.new(status: status)
        assert Retry.safe_transient?(get_request(), response)
        assert Retry.safe_transient?(head_request(), response)
        refute Retry.safe_transient?(post_request(), response)
      end
    end

    test "retries GET timeout and connection-refused transport errors" do
      assert Retry.safe_transient?(get_request(), %Req.TransportError{reason: :timeout})
      assert Retry.safe_transient?(get_request(), %Req.TransportError{reason: :econnrefused})
      refute Retry.safe_transient?(post_request(), %Req.TransportError{reason: :timeout})
    end
  end
end
