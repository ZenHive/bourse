defmodule Bourse.Unified.OrderBookParseTest do
  @moduledoc """
  Focused default-run coverage of the order-book read path and venue-carve
  invariants.
  """
  use ExUnit.Case, async: true

  import Bourse.StructValidators

  alias Bourse.Exchange
  alias Bourse.OrderBook
  alias Bourse.Unified.ReadParse

  @hyperliquid_l2_book_path Path.expand("../../fixtures/responses/hyperliquid/fetch_order_book.json", __DIR__)
  @external_resource @hyperliquid_l2_book_path

  @supported_first_class_captures [
    # Live public API captures from 2026-07-25.
    {"deribit", "BTC/USD:BTC",
     %{
       "result" => %{
         "bids" => [[64_028.0, 857_290.0]],
         "asks" => [[64_028.5, 1_152_010.0]]
       }
     }},
    {"okx", "BTC/USDT",
     %{
       "data" => [
         %{
           "bids" => [["64074", "0.06024347", "0", "3"]],
           "asks" => [["64074.1", "2.99658177", "0", "3"]]
         }
       ]
     }},
    {"bybit", "BTC/USDT:USDT",
     %{
       "result" => %{
         "b" => [["66026.80", "0.002"]],
         "a" => [["66027.00", "0.016"]]
       }
     }},
    {"binance", "BTC/USDT",
     %{
       "lastUpdateId" => 1,
       "bids" => [["64069.99000000", "21.76690000"]],
       "asks" => [["64070.00000000", "7.29608000"]]
     }},
    # Raw row from the pinned CCXT 4.5.65 compatibility corpus.
    {"binanceusdm", "BTC/USDT:USDT",
     %{
       "lastUpdateId" => 35_263_532_345,
       "T" => "1706803917258",
       "bids" => [["42651.10", "470.672"]],
       "asks" => [["42651.20", "63.248"]]
     }},
    # Live public API capture from 2026-07-25.
    {"hyperliquid", "BTC/USDC:USDC",
     %{
       "levels" => [
         [%{"n" => 1, "px" => "64137.0", "sz" => "0.00019"}],
         [%{"n" => 1, "px" => "64138.0", "sz" => "0.03509"}]
       ]
     }},
    # Raw row from the pinned CCXT 4.5.65 compatibility corpus.
    {"lighter", "ETH/USDC:USDC",
     %{
       "bids" => [
         %{
           "order_id" => "281475565888172",
           "price" => "3429.80",
           "remaining_base_amount" => "1.3237"
         }
       ],
       "asks" => [
         %{
           "order_id" => "562949401225099",
           "price" => "3430.00",
           "remaining_base_amount" => "0.2000"
         }
       ]
     }}
  ]

  defmodule NoopParser do
    @moduledoc false
    def __response_envelopes__, do: %{}
  end

  defp parse(exchange, body, params) do
    ReadParse.parse(exchange, NoopParser, :fetch_order_book, "fetchOrderBook", body, params, :parse_order_book, false)
  end

  test "bybit-shaped body: nonce is nil (Bourse does not map 'u'), levels are [price, amount]" do
    body = %{
      "result" => %{
        "s" => "BTCUSDT",
        "ts" => 1_706_803_948_569,
        "u" => 342_690,
        "b" => [["42544.5", "88.856"], ["42544.7", "172.404"]],
        "a" => [["42548.2", "75.008"], ["42548", "108.998"]]
      }
    }

    assert {:ok, %OrderBook{} = book} = parse(Exchange.new!("bybit"), body, %{"symbol" => "BTC/USDT:USDT"})
    assert book.nonce == nil
    assert book.timestamp == 1_706_803_948_569
    assert book.datetime == "2024-02-01T16:12:28.569Z"
    # bids sorted highest-first, asks lowest-first, each 2-wide
    assert book.bids == [[42_544.7, 172.404], [42_544.5, 88.856]]
    assert book.asks == [[42_548.0, 108.998], [42_548.2, 75.008]]
    assert :ok = assert_order_book_struct(book, "BTC/USDT:USDT")
  end

  test "okx-shaped body: provider columns remain in info while levels normalize to exact pairs" do
    body = %{
      "data" => [
        %{
          "ts" => 1_712_265_035_051,
          "bids" => [["67973.3", "0.05", "0", "1"], ["67973.2", "0.00725939", "0", "1"]],
          "asks" => [["67973.4", "1.40848059", "0", "7"], ["67975.9", "0.08292002", "0", "1"]]
        }
      ]
    }

    assert {:ok, %OrderBook{} = book} = parse(Exchange.new!("okx"), body, %{"symbol" => "BTC/USDT"})
    assert book.bids == [[67_973.3, 0.05], [67_973.2, 0.00725939]]
    assert book.asks == [[67_973.4, 1.40848059], [67_975.9, 0.08292002]]
    assert hd(book.info["bids"]) == ["67973.3", "0.05", "0", "1"]
    assert :ok = assert_order_book_struct(book, "BTC/USDT")
  end

  test "okx full-book three-column levels normalize without leaking order count" do
    body = %{
      "data" => [
        %{
          "bids" => [["100", "1", "4"]],
          "asks" => [["101", "2", "3"]]
        }
      ]
    }

    assert {:ok, %OrderBook{bids: [[100.0, 1.0]], asks: [[101.0, 2.0]]}} =
             parse(Exchange.new!("okx"), body, %{"symbol" => "BTC/USDT"})
  end

  test "every supported first-class venue capture emits exact [price, amount] pairs" do
    Enum.each(@supported_first_class_captures, fn {exchange_id, symbol, body} ->
      assert {:ok, %OrderBook{} = book} = parse(Exchange.new!(exchange_id), body, %{"symbol" => symbol})
      assert book.bids != [], "#{exchange_id} capture must contain bids"
      assert book.asks != [], "#{exchange_id} capture must contain asks"

      assert Enum.all?(book.bids ++ book.asks, fn
               [price, amount] -> is_number(price) and is_number(amount)
               _other -> false
             end),
             "#{exchange_id} emitted a level other than exact [price, amount]: #{inspect(book)}"
    end)
  end

  test "first-class venues without order-book support stay outside the level contract" do
    refute Exchange.has?(Exchange.new!("alpaca"), "fetchOrderBook")
    refute Exchange.has?(Exchange.new!("derive"), "fetchOrderBook")
  end

  test "unexpected list columns fail loudly instead of reaching consumers" do
    binance_body = %{"bids" => [["100", "1", "unexpected"]], "asks" => [["101", "1"]]}

    assert {:error, %Bourse.Error{message: binance_message, raw: %{level: ["100", "1", "unexpected"]}}} =
             parse(Exchange.new!("binance"), binance_body, %{"symbol" => "BTC/USDT"})

    assert binance_message =~ "Unexpected binance order book level"

    okx_body = %{
      "data" => [
        %{
          "bids" => [["100", "1", "0", "2", "unexpected"]],
          "asks" => [["101", "1", "0", "3"]]
        }
      ]
    }

    assert {:error, %Bourse.Error{message: okx_message}} =
             parse(Exchange.new!("okx"), okx_body, %{"symbol" => "BTC/USDT"})

    assert okx_message =~ "Unexpected okx order book level"
  end

  test "binance spot body without a timestamp: timestamp/datetime nil, nonce from lastUpdateId" do
    body = %{
      "lastUpdateId" => 4_313_234,
      "bids" => [["29861", "0.00101"], ["29829.3", "0.000667"]],
      "asks" => [["29971.81", "0.001161"], ["29988.93", "0.112648"]]
    }

    assert {:ok, %OrderBook{} = book} = parse(Exchange.new!("binance"), body, %{"symbol" => "BTC/USDT"})
    assert book.timestamp == nil
    assert book.datetime == nil
    assert book.nonce == 4_313_234
    assert :ok = assert_order_book_struct(book, "BTC/USDT")
    assert OrderBook.best_bid(book) == 29_861.0
    assert OrderBook.best_ask(book) == 29_971.81
    assert OrderBook.spread(book) == 29_971.81 - 29_861.0
  end

  test "captured Hyperliquid l2Book object levels become bids and asks" do
    body = @hyperliquid_l2_book_path |> File.read!() |> Jason.decode!()

    assert {:ok, %OrderBook{} = book} =
             parse(Exchange.new!("hyperliquid"), body, %{"symbol" => "BTC/USDC:USDC"})

    assert book.bids == [[63_948.0, 0.02431], [63_945.0, 0.00802], [63_932.0, 0.04988]]
    assert book.asks == [[63_955.0, 0.00026], [63_968.0, 0.01675], [63_977.0, 0.001]]
    assert :ok = assert_order_book_struct(book, "BTC/USDC:USDC")
  end

  test "unsorted input is sorted (bids desc, asks asc) and the book is never crossed" do
    body = %{
      "lastUpdateId" => 1,
      "bids" => [["100", "1"], ["102", "1"], ["101", "1"]],
      "asks" => [["105", "1"], ["103", "1"], ["104", "1"]]
    }

    assert {:ok, %OrderBook{} = book} = parse(Exchange.new!("binance"), body, %{"symbol" => "BTC/USDT"})
    assert Enum.map(book.bids, &hd/1) == [102.0, 101.0, 100.0]
    assert Enum.map(book.asks, &hd/1) == [103.0, 104.0, 105.0]
    assert :ok = assert_order_book_struct(book)
  end

  test "a success envelope with no bids/asks yields an empty book (Bourse safeList default)" do
    assert {:ok, %OrderBook{bids: [], asks: []} = book} =
             parse(Exchange.new!("bybit"), %{"retCode" => 0, "result" => %{}}, %{"symbol" => "BTC/USDT"})

    assert :ok = assert_order_book_struct(book)
    assert OrderBook.best_bid(book) == nil
    assert OrderBook.spread(book) == nil
  end

  test "a non-map body is an error, not a crash" do
    assert {:error, _} = parse(Exchange.new!("binance"), [1, 2, 3], %{"symbol" => "BTC/USDT"})
  end
end
