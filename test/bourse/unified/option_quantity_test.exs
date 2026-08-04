defmodule Bourse.Unified.OptionQuantityTest do
  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Order
  alias Bourse.Position
  alias Bourse.Spec.Schema
  alias Bourse.Unified.OptionQuantity

  describe "authored semantics" do
    test "declare one canonical unit and explicit native conversion" do
      expected = %{
        "deribit" => {"amount", "base"},
        "okx" => {"sz", "contracts"},
        "bybit" => {"qty", "base"},
        "derive" => {"amount", "base"}
      }

      for {exchange_id, {wire_field, wire_unit}} <- expected do
        spec = Bourse.Spec.load!(exchange_id)
        config = get_in(spec, ["markets", "option_quantity"])

        assert config["canonical_unit"] == "base"
        assert config["wire_field"] == wire_field
        assert config["wire_unit"] == wire_unit
        assert Schema.validate!(spec, exchange_id) == spec
      end
    end

    test "reject missing multipliers and non-canonical units" do
      okx = Bourse.Spec.load!("okx")

      assert_raise ArgumentError, ~r/markets\.option_quantity\.contract_size/, fn ->
        Schema.validate!(put_in(okx, ["markets", "option_quantity", "contract_size"], nil), "okx")
      end

      assert_raise ArgumentError, ~r/markets\.option_quantity.*canonical base unit/, fn ->
        Schema.validate!(put_in(okx, ["markets", "option_quantity", "canonical_unit"], "contracts"), "okx")
      end
    end
  end

  describe "normalize_market/3" do
    test "exchange construction carries the authored venue semantics" do
      assert %Exchange{
               config: %{
                 "option_quantity" => %{
                   "canonical_unit" => "base",
                   "wire_field" => "sz",
                   "wire_unit" => "contracts"
                 }
               }
             } = Exchange.new!("okx")
    end

    test "authors Deribit base amount and alternate contract exposure from contract_size" do
      market = option_market(precision: %{"amount" => 0.1}, limits: %{"amount" => %{"min" => 0.1, "max" => nil}})
      exchange = exchange("deribit", base_config("amount", %{"kind" => "field", "field" => "contract_size"}))

      normalized = OptionQuantity.normalize_market(market, %{"contract_size" => "1"}, exchange)

      assert normalized.quantity_unit == "base"
      assert normalized.native_quantity_unit == "base"
      assert normalized.native_quantity_field == "amount"
      assert normalized.native_amount_step == 0.1
      assert normalized.contract_size == 1
      assert normalized.precision == market.precision
      assert normalized.limits == market.limits
      assert_option_identity(normalized)
    end

    test "authors OKX contract counts and scales precision and limits to base exposure" do
      market =
        option_market(
          precision: %{"amount" => 1, "price" => 0.0001},
          limits: %{"amount" => %{"min" => 1, "max" => 500}}
        )

      exchange =
        exchange(
          "okx",
          contracts_config("sz", %{"kind" => "product", "fields" => ["ctVal", "ctMult"]})
        )

      normalized = OptionQuantity.normalize_market(market, %{"ctVal" => "1", "ctMult" => "0.01"}, exchange)

      assert normalized.quantity_unit == "base"
      assert normalized.native_quantity_unit == "contracts"
      assert normalized.native_quantity_field == "sz"
      assert normalized.native_amount_step == 1
      assert normalized.contract_size == 0.01
      assert normalized.precision == %{"amount" => 0.01, "price" => 0.0001}
      assert normalized.limits == %{"amount" => %{"min" => 0.01, "max" => 5}}
      assert_option_identity(normalized)
    end

    test "authors Bybit and Derive base-quantity steps without inventing a multiplier" do
      for {id, field, step} <- [{"bybit", "qty", 0.01}, {"derive", "amount", 0.1}] do
        market =
          if id == "bybit" do
            option_market(
              symbol: "BTC/USDT:USDT-270625-150000-P",
              strike: nil,
              option_type: nil,
              precision: %{"amount" => step},
              limits: %{}
            )
          else
            option_market(precision: %{"amount" => step}, limits: %{})
          end

        normalized = OptionQuantity.normalize_market(market, %{}, exchange(id, base_config(field, nil)))

        assert normalized.native_quantity_unit == "base"
        assert normalized.native_quantity_field == field
        assert normalized.native_amount_step == step
        assert normalized.contract_size == nil
        assert normalized.precision == %{"amount" => step}

        if id == "bybit" do
          assert normalized.strike == 150_000
          assert normalized.option_type == "put"
        end
      end
    end

    test "normalizes provider option-type spellings and tolerates native-only symbols" do
      exchange = exchange("bybit", base_config("qty", nil))

      for {provider_type, unified_type} <- [
            {"C", "call"},
            {"P", "put"},
            {"Call", "call"},
            {"Put", "put"}
          ] do
        normalized =
          [option_type: provider_type]
          |> option_market()
          |> OptionQuantity.normalize_market(%{}, exchange)

        assert normalized.option_type == unified_type
      end

      native = option_market(symbol: "NATIVE-OPTION", option_type: "call")
      assert OptionQuantity.normalize_market(native, %{}, exchange).option_type == "call"

      symbol_less = option_market(symbol: nil, option_type: "put")
      assert OptionQuantity.normalize_market(symbol_less, %{}, exchange).option_type == "put"
    end

    test "leaves non-option and unauthored markets unchanged" do
      spot = %Market{option: false, precision: %{"amount" => 0.01}}
      option = option_market()

      assert OptionQuantity.normalize_market(spot, %{}, exchange("okx", contracts_config("sz", nil))) == spot
      assert OptionQuantity.normalize_market(option, %{}, exchange("binance", nil)) == option
    end

    test "fails loudly when an authored multiplier is missing or invalid" do
      market = option_market()
      product = contracts_config("sz", %{"kind" => "product", "fields" => ["ctVal", "ctMult"]})
      field = base_config("amount", %{"kind" => "field", "field" => "contract_size"})

      assert_raise ArgumentError, ~r/missing option contract multiplier/, fn ->
        OptionQuantity.normalize_market(market, %{"ctVal" => "1"}, exchange("okx", product))
      end

      assert_raise ArgumentError, ~r/missing option contract multiplier/, fn ->
        OptionQuantity.normalize_market(market, %{"contract_size" => 0}, exchange("deribit", field))
      end

      assert_raise ArgumentError, ~r/missing option contract multiplier/, fn ->
        OptionQuantity.normalize_market(market, %{}, exchange("unknown", base_config("amount", %{})))
      end
    end
  end

  describe "exact conversion" do
    test "representable contract quantities round-trip exactly" do
      market = contracts_market()

      assert {:ok, 3} = OptionQuantity.to_native(market, "0.03")
      assert {:ok, 0.03} = OptionQuantity.from_native(market, 3)
      assert {:ok, 0} = OptionQuantity.from_native(market, 0)
      assert {:ok, 200} = OptionQuantity.to_native(%{market | contract_size: "0.0001"}, 0.02)
    end

    test "representable base quantities round-trip without a multiplier" do
      market = base_market()

      assert {:ok, 0.02} = OptionQuantity.to_native(market, 0.02)
      assert {:ok, 0.02} = OptionQuantity.from_native(market, "0.02")
    end

    test "Deribit alternate contracts round-trip through contract_size" do
      market = %{base_market() | contract_size: 0.01}

      assert {:ok, 2} = OptionQuantity.to_contracts(market, 0.02)
      assert {:ok, 0.02} = OptionQuantity.from_contracts(market, 2)
      assert {:ok, 2} = OptionQuantity.to_contracts(contracts_market(), 0.02)
    end

    test "non-representable values return an explicit quantization error" do
      market = contracts_market()

      assert {:error, %Error{type: :invalid_order, raw: %{"reason" => "quantization_error"}}} =
               OptionQuantity.to_native(market, 0.015)

      assert {:error, %Error{type: :invalid_order, raw: %{"reason" => "quantization_error"}}} =
               OptionQuantity.from_native(market, 1.5)
    end

    test "missing or invalid semantics fail explicitly instead of defaulting to one" do
      assert {:error, %Error{raw: %{"reason" => "missing_quantity_semantics"}}} =
               OptionQuantity.to_native(option_market(), 1)

      assert {:error, %Error{raw: %{"reason" => "missing_contract_size"}}} =
               OptionQuantity.to_native(%{contracts_market() | contract_size: nil}, 1)

      assert {:error, %Error{raw: %{"reason" => "missing_contract_size"}}} =
               OptionQuantity.to_contracts(base_market(), 1)

      assert {:error, %Error{raw: %{"reason" => "invalid_quantity"}}} =
               OptionQuantity.to_native(base_market(), 0)

      assert {:error, %Error{raw: %{"reason" => "invalid_quantity"}}} =
               OptionQuantity.to_native(base_market(), "not-a-number")
    end
  end

  describe "request and response conversion" do
    test "converts unified option amount before request shaping" do
      market = contracts_market()
      exchange = %{exchange("okx", nil) | markets: [market]}

      assert %{"amount" => 3} =
               OptionQuantity.to_native_request!(
                 %{"symbol" => market.symbol, "amount" => 0.03, "category" => "option"},
                 exchange,
                 "createOrder"
               )

      assert_raise Error, ~r/quantization_error/, fn ->
        OptionQuantity.to_native_request!(
          %{"symbol" => market.symbol, "amount" => 0.015, "category" => "option"},
          exchange,
          "createOrder"
        )
      end

      unchanged = %{"symbol" => market.symbol, "amount" => 0.03}
      assert OptionQuantity.to_native_request!(unchanged, exchange, "fetchOrder") == unchanged
      assert OptionQuantity.to_native_request!(unchanged, exchange("okx", nil), "createOrder") == unchanged
    end

    test "converts every batch row using its own option market" do
      first = contracts_market(symbol: "BTC/USD:BTC-260723-59000-C", id: "BTC-USD-260723-59000-C")
      second = %{first | symbol: "ETH/USD:ETH-260723-3000-P", id: "ETH-USD-260723-3000-P", contract_size: 0.1}
      exchange = %{exchange("okx", nil) | markets: [first, second]}

      params = %{
        "category" => "option",
        "orders" => [
          %{"symbol" => first.symbol, "amount" => 0.02},
          %{"symbol" => second.symbol, "amount" => 0.2}
        ]
      }

      assert %{"orders" => [%{"amount" => 2}, %{"amount" => 2}]} =
               OptionQuantity.to_native_request!(params, exchange, "createOrders")
    end

    test "rejects an unmatched explicitly-option request and ignores non-option amounts" do
      exchange = %{
        exchange("okx", nil)
        | markets: [nil, %Market{id: "BTC-USDT", symbol: "BTC/USDT", option: false}]
      }

      assert_raise Error, ~r/market_not_found/, fn ->
        OptionQuantity.to_native_request!(
          %{"symbol" => "missing", "amount" => 1, "category" => "option"},
          exchange,
          "createOrder"
        )
      end

      params = %{"symbol" => "BTC/USDT", "amount" => 1}
      assert OptionQuantity.to_native_request!(params, exchange, "createOrder") == params

      assert OptionQuantity.to_native_request!(Map.delete(params, "amount"), exchange, "createOrder") ==
               Map.delete(params, "amount")
    end

    test "converts option order result quantities and preserves identity fields" do
      market = contracts_market()
      exchange = %{exchange("okx", nil) | markets: [market]}

      order = %Order{
        id: "order-1",
        symbol: market.symbol,
        amount: 3,
        filled: 1,
        remaining: 2,
        price: 0.001,
        info: %{"sz" => "3"}
      }

      assert [%Order{} = converted] = OptionQuantity.from_native_result!([order], exchange)
      assert converted.amount == 0.03
      assert converted.filled == 0.01
      assert converted.remaining == 0.02
      assert converted.id == order.id
      assert converted.symbol == order.symbol
      assert converted.price == order.price
      assert converted.info == order.info
    end

    test "converts position quantities for every authored first-class option venue" do
      okx_market = contracts_market()
      deribit_market = base_market("BTC/USD:BTC-260731-65000-C", "BTC-31JUL26-65000-C", "amount", 0.1)
      bybit_market = base_market("BTC/USDT:USDT-260807-65000-C", "BTC-08AUG26-65000-C-USDT", "qty", 0.01)
      derive_market = base_market("ETH/USDC:USDC-260731-2400-C", "ETH-20260731-2400-C", "amount", 0.1)

      cases = [
        {"okx", okx_market, 19, 0.19},
        {"deribit", deribit_market, 0.1, 0.1},
        {"bybit", bybit_market, 0.01, 0.01},
        {"derive", derive_market, 0.1, 0.1}
      ]

      for {venue_id, market, native_contracts, expected_contracts} <- cases do
        position = %Position{symbol: market.symbol, contracts: native_contracts}
        venue = %{exchange(venue_id, nil) | markets: [market]}

        assert %Position{contracts: ^expected_contracts} =
                 OptionQuantity.from_native_result!(position, venue)
      end
    end

    test "leaves authored base-unit positions unchanged without order quantization metadata" do
      market = %Market{
        id: "BTC-31JUL26-65000-C",
        symbol: "BTC/USD:BTC-260731-65000-C",
        option: true
      }

      position = %Position{symbol: market.symbol, contracts: 0.03}
      venue = %{exchange("deribit", base_config("amount", nil)) | markets: [market]}

      assert OptionQuantity.from_native_result!(position, venue) == position
    end

    test "leaves a contracts-unit option position with nil contracts unchanged" do
      market = contracts_market()
      position = %Position{symbol: market.symbol, contracts: nil}
      venue = %{exchange("okx", nil) | markets: [market]}

      assert OptionQuantity.from_native_result!(position, venue) == position
    end

    test "leaves an option position whose market declares no quantity unit unchanged" do
      market = %Market{
        id: "BTC-31JUL26-65000-C",
        symbol: "BTC/USD:BTC-260731-65000-C",
        option: true,
        native_quantity_unit: nil
      }

      position = %Position{symbol: market.symbol, contracts: 0.1}
      venue = %{exchange("deribit", nil) | markets: [market]}

      assert OptionQuantity.from_native_result!(position, venue) == position
    end

    test "leaves non-option, nil quantities, and non-order results unchanged" do
      option = contracts_market()
      spot = %Market{id: "BTC-USDT", symbol: "BTC/USDT", option: false}
      exchange = %{exchange("okx", nil) | markets: [option, spot]}
      sparse = %Order{symbol: option.symbol}
      spot_order = %Order{symbol: spot.symbol, amount: 1}

      assert OptionQuantity.from_native_result!(sparse, exchange) == sparse
      assert OptionQuantity.from_native_result!(spot_order, exchange) == spot_order
      assert OptionQuantity.from_native_result!(%{"data" => []}, exchange) == %{"data" => []}
    end
  end

  defp option_market(overrides \\ []) do
    struct!(
      Market,
      Keyword.merge(
        [
          id: "BTC-USD-260723-59000-C",
          symbol: "BTC/USD:BTC-260723-59000-C",
          base: "BTC",
          quote: "USD",
          settle: "BTC",
          option: true,
          contract: true,
          expiry: 1_784_793_600_000,
          strike: 59_000,
          option_type: "call",
          precision: %{"amount" => 0.1},
          limits: %{"amount" => %{"min" => 0.1, "max" => nil}}
        ],
        overrides
      )
    )
  end

  defp contracts_market(overrides \\ []) do
    struct!(
      option_market(),
      Keyword.merge(
        [
          quantity_unit: "base",
          native_quantity_unit: "contracts",
          native_quantity_field: "sz",
          native_amount_step: 1,
          contract_size: 0.01,
          precision: %{"amount" => 0.01}
        ],
        overrides
      )
    )
  end

  defp base_market do
    %{
      option_market()
      | quantity_unit: "base",
        native_quantity_unit: "base",
        native_quantity_field: "qty",
        native_amount_step: 0.01,
        precision: %{"amount" => 0.01}
    }
  end

  defp base_market(symbol, id, native_quantity_field, amount_step) do
    %{
      option_market(symbol: symbol, id: id)
      | quantity_unit: "base",
        native_quantity_unit: "base",
        native_quantity_field: native_quantity_field,
        native_amount_step: amount_step,
        precision: %{"amount" => amount_step}
    }
  end

  defp exchange(id, option_quantity) do
    %Exchange{id: id, name: id, config: %{"option_quantity" => option_quantity}}
  end

  defp base_config(field, contract_size) do
    %{
      "canonical_unit" => "base",
      "wire_unit" => "base",
      "wire_field" => field,
      "contract_size" => contract_size
    }
  end

  defp contracts_config(field, contract_size) do
    %{
      "canonical_unit" => "base",
      "wire_unit" => "contracts",
      "wire_field" => field,
      "contract_size" => contract_size
    }
  end

  defp assert_option_identity(market) do
    assert market.base == "BTC"
    assert market.settle == "BTC"
    assert market.expiry == 1_784_793_600_000
    assert market.strike == 59_000
    assert market.option_type == "call"
  end
end
