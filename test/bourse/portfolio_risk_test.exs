defmodule Bourse.PortfolioRiskTest do
  use ExUnit.Case, async: false

  alias Bourse.Credentials
  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.PortfolioRisk
  alias Bourse.PortfolioRisk.Snapshot
  alias Bourse.Test.FixtureGateIsolation

  @observed_at 1_800_000_000_000

  setup do
    FixtureGateIsolation.isolate!("deribit")
    :ok
  end

  test "builds a complete populated snapshot and keeps account state in its domain" do
    stub = snapshot_stub()
    exchange = exchange_with_markets()
    scope = PortfolioRisk.scope(exchange, "main", plug: {Req.Test, stub})

    assert {:ok, %Snapshot{status: :complete} = snapshot} =
             PortfolioRisk.snapshot([scope], observed_at: @observed_at)

    assert snapshot.failures == []
    assert snapshot.blocked_buckets == []
    assert [%{venue: "deribit", account: "main"} = domain] = snapshot.domains
    assert domain.components.balance.status == :ok
    assert domain.components.positions.data == []
    assert domain.components.open_orders.data == []
    assert {:ok, capacity} = domain.available_capacity
    assert is_number(capacity["BTC"])

    assert Enum.any?(snapshot.contributions, fn contribution ->
             contribution.source == :balance and contribution.underlying == "BTC" and
               contribution.greeks.delta.value > 0
           end)

    assert Enum.any?(snapshot.aggregates, fn aggregate ->
             aggregate.status == :complete and aggregate.bucket.underlying == "BTC"
           end)
  end

  test "a bare scope map without request_opts is accepted per the optional typespec" do
    exchange = Map.put(exchange_with_markets(), :base_urls, %{"rest" => "http://127.0.0.1:1"})

    assert {:ok, %Snapshot{status: :partial} = snapshot} =
             PortfolioRisk.snapshot([%{exchange: exchange, account: "main"}],
               observed_at: @observed_at
             )

    assert [%{venue: "deribit", account: "main"} = domain] = snapshot.domains
    assert domain.components.balance.status == :error
    assert Enum.any?(snapshot.failures, &(&1.component == :balance))
  end

  test "a failed component remains queryable and cannot masquerade as zero exposure" do
    stub = snapshot_stub(fail_path: "/api/v2/private/get_positions")
    scope = PortfolioRisk.scope(exchange_with_markets(), "main", plug: {Req.Test, stub})

    assert {:ok, %Snapshot{status: :partial} = snapshot} =
             PortfolioRisk.snapshot([scope], observed_at: @observed_at)

    assert [%{components: components} = domain] = snapshot.domains
    assert components.balance.status == :ok
    assert components.positions.status == :error
    assert components.positions.error.type == :network_error
    assert {:error, %Bourse.Error{type: :network_error}} = domain.margin

    assert Enum.any?(snapshot.failures, &(&1.component == :positions))
    assert Enum.any?(snapshot.contributions, &(&1.source == :balance))
  end

  test "venue/account domains never net margin, collateral, capacity, modes, or liquidation state" do
    first = PortfolioRisk.scope(exchange_with_markets(), "account-a", plug: {Req.Test, snapshot_stub()})
    second = PortfolioRisk.scope(exchange_with_markets(), "account-b", plug: {Req.Test, snapshot_stub()})

    assert {:ok, %Snapshot{domains: [a, b]}} =
             PortfolioRisk.snapshot([first, second], observed_at: @observed_at)

    assert {a.venue, a.account} == {"deribit", "account-a"}
    assert {b.venue, b.account} == {"deribit", "account-b"}
    assert match?({:ok, _}, a.margin)
    assert match?({:ok, _}, b.margin)
    assert match?({:ok, _}, a.available_capacity)
    assert match?({:ok, _}, b.available_capacity)
    refute Map.has_key?(Map.from_struct(%Snapshot{status: :complete, observed_at: @observed_at}), :margin)
  end

  test "option positions and pending orders contribute signed Greeks with domain provenance" do
    market = option_market()
    stub = option_snapshot_stub(@observed_at - 1)
    scope = PortfolioRisk.scope(exchange_with_markets([market]), "options", plug: {Req.Test, stub})

    assert {:ok, %Snapshot{status: :complete} = snapshot} =
             PortfolioRisk.snapshot([scope], observed_at: @observed_at)

    assert [%{margin: {:ok, [margin]}, liquidation_state: {:ok, [liquidation]}}] = snapshot.domains
    assert is_binary(margin.symbol)
    assert margin.initial_margin == 0.01
    assert liquidation.liquidation_price == 10_000.0

    position = Enum.find(snapshot.contributions, &(&1.source == :position))
    order = Enum.find(snapshot.contributions, &(&1.source == :open_order))

    assert position.account == "options"
    assert position.venue == "deribit"
    assert position.underlying == "BTC"
    assert position.quantity == 0.03
    assert position.greeks.delta.value == 0.015
    assert position.source_timestamp == @observed_at - 1
    assert position.observed_at == @observed_at

    assert order.pending
    assert order.quantity == -0.02
    assert order.greeks.delta.value == -0.01
    assert order.source_timestamp == @observed_at - 1
  end

  test "a missing Greek blocks only rho while other option buckets remain complete" do
    market = option_market()
    stub = option_snapshot_stub(@observed_at - 1, omit_rho: true)
    scope = PortfolioRisk.scope(exchange_with_markets([market]), "options", plug: {Req.Test, stub})

    assert {:ok, %Snapshot{status: :partial} = snapshot} =
             PortfolioRisk.snapshot([scope], observed_at: @observed_at)

    assert Enum.all?(snapshot.blocked_buckets, &(&1.bucket.greek == :rho))
    assert Enum.all?(snapshot.blocked_buckets, &(&1.reason == {:missing_greek, :rho}))

    rho = Enum.find(snapshot.aggregates, &(&1.bucket.greek == :rho))
    delta = Enum.find(snapshot.aggregates, &(&1.bucket.greek == :delta))
    assert rho.status == :blocked
    assert rho.value == nil
    assert delta.status == :complete
  end

  test "stale Greeks block only option buckets and leave balance exposure queryable" do
    market = option_market()
    stub = option_snapshot_stub(@observed_at - 60_000)
    scope = PortfolioRisk.scope(exchange_with_markets([market]), "options", plug: {Req.Test, stub})

    assert {:ok, %Snapshot{status: :partial} = snapshot} =
             PortfolioRisk.snapshot([scope], observed_at: @observed_at, max_age_ms: 1_000)

    assert length(snapshot.blocked_buckets) == 10
    assert Enum.all?(snapshot.blocked_buckets, &match?(%Bourse.Error{type: :operation_failed}, &1.reason))
    assert Enum.any?(snapshot.contributions, &(&1.source == :balance))
    refute Enum.any?(snapshot.contributions, &(&1.source in [:position, :open_order]))
  end

  test "loads missing market metadata before reading account components" do
    stub = market_loading_stub()
    exchange = %{exchange_with_markets() | markets: nil}
    scope = PortfolioRisk.scope(exchange, "main", plug: {Req.Test, stub})

    assert {:ok, %Snapshot{status: :complete} = snapshot} =
             PortfolioRisk.snapshot([scope], observed_at: @observed_at)

    assert [%{components: %{markets: %{status: :ok, data: [%Market{} = market]}}}] = snapshot.domains
    assert market.symbol == "BTC/USD:BTC"
  end

  test "market-read failure does not erase successful private components" do
    stub = option_snapshot_stub(@observed_at - 1, fail_markets: true)
    exchange = %{exchange_with_markets() | markets: nil}
    scope = PortfolioRisk.scope(exchange, "main", plug: {Req.Test, stub})

    assert {:ok, %Snapshot{status: :partial} = snapshot} =
             PortfolioRisk.snapshot([scope], observed_at: @observed_at)

    assert [%{components: components}] = snapshot.domains
    assert components.markets.status == :error
    assert components.balance.status == :ok
    assert components.positions.status == :ok
    assert Enum.any?(snapshot.failures, &(&1.component == :markets))
    assert Enum.any?(snapshot.failures, &(&1.component == :risk_resolution))
    assert Enum.any?(snapshot.contributions, &(&1.source == :balance))
  end

  test "a crashed scope reader becomes an explicit failed domain" do
    exchange = %{exchange_with_markets() | markets: nil}
    scope = PortfolioRisk.scope(exchange, "main", plug: {Req.Test, crashing_market_stub()})
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      assert {:ok, %Snapshot{status: :partial, domains: [domain]} = snapshot} =
               PortfolioRisk.snapshot([scope], observed_at: @observed_at)

      assert Enum.all?([:markets, :balance, :positions, :open_orders], fn component ->
               domain.components[component].status == :error
             end)

      assert Enum.sort(Enum.map(snapshot.failures, & &1.component)) ==
               [:balance, :markets, :open_orders, :positions]
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  test "invalid requests and duplicate domains fail before fan-out" do
    exchange = exchange_with_markets()

    assert {:error, %Bourse.Error{type: :invalid_parameters}} = PortfolioRisk.snapshot([])

    assert {:error, %Bourse.Error{type: :invalid_parameters}} = PortfolioRisk.snapshot([:invalid_scope])

    assert {:error, %Bourse.Error{type: :invalid_parameters}} =
             PortfolioRisk.snapshot([%{exchange: exchange, account: nil}])

    duplicate = PortfolioRisk.scope(exchange, "same")

    assert {:error, %Bourse.Error{type: :invalid_parameters}} =
             PortfolioRisk.snapshot([duplicate, duplicate])

    assert {:error, %Bourse.Error{type: :invalid_parameters}} =
             PortfolioRisk.snapshot([duplicate], timeout: 0)

    assert {:error, %Bourse.Error{type: :invalid_parameters}} =
             PortfolioRisk.snapshot([duplicate], observed_at: "invalid")

    assert {:error, %Bourse.Error{type: :invalid_parameters}} =
             PortfolioRisk.snapshot([duplicate], max_age_ms: -1)
  end

  defp exchange_with_markets(markets \\ nil) do
    credentials = Credentials.new!(api_key: "test-key", secret: "test-secret")

    "deribit"
    |> Exchange.new!(credentials: credentials)
    |> Map.put(
      :markets,
      markets ||
        [
          %Market{
            id: "BTC-PERPETUAL",
            symbol: "BTC/USD:BTC",
            base: "BTC",
            quote: "USD",
            settle: "BTC",
            type: "swap",
            swap: true,
            contract: true,
            linear: false,
            inverse: true,
            contract_size: 10
          }
        ]
    )
  end

  defp snapshot_stub(opts \\ []) do
    stub = {__MODULE__, System.unique_integer([:positive])}
    failed_path = Keyword.get(opts, :fail_path)

    balance_body =
      "test/fixtures/responses/deribit/fetch_balance.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("body")

    Req.Test.stub(stub, fn conn ->
      cond do
        conn.request_path == failed_path ->
          Req.Test.transport_error(conn, :timeout)

        conn.request_path == "/api/v2/private/get_account_summaries" ->
          Req.Test.json(conn, balance_body)

        true ->
          Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => [], "testnet" => true})
      end
    end)

    stub
  end

  defp option_snapshot_stub(timestamp, opts \\ []) do
    stub = {__MODULE__, :option, System.unique_integer([:positive])}
    market = option_market()
    omit_rho? = Keyword.get(opts, :omit_rho, false)
    fail_markets? = Keyword.get(opts, :fail_markets, false)

    greeks =
      maybe_delete(%{"delta" => 0.5, "gamma" => 0.01, "vega" => 0.2, "theta" => -0.3, "rho" => 0.1}, "rho", omit_rho?)

    Req.Test.stub(stub, fn conn ->
      case conn.request_path do
        "/api/v2/public/get_instruments" when fail_markets? ->
          Req.Test.transport_error(conn, :timeout)

        "/api/v2/private/get_account_summaries" ->
          Req.Test.json(conn, simple_balance_body())

        "/api/v2/private/get_positions" ->
          Req.Test.json(conn, rpc_result([option_position_row(market, timestamp)]))

        "/api/v2/private/get_open_orders_by_currency" ->
          Req.Test.json(conn, rpc_result([option_order_row(market, timestamp)]))

        "/api/v2/public/ticker" ->
          Req.Test.json(
            conn,
            rpc_result(%{
              "instrument_name" => market.id,
              "timestamp" => timestamp,
              "greeks" => greeks,
              "underlying_price" => 100_000.0
            })
          )

        _other ->
          Req.Test.json(conn, rpc_result([]))
      end
    end)

    stub
  end

  defp market_loading_stub do
    stub = {__MODULE__, :markets, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn conn ->
      case conn.request_path do
        "/api/v2/public/get_instruments" ->
          Req.Test.json(
            conn,
            rpc_result([
              %{
                "instrument_name" => "BTC-PERPETUAL",
                "base_currency" => "BTC",
                "counter_currency" => "USD",
                "settlement_currency" => "BTC",
                "kind" => "future",
                "settlement_period" => "perpetual",
                "is_active" => true,
                "contract_size" => 10.0,
                "tick_size" => 0.5,
                "min_trade_amount" => 10.0
              }
            ])
          )

        "/api/v2/private/get_account_summaries" ->
          Req.Test.json(conn, simple_balance_body())

        _other ->
          Req.Test.json(conn, rpc_result([]))
      end
    end)

    stub
  end

  defp crashing_market_stub do
    stub = {__MODULE__, :crashing_market, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn _conn -> Process.exit(self(), :kill) end)
    stub
  end

  defp option_market do
    %Market{
      id: "BTC-31JAN26-100000-C",
      symbol: "BTC/USD:BTC-260131-100000-C",
      base: "BTC",
      quote: "USD",
      settle: "BTC",
      type: "option",
      option: true,
      contract: true,
      quantity_unit: "base",
      native_quantity_unit: "base",
      contract_size: 1,
      strike: 100_000,
      expiry: 1_769_817_600_000,
      option_type: "call"
    }
  end

  defp option_position_row(market, timestamp) do
    %{
      "instrument_name" => market.id,
      "kind" => "option",
      "direction" => "buy",
      "size" => 0.03,
      "size_currency" => 0.03,
      "average_price" => 0.1,
      "mark_price" => 0.2,
      "initial_margin" => 0.01,
      "maintenance_margin" => 0.005,
      "estimated_liquidation_price" => 10_000,
      "timestamp" => timestamp
    }
  end

  defp option_order_row(market, timestamp) do
    %{
      "order_id" => "pending-option",
      "instrument_name" => market.id,
      "direction" => "sell",
      "amount" => 0.02,
      "filled_amount" => 0,
      "price" => 0.1,
      "order_state" => "open",
      "original_order_type" => "limit",
      "creation_timestamp" => timestamp,
      "last_update_timestamp" => timestamp
    }
  end

  defp simple_balance_body do
    rpc_result(%{
      "summaries" => [
        %{
          "currency" => "BTC",
          "balance" => 1.0,
          "available_funds" => 0.8,
          "maintenance_margin" => 0.1
        }
      ]
    })
  end

  defp rpc_result(result), do: %{"jsonrpc" => "2.0", "result" => result, "testnet" => true}

  defp maybe_delete(map, key, true), do: Map.delete(map, key)
  defp maybe_delete(map, _key, false), do: map
end
