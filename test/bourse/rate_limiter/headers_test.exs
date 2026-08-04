defmodule Bourse.RateLimiter.HeadersTest do
  use ExUnit.Case, async: true

  alias Bourse.RateLimiter.Headers
  alias Bourse.RateLimiter.Info

  describe "parse/3 — Binance pattern" do
    test "parses x-mbx-used-weight-1m header" do
      headers = %{"x-mbx-used-weight-1m" => ["800"]}
      # Binance spec rate_limit_ms = 50 → 60_000/50 = 1200 req/min
      assert {:ok, %Info{} = info} = Headers.parse("binance", headers, 50)
      assert info.exchange == "binance"
      assert info.used == 800
      assert info.limit == 1200
      assert info.remaining == 400
      assert info.axis == "ip"
      assert info.source == :binance_weight
      assert info.raw_headers["matched"] == "x-mbx-used-weight-1m"
    end

    test "parses x-sapi-used-ip-weight-1m header" do
      headers = %{"x-sapi-used-ip-weight-1m" => ["500"]}

      assert {:ok, %Info{} = info} = Headers.parse("binance", headers, 50)
      assert info.used == 500
      assert info.remaining == 700
      assert info.axis == "ip"
      assert info.source == :binance_weight
    end

    test "parses x-mbx-order-count-1m as order-weight bucket" do
      headers = %{"x-mbx-order-count-1m" => ["23"]}

      assert {:ok, %Info{} = info} = Headers.parse("binance", headers, 50)
      assert info.used == 23
      assert info.axis == "order_weight"
      assert info.source == :binance_order_count
      assert info.raw_headers["matched"] == "x-mbx-order-count-1m"
    end

    test "handles float rate_limit_ms values without crashing" do
      headers = %{"x-mbx-used-weight-1m" => ["300"]}

      # OKX-like float: 110.00000000000001 → trunc(60_000/110.0) = 545
      assert {:ok, %Info{} = info} = Headers.parse("binance", headers, 110.00000000000001)
      assert info.limit == 545
      assert info.remaining == 245

      # KuCoin-like float: 7.5 → trunc(60_000/7.5) = 8000
      assert {:ok, %Info{} = info} = Headers.parse("binance", headers, 7.5)
      assert info.limit == 8000
      assert info.remaining == 7700
    end

    test "limit is nil when spec_rate_limit not provided" do
      headers = %{"x-mbx-used-weight-1m" => ["800"]}

      assert {:ok, %Info{} = info} = Headers.parse("binance", headers)
      assert info.used == 800
      assert info.limit == nil
      assert info.remaining == nil
    end
  end

  describe "parse/3 — Bybit pattern" do
    test "parses x-bapi-* headers" do
      headers = %{
        "x-bapi-limit" => ["120"],
        "x-bapi-limit-status" => ["80"],
        "x-bapi-limit-reset-timestamp" => ["1700000000000"]
      }

      assert {:ok, %Info{} = info} = Headers.parse("bybit", headers)
      assert info.exchange == "bybit"
      assert info.limit == 120
      assert info.remaining == 80
      assert info.used == 40
      assert info.reset_at == 1_700_000_000_000
      assert info.source == :bybit_bapi
    end

    test "handles partial Bybit headers" do
      headers = %{"x-bapi-limit" => ["120"]}

      assert {:ok, %Info{} = info} = Headers.parse("bybit", headers)
      assert info.limit == 120
      assert info.remaining == nil
      assert info.used == nil
    end
  end

  describe "parse/3 — Standard pattern" do
    test "parses x-ratelimit-* headers" do
      headers = %{
        "x-ratelimit-limit" => ["100"],
        "x-ratelimit-remaining" => ["75"],
        "x-ratelimit-reset" => ["1700000000"]
      }

      assert {:ok, %Info{} = info} = Headers.parse("kucoin", headers)
      assert info.exchange == "kucoin"
      assert info.limit == 100
      assert info.remaining == 75
      assert info.used == 25
      # Seconds converted to ms
      assert info.reset_at == 1_700_000_000_000
      assert info.source == :standard
    end
  end

  describe "parse/3 — no match" do
    test "returns :none for unknown headers" do
      headers = %{"content-type" => ["application/json"]}
      assert :none = Headers.parse("okx", headers)
    end

    test "returns :none for empty headers" do
      assert :none = Headers.parse("okx", %{})
    end
  end

  describe "parse/3 — priority" do
    test "Binance pattern takes priority over standard" do
      headers = %{
        "x-mbx-used-weight-1m" => ["800"],
        "x-ratelimit-limit" => ["100"]
      }

      assert {:ok, %Info{source: :binance_weight}} = Headers.parse("binance", headers, 50)
    end
  end
end
