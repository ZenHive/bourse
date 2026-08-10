defmodule Bourse.Unified.ReadParseSlotWiringTest do
  @moduledoc false
  # Offline gate for the task-239 parser-slot wiring. These pure tests run in
  # the default suite.
  use ExUnit.Case, async: false

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Unified
  alias Bourse.Unified.ReadParse

  describe "wired parser slots — accounts / time / option / leverage (task 239)" do
    test "fetchTime routes to integer ms (okx static fixture shape)" do
      exchange = Exchange.new!("okx")
      body = %{"code" => "0", "data" => [%{"ts" => "1712250348676"}], "msg" => ""}

      assert {:ok, 1_712_250_348_676} =
               ReadParse.parse(exchange, Bourse.Okx, :fetch_time, "fetchTime", body, %{}, :parse_time, false)
    end

    test "fetchTime routes deribit JSON-RPC result to integer ms" do
      exchange = Exchange.new!("deribit")
      body = %{"jsonrpc" => "2.0", "result" => 1_700_000_000_000, "testnet" => true}

      assert {:ok, 1_700_000_000_000} =
               ReadParse.parse(
                 exchange,
                 Bourse.Deribit,
                 :fetch_time,
                 "fetchTime",
                 body,
                 %{},
                 :parse_time,
                 false
               )
    end

    test "fetchAccounts returns %Account{} list (okx config row)" do
      exchange = Exchange.new!("okx")

      body = %{
        "code" => "0",
        "data" => [%{"uid" => "374579799097793561", "acctLv" => "1", "label" => "main"}],
        "msg" => ""
      }

      assert {:ok, [%Bourse.Account{id: "374579799097793561", type: "1"}]} =
               ReadParse.parse(
                 exchange,
                 Bourse.Okx,
                 :fetch_accounts,
                 "fetchAccounts",
                 body,
                 %{},
                 :parse_account,
                 true
               )
    end

    test "fetchAccounts returns %Account{} list (deribit subaccounts)" do
      exchange = Exchange.new!("deribit")

      body = %{
        "jsonrpc" => "2.0",
        "result" => [
          %{"id" => "238216", "type" => "main", "username" => "alice"},
          %{"id" => "245499", "type" => "subaccount", "username" => "alice_1"}
        ]
      }

      assert {:ok, accounts} =
               ReadParse.parse(
                 exchange,
                 Bourse.Deribit,
                 :fetch_accounts,
                 "fetchAccounts",
                 body,
                 %{},
                 :parse_account,
                 true
               )

      assert [%Bourse.Account{id: "238216", type: "main"}, %Bourse.Account{id: "245499", type: "subaccount"}] =
               accounts
    end

    test "fetchOption returns %OptionData{} with populated fields (deribit book summary)" do
      exchange = Exchange.new!("deribit")
      symbol = "BTC-27DEC24-240000-C"

      body = %{
        "jsonrpc" => "2.0",
        "result" => [
          %{
            "instrument_name" => symbol,
            "base_currency" => "BTC",
            "bid_price" => 0.0385,
            "ask_price" => 0.042,
            "mid_price" => 0.04025,
            "mark_price" => 0.04007735,
            "last" => 0.04,
            "open_interest" => 274.2,
            "underlying_price" => 73_742.14,
            "volume" => 4.0,
            "volume_usd" => 11_045.12,
            "price_change" => -6.9767,
            "creation_timestamp" => 1_711_100_949_273
          }
        ]
      }

      assert {:ok, %Bourse.OptionData{} = opt} =
               ReadParse.parse(
                 exchange,
                 Bourse.Deribit,
                 :fetch_option,
                 "fetchOption",
                 body,
                 %{"symbol" => symbol},
                 :parse_option,
                 false
               )

      assert opt.symbol == "BTC/USD:BTC-241227-240000-C"
      assert opt.currency == "BTC"
      assert opt.bid_price == 0.0385
      assert opt.ask_price == 0.042
      assert opt.mark_price == 0.04007735
      assert opt.last_price == 0.04
      assert opt.open_interest == 274.2
      assert opt.underlying_price == 73_742.14
      assert is_map(opt.info)
    end

    test "fetchLeverage merges okx hedge-mode long/short rows into %Leverage{}" do
      exchange = Exchange.new!("okx")

      body = %{
        "code" => "0",
        "data" => [
          %{"instId" => "BTC-USDT-SWAP", "mgnMode" => "cross", "posSide" => "long", "lever" => "3"},
          %{"instId" => "BTC-USDT-SWAP", "mgnMode" => "cross", "posSide" => "short", "lever" => "5"}
        ],
        "msg" => ""
      }

      assert {:ok, %Bourse.Leverage{} = lev} =
               ReadParse.parse(
                 exchange,
                 Bourse.Okx,
                 :fetch_leverage,
                 "fetchLeverage",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_leverage,
                 false
               )

      assert lev.symbol == "BTC/USDT:USDT"
      assert lev.margin_mode == "cross"
      assert lev.long_leverage == 3
      assert lev.short_leverage == 5
      assert is_list(lev.info)
    end

    test "fetchLeverage fails loud when sided rows carry no leverage at all" do
      exchange = Exchange.new!("okx")

      body = %{
        "code" => "0",
        "data" => [%{"instId" => "BTC-USDT-SWAP", "posSide" => "long"}],
        "msg" => ""
      }

      assert {:error, %Error{}} =
               ReadParse.parse(
                 exchange,
                 Bourse.Okx,
                 :fetch_leverage,
                 "fetchLeverage",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_leverage,
                 false
               )
    end

    test "fetchLeverage parses bybit single position row into %Leverage{}" do
      exchange = Exchange.new!("bybit")

      # Key set observed live on bybit demo `/v5/position/list` (2026-07-16):
      # the row carries `tradeMode`, never a `marginMode` key.
      body = %{
        "retCode" => 0,
        "result" => %{
          "list" => [
            %{
              "symbol" => "BTCUSDT",
              "leverage" => "10",
              "tradeMode" => 0
            }
          ]
        }
      }

      assert {:ok, %Bourse.Leverage{} = lev} =
               ReadParse.parse(
                 exchange,
                 Bourse.Bybit,
                 :fetch_leverage,
                 "fetchLeverage",
                 body,
                 %{"symbol" => "BTC/USDT:USDT"},
                 :parse_leverage,
                 false
               )

      assert lev.long_leverage == 10
      assert lev.short_leverage == 10
      assert lev.symbol == "BTC/USDT:USDT"
    end

    test "unified fetch_option/fetch_leverage do not leak HTTP envelopes through call_dispatch" do
      # Routing regression: Promise<Option>/Promise<Leverage> must not resolve to
      # parser_plan :none (which returns the raw status/headers/body map).
      deribit = Exchange.new!("deribit")
      okx = Exchange.new!("okx")

      option_body = %{
        "jsonrpc" => "2.0",
        "result" => [
          %{
            "instrument_name" => "BTC-27DEC24-240000-C",
            "base_currency" => "BTC",
            "bid_price" => 0.01,
            "ask_price" => 0.02,
            "mark_price" => 0.015,
            "last" => 0.014,
            "open_interest" => 1.0
          }
        ]
      }

      lev_body = %{
        "code" => "0",
        "data" => [%{"instId" => "BTC-USDT-SWAP", "mgnMode" => "cross", "posSide" => "net", "lever" => "3"}],
        "msg" => ""
      }

      option_stub = unique_stub("opt")
      lev_stub = unique_stub("lev")

      Req.Test.stub(option_stub, fn conn ->
        Req.Test.json(conn, option_body)
      end)

      Req.Test.stub(lev_stub, fn conn ->
        Req.Test.json(conn, lev_body)
      end)

      assert {:ok, %Bourse.OptionData{}} =
               Unified.call_dispatch(
                 deribit,
                 Bourse.Deribit,
                 :fetch_option,
                 "fetchOption",
                 %{"symbol" => "BTC-27DEC24-240000-C"},
                 plug: {Req.Test, option_stub}
               )

      creds = Bourse.Credentials.new!(api_key: "k", secret: "s", password: "p")
      okx = %{okx | credentials: creds}

      assert {:ok, %Bourse.Leverage{long_leverage: 3, short_leverage: 3}} =
               Unified.call_dispatch(
                 okx,
                 Bourse.Okx,
                 :fetch_leverage,
                 "fetchLeverage",
                 %{"symbol" => "BTC/USDT:USDT"},
                 plug: {Req.Test, lev_stub}
               )
    end
  end

  defp unique_stub(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end
