defmodule Bourse.Signing.SignedRequestTest do
  use ExUnit.Case, async: true

  alias Bourse.Signing.SignedRequest

  describe "Inspect redaction" do
    test "masks header values but keeps header names, method, and path visible" do
      request = %SignedRequest{
        url: "https://api.bybit.com/v5/order/create",
        method: :post,
        headers: [
          {"X-BAPI-API-KEY", "live-api-key"},
          {"X-BAPI-SIGN", "hmac-signature-hex"},
          {"Content-Type", "application/json"}
        ],
        body: ~s({"category":"linear","apiKey":"live-api-key"})
      }

      output = inspect(request, limit: :infinity, printable_limit: :infinity)

      refute output =~ "live-api-key"
      refute output =~ "hmac-signature-hex"
      assert output =~ "X-BAPI-API-KEY"
      assert output =~ "X-BAPI-SIGN"
      assert output =~ "https://api.bybit.com/v5/order/create"
      assert output =~ ":post"
      assert output =~ ~s(body: "***")
    end

    test "masks the query string for query-signed requests (Binance pattern)" do
      request = %SignedRequest{
        url: "https://api.binance.com/api/v3/account?timestamp=17&signature=abc123sig",
        method: :get,
        headers: [{"X-MBX-APIKEY", "binance-key"}],
        body: nil
      }

      output = inspect(request, limit: :infinity, printable_limit: :infinity)

      refute output =~ "abc123sig"
      refute output =~ "binance-key"
      assert output =~ "https://api.binance.com/api/v3/account?***"
      assert output =~ "body: nil"
    end
  end
end
