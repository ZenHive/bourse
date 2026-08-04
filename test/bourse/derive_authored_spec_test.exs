defmodule Bourse.DeriveAuthoredSpecTest do
  use ExUnit.Case, async: true

  import Bourse.IntegrationHelper, only: [build_exchange: 2, require_credentials!: 2]

  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Test.RequestCollector

  @derive_testnet_url "https://api-demo.lyra.finance"
  @derive_testnet_subaccount_id 144_422
  @derive_option_native_id "ZEC-20260925-800-P"
  @derive_option_symbol "ZEC/USDC:USDC-260925-800-P"
  @observed_timestamp_ms 1_700_000_000_000

  test "SM balance keeps provider collateral amount as total and deliberately leaves free and used unmapped" do
    field_map = Bourse.Derive.__field_maps__()["balance"]["field_map"]

    assert %{
             "kind" => "keyed_collection",
             "collection_key" => "collaterals",
             "index_key" => "currency",
             "value_key" => "amount"
           } = field_map["total"]

    assert field_map["free"] == nil
    assert field_map["used"] == nil
  end

  test "fetch_markets fans out Derive instrument types and parses unified market identities" do
    stub = {__MODULE__, :derive_markets, System.unique_integer([:positive])}
    requested = start_supervised!({Agent, fn -> [] end})

    # Each typed request serves ONLY its own instrument_type, so a combined
    # result is reachable only if all three legs of the fan-out are issued.
    Req.Test.stub(stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"instrument_type" => instrument_type} = JSON.decode!(body)
      Agent.update(requested, &[instrument_type | &1])

      rows = Enum.filter(derive_market_rows(), &(&1["instrument_type"] == instrument_type))
      Req.Test.json(conn, %{"result" => %{"instruments" => rows}})
    end)

    exchange = Exchange.new!("derive")

    assert {:ok, markets} = Bourse.fetch_markets(exchange, plug: {Req.Test, stub})

    assert Enum.sort(Agent.get(requested, & &1)) == ["erc20", "option", "perp"]
    assert length(markets) == 3

    assert Enum.any?(markets, &(&1.symbol == "WEETH/USDC" and &1.type == "spot" and &1.spot == true))

    assert Enum.any?(markets, fn market ->
             market.symbol == "BTC/USD:USDC" and market.type == "swap" and market.swap == true and
               market.linear == true and market.contract == true and market.settle == "USDC"
           end)

    assert Enum.any?(markets, fn market ->
             market.symbol == "ZEC/USDC:USDC-261225-900-P" and market.type == "option" and
               market.option == true and market.strike == 900 and is_integer(market.expiry)
           end)
  end

  test "Derive fetch_open_orders requests only open orders" do
    stub = {__MODULE__, :derive_open_orders, System.unique_integer([:positive])}
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, %{"result" => %{"orders" => []}})
    end)

    credentials =
      Credentials.new!(
        api_key: "0x05Fd3d190C176eB58cC4DDf38bFD1848a9786238",
        secret: "0x0123456789012345678901234567890123456789012345678901234567890123"
      )

    exchange =
      Exchange.new!("derive",
        credentials: credentials,
        options: %{"subaccount_id" => @derive_testnet_subaccount_id}
      )

    assert {:ok, []} = Bourse.fetch_open_orders(exchange, plug: {Req.Test, stub})

    conn = RequestCollector.one!(requests)
    assert conn.request_path == "/private/get_orders"

    assert %{"subaccount_id" => @derive_testnet_subaccount_id, "status" => "open"} =
             RequestCollector.json_body!(requests)
  end

  test "Derive option order, position, and trade rows backfill unified symbols" do
    stub = {__MODULE__, :derive_option_reads, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn conn ->
      Req.Test.json(conn, derive_option_read_response(conn.request_path))
    end)

    credentials =
      Credentials.new!(
        api_key: "0x05Fd3d190C176eB58cC4DDf38bFD1848a9786238",
        secret: "0x0123456789012345678901234567890123456789012345678901234567890123"
      )

    exchange =
      Exchange.new!("derive",
        credentials: credentials,
        options: %{"subaccount_id" => @derive_testnet_subaccount_id}
      )

    assert {:ok, [%Bourse.Order{symbol: @derive_option_symbol}]} =
             Bourse.fetch_open_orders(exchange, plug: {Req.Test, stub})

    assert {:ok, [%Bourse.Position{symbol: @derive_option_symbol, percentage: 2.0}]} =
             Bourse.fetch_positions(exchange, plug: {Req.Test, stub})

    assert {:ok, [%Bourse.Trade{symbol: @derive_option_symbol}]} =
             Bourse.fetch_my_trades(exchange, plug: {Req.Test, stub})

    assert Exchange.has?(exchange, "fetchGreeks")
    refute Exchange.has?(exchange, "fetchAllGreeks")
  end

  test "empty Derive closed order envelopes are successful lists" do
    stub = {__MODULE__, :derive_closed_orders, System.unique_integer([:positive])}
    Req.Test.stub(stub, fn conn -> Req.Test.json(conn, %{"result" => %{"orders" => []}}) end)

    credentials =
      Credentials.new!(
        api_key: "0x05Fd3d190C176eB58cC4DDf38bFD1848a9786238",
        secret: "0x0123456789012345678901234567890123456789012345678901234567890123"
      )

    exchange =
      Exchange.new!("derive",
        credentials: credentials,
        options: %{"subaccount_id" => @derive_testnet_subaccount_id}
      )

    assert {:ok, []} = Bourse.fetch_closed_orders(exchange, plug: {Req.Test, stub})
  end

  test "create_order builds and parses Derive's signed order envelope" do
    stub = {__MODULE__, :derive_create_order, System.unique_integer([:positive])}
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)

      Req.Test.json(conn, %{
        "result" => %{
          "order" => %{
            "order_id" => "derive-order-1",
            "instrument_name" => "ETH-PERP",
            "direction" => "buy",
            "order_type" => "limit",
            "order_status" => "open",
            "creation_timestamp" => 1_700_000_000_000,
            "last_update_timestamp" => 1_700_000_000_000,
            "limit_price" => "100",
            "amount" => "0.1",
            "filled_amount" => "0",
            "average_price" => "0",
            "order_fee" => "0",
            "time_in_force" => "gtc"
          }
        }
      })
    end)

    exchange =
      "derive"
      |> Exchange.new!(
        sandbox: true,
        credentials:
          Credentials.new!(
            api_key: "0x05Fd3d190C176eB58cC4DDf38bFD1848a9786238",
            secret: "0x0123456789012345678901234567890123456789012345678901234567890123"
          )
      )
      |> Exchange.put_markets([
        %Bourse.Market{
          id: "ETH-PERP",
          symbol: "ETH/USD:USDC",
          precision: %{"amount" => 0.01, "price" => 0.01},
          info: %{"base_asset_address" => "0x0000000000000000000000000000000000000001", "base_asset_sub_id" => "0"}
        }
      ])

    assert {:ok, %Bourse.Order{id: "derive-order-1", status: "open", side: "buy", price: 100.0, amount: 0.1}} =
             Bourse.create_order(exchange, "ETH/USD:USDC", "limit", "buy", 0.1,
               price: 100,
               max_fee: "2",
               subaccount_id: @derive_testnet_subaccount_id,
               timestamp_ms_override: 1_700_000_000_000,
               plug: {Req.Test, stub}
             )

    assert %{
             "instrument_name" => "ETH-PERP",
             "direction" => "buy",
             "order_type" => "limit",
             "amount" => "0.1",
             "limit_price" => "100",
             "max_fee" => "2",
             "subaccount_id" => @derive_testnet_subaccount_id,
             "nonce" => 1_700_000_000_000,
             "signature_expiry_sec" => 1_707_776_000,
             "signature" => "0x" <> _
           } = RequestCollector.json_body!(requests)
  end

  test "cancel_order maps the unified id and symbol to Derive's native body" do
    stub = {__MODULE__, :derive_cancel_order, System.unique_integer([:positive])}
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, %{"result" => %{"order_id" => "derive-order-1", "order_status" => "cancelled"}})
    end)

    exchange =
      "derive"
      |> Exchange.new!(
        credentials:
          Credentials.new!(
            api_key: "0x05Fd3d190C176eB58cC4DDf38bFD1848a9786238",
            secret: "0x0123456789012345678901234567890123456789012345678901234567890123"
          ),
        options: %{"subaccount_id" => @derive_testnet_subaccount_id}
      )
      |> Exchange.put_markets([%Bourse.Market{id: "ETH-PERP", symbol: "ETH/USD:USDC"}])

    assert {:ok, %Bourse.Order{id: "derive-order-1", status: "canceled"}} =
             Bourse.cancel_order(exchange, "derive-order-1", symbol: "ETH/USD:USDC", plug: {Req.Test, stub})

    assert %{
             "order_id" => "derive-order-1",
             "instrument_name" => "ETH-PERP",
             "subaccount_id" => @derive_testnet_subaccount_id
           } =
             RequestCollector.json_body!(requests)
  end

  test "edit_order reuses the signed create envelope and sets order_id_to_cancel" do
    stub = {__MODULE__, :derive_edit_order, System.unique_integer([:positive])}
    {:ok, requests} = RequestCollector.start_link()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)

      Req.Test.json(conn, %{
        "result" => %{
          "order" => %{
            "order_id" => "derive-order-2",
            "instrument_name" => "ETH-PERP",
            "direction" => "buy",
            "order_type" => "limit",
            "order_status" => "open",
            "creation_timestamp" => 1_700_000_000_000,
            "last_update_timestamp" => 1_700_000_000_000,
            "limit_price" => "90",
            "amount" => "0.2",
            "filled_amount" => "0",
            "average_price" => "0",
            "order_fee" => "0",
            "time_in_force" => "gtc"
          }
        }
      })
    end)

    exchange =
      "derive"
      |> Exchange.new!(
        sandbox: true,
        credentials:
          Credentials.new!(
            api_key: "0x05Fd3d190C176eB58cC4DDf38bFD1848a9786238",
            secret: "0x0123456789012345678901234567890123456789012345678901234567890123"
          )
      )
      |> Exchange.put_markets([
        %Bourse.Market{
          id: "ETH-PERP",
          symbol: "ETH/USD:USDC",
          precision: %{"amount" => 0.01, "price" => 0.01},
          info: %{"base_asset_address" => "0x0000000000000000000000000000000000000001", "base_asset_sub_id" => "0"}
        }
      ])

    assert {:ok, %Bourse.Order{id: "derive-order-2", status: "open", side: "buy", price: 90.0, amount: 0.2}} =
             Bourse.edit_order(exchange, "derive-order-1", "ETH/USD:USDC", "limit", "buy",
               amount: 0.2,
               price: 90,
               max_fee: "2",
               subaccount_id: @derive_testnet_subaccount_id,
               clientOrderId: "edit-label",
               timestamp_ms_override: 1_700_000_000_000,
               plug: {Req.Test, stub}
             )

    body = RequestCollector.json_body!(requests)

    # Each unified key binds to its own venue field — never the instrument name.
    assert body["instrument_name"] == "ETH-PERP"
    assert body["order_id_to_cancel"] == "derive-order-1"
    assert body["direction"] == "buy"
    assert body["order_type"] == "limit"
    assert body["amount"] == "0.2"
    assert body["limit_price"] == "90"
    assert body["max_fee"] == "2"
    assert body["subaccount_id"] == @derive_testnet_subaccount_id
    assert body["nonce"] == 1_700_000_000_000
    assert body["label"] == "edit-label"
    assert body["signature"] =~ ~r/^0x[0-9a-fA-F]+$/
    refute body["direction"] == "ETH-PERP"
    refute body["limit_price"] == "ETH-PERP"
    refute body["nonce"] == "ETH-PERP"
  end

  @tag :integration
  @tag :network
  test "live api-demo market fan-out and empty order reads" do
    public_exchange = build_exchange(:derive, sandbox: true)

    assert {:ok, markets} = Bourse.fetch_markets(public_exchange)
    assert Enum.any?(markets, &(&1.type == "spot" and is_nil(&1.settle)))
    assert Enum.any?(markets, &(&1.type == "swap" and &1.linear == true and &1.settle == "USDC"))

    assert Enum.any?(markets, fn market ->
             market.type == "option" and market.option == true and is_integer(market.strike) and
               is_integer(market.expiry) and String.contains?(market.symbol, ":USDC-")
           end)

    credentials = require_credentials!(:derive, url: @derive_testnet_url)
    private_exchange = build_exchange(:derive, credentials: credentials, sandbox: true)

    # Open-order reads must stay empty between lifecycle probes. Closed-order
    # history accumulates (task 473 leftovers and every subsequent cancel) —
    # assert list shape only, not emptiness (live 2026-07-29: 49 closed rows).
    assert {:ok, []} = Bourse.fetch_open_orders(private_exchange, subaccount_id: @derive_testnet_subaccount_id)
    assert {:ok, closed} = Bourse.fetch_closed_orders(private_exchange, subaccount_id: @derive_testnet_subaccount_id)
    assert is_list(closed)
    assert Enum.all?(closed, &match?(%Bourse.Order{}, &1))
  end

  @tag :integration
  @tag :network
  test "live api-demo private reads use the constructor default and preserve identifier errors" do
    credentials = require_credentials!(:derive, url: @derive_testnet_url)

    unconfigured = build_exchange(:derive, credentials: credentials, sandbox: true)

    assert {:error, %Error{type: :invalid_parameters, message: missing_message}} =
             Bourse.fetch_open_orders(unconfigured)

    assert missing_message =~ "subaccount_id"
    assert missing_message =~ "subaccount_id: value"

    exchange = %{
      unconfigured
      | options: %{"subaccount_id" => @derive_testnet_subaccount_id}
    }

    assert {:ok, positions} = Bourse.fetch_positions(exchange)
    assert is_list(positions)

    assert {:ok, orders} = Bourse.fetch_orders(exchange)
    assert is_list(orders)

    assert {:ok, open_orders} = Bourse.fetch_open_orders(exchange)
    assert is_list(open_orders)

    assert {:ok, trades} = Bourse.fetch_my_trades(exchange)
    assert is_list(trades)

    assert {:error, %Error{type: :invalid_order, code: 14_001, message: provider_message}} =
             Bourse.fetch_positions(exchange, subaccount_id: 999_999_999)

    assert provider_message =~ "Subaccount not found"
  end

  defp derive_market_rows do
    [
      %{
        "instrument_name" => "WEETH-USDC",
        "instrument_type" => "erc20",
        "base_currency" => "WEETH",
        "quote_currency" => "USDC",
        "is_active" => true,
        "amount_step" => "0.01",
        "tick_size" => "0.01"
      },
      %{
        "instrument_name" => "BTC-PERP",
        "instrument_type" => "perp",
        "base_currency" => "BTC",
        "quote_currency" => "USD",
        "is_active" => true,
        "amount_step" => "0.001",
        "tick_size" => "0.1"
      },
      %{
        "instrument_name" => "ZEC-20261225-900-P",
        "instrument_type" => "option",
        "base_currency" => "ZEC",
        "quote_currency" => "USDC",
        "is_active" => true,
        "amount_step" => "0.1",
        "tick_size" => "0.1",
        "option_details" => %{"expiry" => 1_798_000_000, "option_type" => "P", "strike" => "900"}
      }
    ]
  end

  defp derive_option_read_response("/private/get_orders") do
    %{
      "result" => %{
        "orders" => [
          %{
            "order_id" => "derive-option-order",
            "instrument_name" => @derive_option_native_id,
            "instrument_type" => "option",
            "amount" => "2",
            "filled_amount" => "0",
            "limit_price" => "0.1",
            "order_status" => "open",
            "direction" => "buy",
            "order_type" => "limit",
            "creation_timestamp" => @observed_timestamp_ms
          }
        ]
      }
    }
  end

  defp derive_option_read_response("/private/get_positions") do
    %{
      "result" => %{
        "positions" => [
          %{
            "instrument_name" => @derive_option_native_id,
            "instrument_type" => "option",
            "amount" => "2",
            "average_price" => "0.1",
            "initial_margin" => "-100",
            "mark_price" => "0.2",
            "unrealized_pnl" => "-2",
            "creation_timestamp" => @observed_timestamp_ms
          }
        ]
      }
    }
  end

  defp derive_option_read_response("/private/get_trade_history") do
    %{
      "result" => %{
        "trades" => [
          %{
            "trade_id" => "derive-option-trade",
            "instrument_name" => @derive_option_native_id,
            "instrument_type" => "option",
            "trade_amount" => "1",
            "trade_price" => "0.1",
            "direction" => "buy",
            "timestamp" => @observed_timestamp_ms
          }
        ]
      }
    }
  end
end
