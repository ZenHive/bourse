defmodule Bourse.PrivateRecordedResponseReplayTest do
  use ExUnit.Case, async: false

  alias Bourse.OracleLabel
  alias Bourse.RecordedResponseFixtures
  alias Bourse.RecordedResponseFixtures.ListBody
  alias Bourse.ReplayExchange
  alias Bourse.Spec
  alias Bourse.Test.FixtureGateIsolation
  alias Bourse.Unified

  @manifest_path "test/fixtures/responses/_manifest.json"
  @external_resource @manifest_path
  @recording_manifest @manifest_path |> File.read!() |> Jason.decode!()
  @private_recording_venues Spec.oracle_venues(:private_real_recordings)
  # Offline byte-replay requires ReplayExchange.build!/3 to construct the venue
  # from a Bourse-parsed markets/currencies cache. A venue's authored
  # `oracles.private_real_recordings` grade is the declared boundary for that
  # capability, so only graded venues are replayed here. Newly-recorded venues
  # whose replay cache source has not yet been re-pointed off the vendored
  # compatibility caches (alpaca, binancecoinm, lighter — recordings captured and
  # manifest-registered; the derivation oracle credits only their populated
  # slots) are excluded until the re-pointing lands (task 524).
  @private_targets Enum.filter(RecordedResponseFixtures.capture_targets(), fn {venue, method} ->
                     venue in @private_recording_venues and
                       RecordedResponseFixtures.capture_category(venue, method) == :private
                   end)
  @write_targets Enum.filter(RecordedResponseFixtures.capture_targets(), fn {venue, method} ->
                   venue in @private_recording_venues and
                     RecordedResponseFixtures.capture_category(venue, method) == :write
                 end)

  setup_all do
    paths =
      (@private_targets ++ @write_targets)
      |> Enum.map(fn {venue, method} -> "#{venue}/#{method}.json" end)
      |> Enum.sort()

    IO.puts([
      "\n",
      OracleLabel.tier1_suite_banner(paths, @recording_manifest, @manifest_path),
      "\n"
    ])

    :ok
  end

  setup do
    Enum.each(@private_recording_venues, &FixtureGateIsolation.isolate!/1)
    :ok
  end

  for {venue, method} <- @private_targets do
    test "#{venue} #{method} replays its authenticated real response offline" do
      fixture = private_fixture(unquote(venue), unquote(method))

      parsed = replay!(fixture, unquote(method))

      assert_private_shape!(unquote(method), parsed, fixture, oracle_identity(fixture))
    end
  end

  for {venue, method} <- @write_targets do
    test "#{venue} #{method} replays create, live-read, and cancel responses offline" do
      fixture = private_fixture(unquote(venue), unquote(method))
      exchange = replay_exchange(unquote(venue))
      [create, read, cancel] = fixture["responses"]
      order_id = recorded_order_id(unquote(venue), create["body"])

      assert %Bourse.Order{id: parsed_id} =
               replay_body!(exchange, fixture, :create_order, fixture["params"], create["body"])

      assert to_string(parsed_id) == to_string(order_id)

      read_params = lifecycle_read_params(unquote(venue), fixture["symbol"], order_id)
      parsed_read = replay_body!(exchange, fixture, lifecycle_read_method(unquote(venue)), read_params, read["body"])

      assert_recorded_order!(parsed_read, order_id, oracle_identity(fixture))

      assert %Bourse.Order{id: canceled_id} =
               replay_body!(
                 exchange,
                 fixture,
                 :cancel_order,
                 %{"id" => to_string(order_id), "symbol" => fixture["symbol"]},
                 cancel["body"]
               )

      assert to_string(canceled_id) == to_string(order_id)
    end
  end

  test "Deribit deposit-address replay preserves the venue's currency and address carriers" do
    # Provider contract declares result.address/currency/type:
    # https://docs.deribit.com/api-reference/upcoming/wallet/private-get_current_deposit_address
    fixture = private_fixture("deribit", :fetch_deposit_address)
    raw = fixture["body"]["result"]

    assert raw["currency"] == "BTC"
    assert raw["address"] == "***REDACTED***"

    assert %Bourse.DepositAddress{
             currency: "BTC",
             address: "***REDACTED***",
             info: %{"type" => "deposit"}
           } = replay!(fixture, :fetch_deposit_address)
  end

  test "Deribit trading-fee replay pins the reachable empty live schedule without inventing fees" do
    # Provider contract makes result.fees optional for discounted users:
    # https://docs.deribit.com/api-reference/account-management/private-get_account_summary
    fixture = private_fixture("deribit", :fetch_trading_fees)

    refute Map.has_key?(fixture["body"]["result"], "fees")
    assert %{} = replay!(fixture, :fetch_trading_fees)
  end

  test "USD-M multi-assets balance replay preserves wallet, margin, and withdrawal axes" do
    fixture = private_fixture("binanceusdm", :fetch_balance)
    assets = fixture["body"]["assets"]
    bnb = Enum.find(assets, &(&1["asset"] == "BNB"))

    assert fixture["host"] == "demo-fapi.binance.com"
    assert Bourse.Safe.number(bnb["availableBalance"]) > Bourse.Safe.number(bnb["walletBalance"])
    assert Bourse.Safe.number(bnb["walletBalance"]) == 0
    assert Bourse.Safe.number(bnb["initialMargin"]) == 0
    assert Bourse.Safe.number(bnb["maxWithdrawAmount"]) == 0

    balance = replay!(fixture, :fetch_balance)

    assert balance.free == keyed_numbers(assets, "maxWithdrawAmount")
    assert balance.used == keyed_numbers(assets, "initialMargin")
    assert balance.total == keyed_numbers(assets, "walletBalance")
    assert balance.free["BNB"] == 0
    assert balance.used["BNB"] == 0
    assert balance.total["BNB"] == 0
    assert Enum.all?(balance.used, fn {_asset, used} -> used >= 0 end)
  end

  test "populated private trade recordings preserve venue identifiers, sizes, prices, and clocks" do
    for {venue, raw_path, expected} <- populated_trade_cases() do
      fixture = private_fixture(venue, :fetch_my_trades)
      raw = get_in(fixture, ["body" | raw_path])
      trades = replay!(fixture, :fetch_my_trades)

      assert [%Bourse.Trade{} | _] = trades

      assert Enum.any?(trades, fn trade ->
               to_string(trade.id) == to_string(raw[expected.id]) and
                 trade.price == Bourse.Safe.number(raw[expected.price]) and
                 trade.amount == Bourse.Safe.number(raw[expected.amount]) and
                 trade.timestamp == Bourse.Safe.integer(raw[expected.timestamp])
             end),
             "#{oracle_identity(fixture)} did not preserve the first populated raw trade: #{inspect(raw)}"
    end
  end

  test "populated open-order recordings bind venue wire fields onto the unified order" do
    for {venue, raw_path, expected} <- populated_order_cases() do
      fixture = private_fixture(venue, :fetch_open_orders)
      raw = get_in(fixture, ["body" | raw_path])
      identity = oracle_identity(fixture)

      assert [%Bourse.Order{} | _] = orders = replay!(fixture, :fetch_open_orders)

      order =
        Enum.find(orders, &(to_string(&1.id) == to_string(raw[expected.id]))) ||
          flunk("#{identity} dropped the recorded resting order: #{inspect(raw)}")

      # Expected side recomputed from the captured real body (task-180 independence).
      assert order.price == Bourse.Safe.number(raw[expected.price]), identity
      assert order.amount == Bourse.Safe.number(raw[expected.amount]), identity
      assert order.timestamp == Bourse.Safe.integer(raw[expected.timestamp]), identity
      assert order.client_order_id == raw[expected.client_order_id], identity

      # Venue vocabulary is normalized, not passed through verbatim.
      assert order.status == expected.status, identity
      assert order.side == expected.side, identity
      assert order.type == expected.type, identity
      assert order.symbol == expected.symbol, identity
    end
  end

  test "populated position recordings bind at least one venue wire field" do
    for {venue, raw_path, expected} <- populated_position_cases() do
      fixture = private_fixture(venue, :fetch_positions)
      raw = get_in(fixture, ["body" | raw_path])
      identity = oracle_identity(fixture)

      assert fixture["body_populated"] == true, identity
      assert [%Bourse.Position{} | _] = positions = replay!(fixture, :fetch_positions)

      position =
        Enum.find(positions, fn pos ->
          to_string(pos.symbol) == expected.symbol or
            (is_map(pos.info) and to_string(pos.info[expected.id_key]) == to_string(raw[expected.id_key]))
        end) || flunk("#{identity} dropped the recorded position row: #{inspect(raw)}")

      assert ListBody.binds_wire_row?(position, raw), identity
      assert position.symbol == expected.symbol, identity
      assert position.contracts == expected.contracts, identity
    end
  end

  test "OKX option position contracts derive from observed pos, ctVal, and ctMult" do
    fixture = private_fixture("okx", :fetch_positions)
    raw_position = get_in(fixture, ["body", "data", Access.at(0)])
    raw_market = get_in(fixture, ["market_context", "raw"])
    [position] = replay!(fixture, :fetch_positions)

    expected =
      raw_position["pos"]
      |> Bourse.Precise.string_mul(raw_market["ctVal"])
      |> Bourse.Precise.string_mul(raw_market["ctMult"])
      |> Bourse.Safe.number()

    assert raw_position["pos"] == "1"
    assert position.contracts == expected
    assert position.contracts == 0.01
  end

  test "empty-body list fixtures are shape-only evidence, not silent tier-1 value cells" do
    empty_cases =
      for {venue, method} <- @private_targets,
          method in ListBody.list_methods(),
          fixture = private_fixture(venue, method),
          fixture["body_populated"] == false do
        {venue, method, fixture}
      end

    assert empty_cases != [], "expected at least one empty-body list fixture in the corpus"

    for {_venue, method, fixture} <- empty_cases do
      identity = oracle_identity(fixture)
      assert ListBody.body_populated?(fixture["body"]) == false, identity

      fn ->
        parsed = replay!(fixture, method)
        assert_private_shape!(method, parsed, fixture, identity)
      end
      |> ExUnit.CaptureIO.capture_io()
      |> then(fn output ->
        assert output =~ ListBody.shape_only_marker(),
               "missing shape-only marker for #{identity}: #{inspect(output)}"
      end)
    end
  end

  test "declared-populated fixture with an emptied body fails instead of staying green" do
    fixture =
      "bybit"
      |> private_fixture(:fetch_my_trades)
      |> Map.put("body_populated", true)
      |> Map.put("body", %{"result" => %{"list" => []}, "retCode" => 0})

    identity = oracle_identity(fixture)
    parsed = []

    assert_raise ExUnit.AssertionError, ~r/silent tier-1 → shape-only downgrade/, fn ->
      assert_private_shape!(:fetch_my_trades, parsed, fixture, identity)
    end
  end

  test "a populated position may parse empty only when its recorded size is zero" do
    fixture =
      "binanceusdm"
      |> private_fixture(:fetch_positions)
      |> update_in(["body", Access.at(0), "positionAmt"], fn _contracts -> "1.0" end)

    assert_raise ExUnit.AssertionError, ~r/non-zero recorded positionAmt/, fn ->
      assert_private_shape!(:fetch_positions, [], fixture, oracle_identity(fixture))
    end
  end

  defp populated_position_cases do
    [
      {"bybit", ["result", "list", Access.at(0)],
       %{contracts: 0.01, id_key: "symbol", symbol: "BTC/USDT:USDT-270625-150000-C"}},
      {"deribit", ["result", Access.at(0)],
       %{contracts: 0.1, id_key: "instrument_name", symbol: "BTC/USD:BTC-260731-65000-C"}},
      {"okx", ["data", Access.at(0)], %{contracts: 0.01, id_key: "posId", symbol: "BTC/USD:BTC-260724-67000-C"}}
    ]
  end

  defp populated_order_cases do
    common = %{
      id: "orderId",
      price: "price",
      amount: "origQty",
      timestamp: "time",
      client_order_id: "clientOrderId",
      status: "open",
      side: "buy",
      type: "limit"
    }

    [
      {"binance", [Access.at(0)], Map.put(common, :symbol, "BTC/USDT")},
      {"binanceusdm", [Access.at(0)], Map.put(common, :symbol, "BTC/USDT:USDT")}
    ]
  end

  defp populated_trade_cases do
    [
      {"binanceusdm", [Access.at(0)], %{id: "id", price: "price", amount: "qty", timestamp: "time"}},
      {"bybit", ["result", "list", Access.at(0)],
       %{id: "execId", price: "execPrice", amount: "execQty", timestamp: "execTime"}},
      {"hyperliquid", [Access.at(0)], %{id: "tid", price: "px", amount: "sz", timestamp: "time"}}
    ]
  end

  defp private_fixture(venue, method) do
    venue
    |> RecordedResponseFixtures.fixture_path(method)
    |> RecordedResponseFixtures.load_fixture!()
  end

  defp replay!(fixture, method) do
    exchange = replay_exchange(fixture)
    replay_body!(exchange, fixture, method, fixture["params"], fixture["body"])
  end

  defp replay_body!(exchange, fixture, method, params, body) do
    stub = {__MODULE__, fixture["exchange"], method, System.unique_integer([:positive])}
    Req.Test.stub(stub, fn conn -> Req.Test.json(conn, body) end)

    opts =
      fixture
      |> RecordedResponseFixtures.decode_call_opts()
      |> Keyword.put(:plug, {Req.Test, stub})

    result = Unified.call(exchange, method, js_name(method), params, opts)

    case result do
      {:ok, parsed} -> parsed
      {:error, reason} -> flunk("#{oracle_identity(fixture)} replay failed: #{inspect(reason)}")
    end
  end

  defp replay_exchange(%{"exchange" => venue, "market_context" => %{"normalized" => market}}) do
    venue
    |> replay_exchange()
    |> Bourse.Exchange.put_markets([market_from_context(market)])
  end

  defp replay_exchange(%{"exchange" => venue}), do: replay_exchange(venue)

  defp replay_exchange("derive" = venue) do
    exchange = ReplayExchange.build!(venue, %{})
    %{exchange | options: Map.put(exchange.options, "subaccount_id", 1)}
  end

  defp replay_exchange(venue), do: ReplayExchange.build!(venue, %{})

  defp market_from_context(market) do
    %Bourse.Market{
      id: market["id"],
      symbol: market["symbol"],
      option: market["option"],
      contract_size: market["contract_size"],
      quantity_unit: market["quantity_unit"],
      native_quantity_unit: market["native_quantity_unit"],
      native_quantity_field: market["native_quantity_field"],
      native_amount_step: market["native_amount_step"],
      precision: market["precision"]
    }
  end

  defp recorded_order_id("bybit", body), do: get_in(body, ["result", "orderId"])
  defp recorded_order_id(venue, body) when venue in ["binance", "binanceusdm"], do: body["orderId"]

  defp lifecycle_read_method("bybit"), do: :fetch_open_orders
  defp lifecycle_read_method(venue) when venue in ["binance", "binanceusdm"], do: :fetch_order

  defp lifecycle_read_params("bybit", symbol, _order_id), do: %{"symbol" => symbol}

  defp lifecycle_read_params(venue, symbol, order_id) when venue in ["binance", "binanceusdm"],
    do: %{"id" => to_string(order_id), "symbol" => symbol}

  defp keyed_numbers(rows, value_key) do
    Map.new(rows, fn row -> {row["asset"], Bourse.Safe.number(row[value_key])} end)
  end

  defp assert_recorded_order!(%Bourse.Order{id: id}, order_id, identity) do
    assert to_string(id) == to_string(order_id), identity
  end

  defp assert_recorded_order!(orders, order_id, identity) when is_list(orders) do
    assert Enum.any?(orders, &(to_string(&1.id) == to_string(order_id))), identity
  end

  defp js_name(method) do
    Enum.find_value(Unified.method_defs(), fn
      {^method, js_name, _params, _description} -> js_name
      _other -> nil
    end)
  end

  defp assert_private_shape!(:fetch_balance, parsed, _fixture, identity) do
    assert %Bourse.Balance{} = parsed, identity
  end

  defp assert_private_shape!(:fetch_deposit_address, parsed, _fixture, identity) do
    assert %Bourse.DepositAddress{} = parsed, identity
  end

  defp assert_private_shape!(:fetch_trading_fees, parsed, _fixture, identity) do
    assert is_map(parsed), identity
    assert Enum.all?(parsed, fn {_symbol, fee} -> match?(%Bourse.TradingFee{}, fee) end), identity
  end

  defp assert_private_shape!(:fetch_position_adl_rank, parsed, fixture, identity) do
    assert fixture["body"] == %{}, identity
    assert is_nil(parsed), identity
  end

  defp assert_private_shape!(method, parsed, fixture, identity)
       when method in [:fetch_open_orders, :fetch_canceled_orders, :fetch_positions, :fetch_my_trades, :fetch_ledger] do
    recording = recording_for(fixture)
    declared = ListBody.declared_populated?(fixture, recording)
    actual = ListBody.body_populated?(fixture["body"])

    assert is_list(parsed), identity
    assert Enum.all?(parsed, &(Map.get(&1, :__struct__) == expected_private_struct(method))), identity

    cond do
      declared and not actual ->
        flunk(
          "#{identity} declared body_populated=true but the recorded body is empty — " <>
            "silent tier-1 → shape-only downgrade (re-capture emptied a populated cell)"
        )

      not actual ->
        IO.puts("  #{ListBody.shape_only_marker()} — #{identity}")
        assert parsed == [], identity

      true ->
        raw_row = ListBody.first_wire_row(fixture["body"])

        assert is_map(raw_row) and map_size(raw_row) > 0,
               "#{identity} declared populated but no wire row was found under the body"

        assert_list_value_binding!(method, parsed, raw_row, identity)
    end
  end

  defp expected_private_struct(:fetch_open_orders), do: Bourse.Order
  defp expected_private_struct(:fetch_canceled_orders), do: Bourse.Order
  defp expected_private_struct(:fetch_positions), do: Bourse.Position
  defp expected_private_struct(:fetch_my_trades), do: Bourse.Trade
  defp expected_private_struct(:fetch_ledger), do: Bourse.LedgerEntry

  defp assert_list_value_binding!(:fetch_positions, [], %{"positionAmt" => contracts}, identity) do
    assert Bourse.Safe.number(contracts) == 0,
           "#{identity} parsed an empty position list from a non-zero recorded positionAmt=#{inspect(contracts)}"

    IO.puts("  populated-body: zero positionAmt bound to filtered-empty result — #{identity}")
  end

  defp assert_list_value_binding!(_method, parsed, raw_row, identity) when is_list(parsed) do
    assert Enum.any?(parsed, &ListBody.binds_wire_row?(&1, raw_row)),
           "#{identity} populated body did not bind any value from the first raw wire row: #{inspect(raw_row)}"
  end

  defp recording_for(fixture) do
    venue = fixture["exchange"] || fixture["venue"]
    method = to_string(fixture["method"])

    Enum.find(@recording_manifest["recordings"] || [], fn recording ->
      recording["venue"] == venue and to_string(recording["method"]) == method
    end)
  end

  defp oracle_identity(fixture) do
    OracleLabel.tier1_label_from_fixture(fixture, @recording_manifest, @manifest_path)
  end
end
