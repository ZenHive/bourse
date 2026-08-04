defmodule Bourse.PortfolioRiskIntegrationTest do
  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper, only: [build_exchange: 2, require_credentials!: 2]

  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.PortfolioRisk
  alias Bourse.PortfolioRisk.Snapshot
  alias Bourse.Test.FixtureGateIsolation

  @moduletag :integration
  @moduletag :network

  @deribit_testnet_url "https://test.deribit.com"

  setup do
    FixtureGateIsolation.isolate!("deribit")
    :ok
  end

  test "live populated Deribit reads produce a complete account-domain snapshot" do
    credentials = require_credentials!(:deribit, url: @deribit_testnet_url)
    exchange = build_exchange(:deribit, credentials: credentials, sandbox: true)
    scope = PortfolioRisk.scope(exchange, "main")

    assert {:ok, %Snapshot{status: :complete} = snapshot} = PortfolioRisk.snapshot([scope])
    assert [%{components: components, available_capacity: {:ok, capacity}}] = snapshot.domains
    assert components.balance.status == :ok
    assert components.positions.status == :ok
    assert components.open_orders.status == :ok
    assert map_size(capacity) > 0
    assert Enum.any?(snapshot.contributions, &(&1.source == :balance))

    assert snapshot.failures == []
    assert snapshot.blocked_buckets == []
  end

  test "live invalid credentials retain each relevant read failure" do
    credentials = Credentials.new!(api_key: "invalid-task-399", secret: "invalid-task-399")
    exchange = build_exchange(:deribit, credentials: credentials, sandbox: true)

    assert {:ok, %Snapshot{status: :partial} = snapshot} =
             PortfolioRisk.snapshot([PortfolioRisk.scope(exchange, "invalid")])

    assert [%{components: components}] = snapshot.domains

    for component <- [:balance, :positions, :open_orders] do
      assert %{status: :error, error: %Error{type: :authentication_error}} =
               Map.fetch!(components, component)

      assert Enum.any?(snapshot.failures, &(&1.component == component))
    end

    assert snapshot.contributions == []
  end
end
