defmodule Bourse.AlpacaAuthoredSliceTest do
  @moduledoc """
  Offline regression pins for the authored Alpaca stocks slice.

  Evidence provenance:

  * The bars / snapshot payloads are REAL RECORDED responses, captured live from
    `data.alpaca.markets` with paper-account keys on 2026-07-20 (`feed=iex`,
    symbol `GLD`) — Bourse's alpaca is crypto-only, so no Bourse oracle exists for
    this surface; the live venue is the only (tier-1) oracle, and these pins
    freeze what it actually returned.
  * The 401 body in `authentication failure` is likewise a real recorded
    response, captured live on 2026-07-19.
  * The null-bars body is the real empty-window response observed live
    2026-07-20.

  Live verification record: `docs/prod-verification-ledger.md` § Closed → alpaca.
  """
  use ExUnit.Case, async: false

  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Test.RequestCollector

  @explicit_since_ms 1_783_900_800_000
  @explicit_until_ms 1_784_073_600_000
  @frozen_now_ms 1_785_758_400_000

  @recorded_401_body """
  <html>
  <head><title>401 Authorization Required</title></head>
  <body>
  <center><h1>401 Authorization Required</h1></center>
  <hr><center>nginx</center>
  </body>
  </html>
  """

  test "stock OHLCV selects the authored bars endpoint and parses its envelope" do
    stub = "alpaca-stock-bars"
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, stock_bars_body())
    end)

    assert {:ok,
            [
              [1_783_915_200_000, 372.77, 372.77, 365.78, 367.125, 164_569],
              [1_784_001_600_000, 374.53, 376.24, 371.11, 372.08, 138_850]
            ]} =
             Bourse.fetch_ohlcv(exchange(), "GLD", "1d",
               since: @explicit_since_ms,
               until: @explicit_until_ms,
               limit: 2,
               plug: {Req.Test, stub}
             )

    conn = RequestCollector.one!(requests)
    assert conn.request_path == "/v2/stocks/GLD/bars"
    assert Plug.Conn.get_req_header(conn, "apca-api-key-id") == ["key"]
    assert Plug.Conn.get_req_header(conn, "apca-api-secret-key") == ["secret"]

    assert RequestCollector.query(conn) == %{
             "end" => "2026-07-15T00:00:00.000Z",
             "feed" => "iex",
             "limit" => "2",
             "start" => "2026-07-13T00:00:00.000Z",
             "timeframe" => "1D"
           }
  end

  test "stock OHLCV authors a 60-day default lookback when since is omitted" do
    stub = "alpaca-stock-bars-default-window"
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, stock_bars_body())
    end)

    assert {:ok, [_first | _rest]} =
             Bourse.fetch_ohlcv(exchange(), "GLD", "1d",
               timestamp_ms_override: @frozen_now_ms,
               plug: {Req.Test, stub}
             )

    assert RequestCollector.query(requests) == %{
             "feed" => "iex",
             "start" => "2026-06-04T12:00:00.000Z",
             "timeframe" => "1D"
           }
  end

  # Live-observed 2026-07-20: Alpaca answers an empty requested window with
  # `{"bars": null, "symbol": "GLD", "next_page_token": null}` with HTTP 200.
  # Bourse `parseOHLCVs` reads the list via safeList(..., []) — null means no
  # candles, not a shape error.
  test "stock OHLCV with a null bars payload parses as an empty candle list" do
    stub = "alpaca-stock-bars-empty"

    Req.Test.stub(stub, fn conn ->
      Req.Test.json(conn, %{"bars" => nil, "symbol" => "GLD", "next_page_token" => nil})
    end)

    assert {:ok, []} =
             Bourse.fetch_ohlcv(exchange(), "GLD", "1d",
               since: @explicit_since_ms,
               limit: 1,
               plug: {Req.Test, stub}
             )
  end

  # Without credentials the authored `symbol_has_slash` selection still targets
  # the authenticated stocks endpoint for a slashless symbol; the resolver must
  # fail loud rather than silently reroute to the public crypto endpoint (live
  # 2026-07-20 the reroute produced Alpaca's "Invalid location: GLD").
  test "credless stock OHLCV fails loud instead of rerouting to the crypto endpoint" do
    credless = Exchange.new!(:alpaca)

    assert {:error, %Error{type: :authentication_error, message: message}} =
             Bourse.fetch_ohlcv(credless, "GLD", "1d", limit: 1)

    assert message =~ "v2/stocks/{symbol}/bars"
  end

  test "stock ticker selects the authored snapshot endpoint and flattens nested fields" do
    stub = "alpaca-stock-snapshot"
    Req.Test.stub(stub, &stock_snapshot_response/1)

    assert {:ok, %Bourse.Ticker{} = ticker} =
             Bourse.fetch_ticker(exchange(), "GLD", plug: {Req.Test, stub})

    assert ticker.symbol == "GLD"
    assert ticker.last == 368.39
    assert ticker.bid == 368.07
    assert ticker.ask == 368.48
    assert ticker.open == 364.09
    assert ticker.high == 368.95
    assert ticker.low == 363.66
    assert ticker.close == 368.46
    assert ticker.base_volume == 161_064
    assert ticker.vwap == 367.426093

    # Alpaca's dailyBar carries `n` (trade count), not a quote-denominated
    # volume, and publishes no quote volume at all — see carve C-T428d.
    assert is_nil(ticker.quote_volume)
  end

  # Real recorded response: `curl -H "APCA-API-KEY-ID: invalid-key" ...
  # https://data.alpaca.markets/v2/stocks/GLD/bars?timeframe=1D&limit=1&feed=iex`
  # observed 2026-07-19 → HTTP 401, `content-type: text/html`, nginx body below.
  test "invalid credentials surface Alpaca's recorded HTML 401 rather than a parsed JSON error" do
    stub = "alpaca-401"

    Req.Test.stub(stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(401, @recorded_401_body)
    end)

    assert {:error, %Error{} = error} =
             Bourse.fetch_ohlcv(exchange(), "GLD", "1d", limit: 1, plug: {Req.Test, stub})

    # Alpaca's edge rejects before the app, so there is no JSON error envelope —
    # the HTML branch classifies by status: 401 means credential rejection
    # (task 439), with the HTML preview retained in raw.
    assert error.type == :authentication_error
    assert error.code == 401
    assert is_binary(error.raw[:body_preview])
  end

  test "inverted stock OHLCV window surfaces Alpaca's observed typed rejection" do
    stub = "alpaca-inverted-bars-window"
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)

      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"message" => "end should not be before start"})
    end)

    assert {:error,
            %Error{
              type: :exchange_error,
              code: 400,
              http_status: 400,
              message: "end should not be before start"
            }} =
             Bourse.fetch_ohlcv(exchange(), "GLD", "1d",
               since: @explicit_until_ms,
               until: @explicit_since_ms,
               plug: {Req.Test, stub}
             )

    query = RequestCollector.query(requests)
    assert query["start"] == "2026-07-15T00:00:00.000Z"
    assert query["end"] == "2026-07-13T00:00:00.000Z"
    refute Map.has_key?(query, "since")
    refute Map.has_key?(query, "until")
  end

  defp exchange do
    Exchange.new!(:alpaca, credentials: Credentials.new!(api_key: "key", secret: "secret"))
  end

  # Real recorded 200 from `GET /v2/stocks/GLD/bars?timeframe=1D&limit=2&
  # start=2026-07-13&feed=iex`, captured live 2026-07-20 with paper keys.
  defp stock_bars_body do
    %{
      "bars" => [
        %{
          "t" => "2026-07-13T04:00:00Z",
          "o" => 372.77,
          "h" => 372.77,
          "l" => 365.78,
          "c" => 367.125,
          "v" => 164_569,
          "n" => 3151,
          "vw" => 367.913702
        },
        %{
          "t" => "2026-07-14T04:00:00Z",
          "o" => 374.53,
          "h" => 376.24,
          "l" => 371.11,
          "c" => 372.08,
          "v" => 138_850,
          "n" => 3106,
          "vw" => 373.583783
        }
      ],
      "next_page_token" => "R0xEfER8MTc4NDA4ODAwMDAwMDAwMDAwMA==",
      "symbol" => "GLD"
    }
  end

  # Real recorded 200 from `GET /v2/stocks/GLD/snapshot?feed=iex`, captured
  # live 2026-07-20 with paper keys (Friday 2026-07-17 close).
  defp stock_snapshot_response(conn) do
    assert conn.request_path == "/v2/stocks/GLD/snapshot"
    assert Plug.Conn.get_req_header(conn, "apca-api-key-id") == ["key"]
    assert Plug.Conn.get_req_header(conn, "apca-api-secret-key") == ["secret"]
    assert conn.query_string == "feed=iex"

    Req.Test.json(conn, %{
      "symbol" => "GLD",
      "latestTrade" => %{
        "c" => [" ", "T"],
        "i" => 52_983_998_537_842,
        "p" => 368.39,
        "s" => 120,
        "t" => "2026-07-17T20:00:04.176990308Z",
        "x" => "V",
        "z" => "B"
      },
      "latestQuote" => %{
        "ap" => 368.48,
        "as" => 40,
        "ax" => "V",
        "bp" => 368.07,
        "bs" => 40,
        "bx" => "V",
        "c" => ["R"],
        "t" => "2026-07-17T20:00:25.692292024Z",
        "z" => "B"
      },
      "minuteBar" => %{
        "c" => 368.39,
        "h" => 368.39,
        "l" => 368.39,
        "n" => 1,
        "o" => 368.39,
        "t" => "2026-07-17T20:00:00Z",
        "v" => 120,
        "vw" => 368.39
      },
      "dailyBar" => %{
        "c" => 368.46,
        "h" => 368.95,
        "l" => 363.66,
        "n" => 3301,
        "o" => 364.09,
        "t" => "2026-07-17T04:00:00Z",
        "v" => 161_064,
        "vw" => 367.426093
      },
      "prevDailyBar" => %{
        "c" => 364.98,
        "h" => 368.43,
        "l" => 364.11,
        "n" => 5926,
        "o" => 367.47,
        "t" => "2026-07-16T04:00:00Z",
        "v" => 345_436,
        "vw" => 366.183939
      }
    })
  end
end
