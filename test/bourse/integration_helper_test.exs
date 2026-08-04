defmodule Bourse.IntegrationHelperTest do
  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper
  import ExUnit.CaptureLog

  alias Bourse.Credentials
  alias Bourse.Error, as: CError

  @registered_test_exchange :__integration_helper_registered_test__
  @missing_test_exchange :__integration_helper_missing_test__

  describe "require_credentials!/2" do
    test "returns creds when registered" do
      Bourse.Testnet.register(@registered_test_exchange, api_key: "k", secret: "s")

      assert %Credentials{api_key: "k", secret: "s"} =
               require_credentials!(@registered_test_exchange)
    end

    test "flunks with actionable env var instructions when missing" do
      msg =
        try do
          require_credentials!(@missing_test_exchange)
        rescue
          e in ExUnit.AssertionError -> e.message
        end

      assert msg =~ "Missing testnet credentials"
      assert msg =~ "__INTEGRATION_HELPER_MISSING_TEST___TESTNET_API_KEY"
      assert msg =~ "__INTEGRATION_HELPER_MISSING_TEST___TESTNET_API_SECRET"
    end

    test "includes passphrase line when opts say so" do
      msg = Bourse.IntegrationHelper.missing_credentials_message(:okx, :default, passphrase: true)
      assert msg =~ "OKX_PASSPHRASE"
    end

    test "includes sandbox infix for non-default slot" do
      msg = Bourse.IntegrationHelper.missing_credentials_message(:binance, :futures)
      assert msg =~ "BINANCE_FUTURES_TESTNET_API_KEY"
    end
  end

  describe "build_exchange/2" do
    test "returns Exchange struct with sandbox: true when requested" do
      exchange = build_exchange(:bybit, sandbox: true)
      assert exchange.id == "bybit"
      assert exchange.sandbox == true
    end

    test "attaches credentials when passed" do
      creds = %Credentials{api_key: "k", secret: "s"}
      exchange = build_exchange(:bybit, credentials: creds, sandbox: true)
      assert %Credentials{api_key: "k", secret: "s"} = exchange.credentials
    end

    test "preserves credentials.sandbox (exchange and creds stay consistent)" do
      creds = %Credentials{api_key: "k", secret: "s", sandbox: true}
      exchange = build_exchange(:bybit, credentials: creds)
      assert exchange.sandbox == true
      assert exchange.credentials.sandbox == true
    end
  end

  describe "assert_public_response/3" do
    test "passes on 2xx raw response with valid shape" do
      body = %{"lastPrice" => "67000"}
      assert :ok = assert_public_response(:fetch_ticker, {:ok, %{status: 200, body: body}})
    end

    test "unwraps nested result envelope" do
      body = %{"result" => %{"lastPrice" => "67000"}}
      assert :ok = assert_public_response(:fetch_ticker, {:ok, %{status: 200, body: body}})
    end

    test "passes on parsed struct path" do
      struct = %Bourse.Ticker{symbol: "BTC/USDT"}
      assert :ok = assert_public_response(:fetch_ticker, {:ok, struct})
    end

    test "rate_limit_exceeded is inconclusive (warns, returns :ok)" do
      err = %CError{type: :rate_limit_exceeded, message: "too fast"}

      log =
        capture_log(fn ->
          assert :ok = assert_public_response(:fetch_ticker, {:error, err})
        end)

      assert log =~ "INCONCLUSIVE"
    end

    test "network_error is inconclusive" do
      err = %CError{type: :network_error, message: "timeout"}
      assert :ok = assert_public_response(:fetch_ticker, {:error, err})
    end

    # Task 82: CF challenge is infrastructure, not a code bug — inconclusive.
    test "cloudflare_challenge is inconclusive on public path" do
      err = %CError{type: :cloudflare_challenge, message: "Just a moment..."}
      assert :ok = assert_public_response(:fetch_ticker, {:error, err})
    end

    # Task 82: non-CF HTML (wrong URL, landing pages) must flunk so T80 canary
    # remains intact. Only CF challenges are inconclusive on the public path.
    test "access_restricted flunks on public path (T80 canary)" do
      err = %CError{type: :access_restricted, message: "Received HTML 'Not Found'"}

      assert_raise ExUnit.AssertionError, ~r/failed with Bourse error/, fn ->
        assert_public_response(:fetch_ticker, {:error, err})
      end
    end

    test "exchange_error flunks" do
      err = %CError{type: :exchange_error, message: "bad request"}

      assert_raise ExUnit.AssertionError, ~r/failed with Bourse error/, fn ->
        assert_public_response(:fetch_ticker, {:error, err})
      end
    end

    test "fetch_ticker accepts non-empty list of maps with price field" do
      body = [%{"lastPrice" => "67000"}, %{"lastPrice" => "68000"}]
      assert :ok = assert_public_response(:fetch_ticker, {:ok, %{status: 200, body: body}})
    end

    test "fetch_ticker flunks on list element missing price field" do
      body = [%{"foo" => "bar"}]

      assert_raise ExUnit.AssertionError, ~r/missing price-like field/, fn ->
        assert_public_response(:fetch_ticker, {:ok, %{status: 200, body: body}})
      end
    end

    test "fetch_ticker flunks on non-map, non-list body" do
      assert_raise ExUnit.AssertionError, ~r/expected map or non-empty list/, fn ->
        assert_public_response(:fetch_ticker, {:ok, %{status: 200, body: "nope"}})
      end
    end

    test "fetch_order_book flunks when bids/asks missing" do
      body = %{"foo" => "bar"}

      assert_raise ExUnit.AssertionError, ~r/missing bids\/asks/, fn ->
        assert_public_response(:fetch_order_book, {:ok, %{status: 200, body: body}})
      end
    end

    test "fetch_order_book passes with bids+asks" do
      body = %{"bids" => [[1, 2]], "asks" => [[3, 4]]}
      assert :ok = assert_public_response(:fetch_order_book, {:ok, %{status: 200, body: body}})
    end
  end

  describe "assert_private_response/3" do
    test "auth error is inconclusive" do
      err = %CError{type: :authentication_error, message: "bad key"}
      assert :ok = assert_private_response(:fetch_balance, {:error, err})
    end

    # Task 82: on the private path, both CF challenges and access_restricted
    # (geo/IP blocks with valid creds) are infrastructure, not code bugs.
    test "cloudflare_challenge is inconclusive on private path" do
      err = %CError{type: :cloudflare_challenge, message: "Attention Required!"}
      assert :ok = assert_private_response(:fetch_balance, {:error, err})
    end

    test "access_restricted is inconclusive on private path" do
      err = %CError{type: :access_restricted, message: "geo block"}
      assert :ok = assert_private_response(:fetch_balance, {:error, err})
    end

    test "order_not_found flunks by default" do
      err = %CError{type: :order_not_found, message: "nope"}

      assert_raise ExUnit.AssertionError, fn ->
        assert_private_response(:fetch_order, {:error, err})
      end
    end

    test "order_not_found passes with allow_not_found: true" do
      err = %CError{type: :order_not_found, message: "nope"}

      assert :ok =
               assert_private_response(:fetch_order, {:error, err}, allow_not_found: true)
    end

    test "no-position exchange_error passes with allow_no_position: true" do
      err = %CError{type: :exchange_error, message: "No position found for user"}

      assert :ok =
               assert_private_response(:fetch_position, {:error, err}, allow_no_position: true)
    end

    test "other exchange_error still flunks with allow_no_position: true" do
      err = %CError{type: :exchange_error, message: "invalid symbol"}

      assert_raise ExUnit.AssertionError, fn ->
        assert_private_response(:fetch_balance, {:error, err}, allow_no_position: true)
      end
    end
  end

  # Task 103: `allow_4xx: true` must propagate through the normalized-error
  # branch on both public and private helpers. Task 183 recalibrates: decision
  # keys on error class, not raw HTTP status.
  describe "allow_4xx on normalized errors (Task 103 / 183)" do
    test "public path: well-formed declined 4xx is inconclusive when allow_4xx: true" do
      err = %CError{
        type: :bad_symbol,
        http_status: 400,
        code: 10_001,
        message: "symbol not supported",
        exchange: "bybit"
      }

      log =
        capture_log(fn ->
          assert :ok = assert_public_response(:fetch_ticker, {:error, err}, allow_4xx: true)
        end)

      assert log =~ "INCONCLUSIVE"
    end

    test "public path: request-malformation 4xx flunks even with allow_4xx: true" do
      err = %CError{
        type: :bad_request,
        http_status: 400,
        code: -11_02,
        message: "Mandatory parameter 'symbol' was not sent",
        exchange: "binanceusdm",
        raw: %{"code" => -1102, "msg" => "Mandatory parameter 'symbol' was not sent"}
      }

      assert_raise ExUnit.AssertionError, ~r/failed with Bourse error/, fn ->
        assert_public_response(:fetch_ohlcv, {:error, err}, allow_4xx: true)
      end
    end

    test "public path: bad_symbol 4xx logs inconclusive with allow_4xx: true (Task 183)" do
      err = %CError{
        type: :bad_symbol,
        http_status: 400,
        message: "Invalid symbol",
        exchange: "okx"
      }

      log =
        capture_log(fn ->
          assert :ok = assert_public_response(:fetch_ticker, {:error, err}, allow_4xx: true)
        end)

      assert log =~ "INCONCLUSIVE"
    end

    test "public path: 4xx still flunks without allow_4xx" do
      err = %CError{
        type: :bad_symbol,
        http_status: 400,
        message: "symbol not supported",
        exchange: "bybit"
      }

      assert_raise ExUnit.AssertionError, ~r/failed with Bourse error/, fn ->
        assert_public_response(:fetch_ticker, {:error, err})
      end
    end

    test "private path: well-formed declined 4xx is inconclusive when allow_4xx: true" do
      err = %CError{
        type: :insufficient_funds,
        http_status: 422,
        code: "INSUFFICIENT_BALANCE",
        message: "insufficient balance",
        exchange: "binance"
      }

      log =
        capture_log(fn ->
          assert :ok =
                   assert_private_response(:fetch_balance, {:error, err}, allow_4xx: true)
        end)

      assert log =~ "INCONCLUSIVE"
    end

    test "private path: request-malformation 4xx flunks even with allow_4xx: true" do
      err = %CError{
        type: :bad_request,
        http_status: 422,
        code: "INVALID_PARAMS",
        message: "invalid params",
        exchange: "binance"
      }

      assert_raise ExUnit.AssertionError, ~r/failed with Bourse error/, fn ->
        assert_private_response(:fetch_balance, {:error, err}, allow_4xx: true)
      end
    end

    test "private path: 4xx still flunks without allow_4xx" do
      err = %CError{
        type: :bad_request,
        http_status: 422,
        message: "invalid params",
        exchange: "binance"
      }

      assert_raise ExUnit.AssertionError, ~r/failed with Bourse error/, fn ->
        assert_private_response(:fetch_balance, {:error, err})
      end
    end

    test "unmapped exchange_error 4xx flunks with allow_4xx: true (class not status)" do
      err = %CError{
        type: :exchange_error,
        http_status: 400,
        message: "unknown client error",
        exchange: "bybit"
      }

      assert_raise ExUnit.AssertionError, ~r/failed with Bourse error/, fn ->
        assert_public_response(:fetch_ticker, {:error, err}, allow_4xx: true)
      end
    end

    test "5xx still flunks even with allow_4xx: true" do
      err = %CError{
        type: :exchange_error,
        http_status: 503,
        message: "upstream unavailable",
        exchange: "bybit"
      }

      assert_raise ExUnit.AssertionError, ~r/failed with Bourse error/, fn ->
        assert_public_response(:fetch_ticker, {:error, err}, allow_4xx: true)
      end
    end

    test "missing http_status still flunks (no regression for pre-T103 errors)" do
      err = %CError{type: :exchange_error, message: "no status attached"}

      assert_raise ExUnit.AssertionError, ~r/failed with Bourse error/, fn ->
        assert_public_response(:fetch_ticker, {:error, err}, allow_4xx: true)
      end
    end

    test "flunk message includes raw body when present" do
      err = %CError{
        type: :bad_request,
        http_status: 400,
        message: "wrong endpoint",
        raw: %{"code" => -11_01, "msg" => "Invalid symbol"}
      }

      assert_raise ExUnit.AssertionError, ~r/raw: %\{/, fn ->
        assert_public_response(:fetch_ohlcv, {:error, err}, allow_4xx: true)
      end
    end
  end
end
