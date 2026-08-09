defmodule Bourse.RecordedResponseFixtures.ListBodyTest do
  use ExUnit.Case, async: true

  alias Bourse.RecordedResponseFixtures
  alias Bourse.RecordedResponseFixtures.ListBody
  alias Bourse.Spec

  @list_fixture_methods ~w(
    fetch_open_orders
    fetch_closed_orders
    fetch_canceled_orders
    fetch_account_positions
    fetch_positions
    fetch_positions_risk
    fetch_leverages
    fetch_my_trades
    fetch_ledger
  )

  test "classifies list-returning private methods" do
    assert ListBody.list_methods() == [
             :fetch_open_orders,
             :fetch_closed_orders,
             :fetch_canceled_orders,
             :fetch_account_positions,
             :fetch_positions,
             :fetch_positions_risk,
             :fetch_leverages,
             :fetch_my_trades,
             :fetch_ledger
           ]

    assert ListBody.list_method?(:fetch_open_orders)
    assert ListBody.list_method?("fetch_positions")
    refute ListBody.list_method?(:fetch_balance)
  end

  test "body_populated? walks nested envelopes and ignores empty row lists" do
    refute ListBody.body_populated?([])
    refute ListBody.body_populated?(%{"data" => []})
    refute ListBody.body_populated?(%{"result" => %{"list" => []}})
    refute ListBody.body_populated?(%{"result" => %{"orders" => [], "next" => "cursor"}})

    assert ListBody.body_populated?([%{"orderId" => 1}])
    assert ListBody.body_populated?(%{"data" => [%{"instId" => "BTC-USDT"}]})
    assert ListBody.body_populated?(%{"result" => %{"list" => [%{"symbol" => "BTCUSDT"}]}})
    assert ListBody.body_populated?(%{"result" => %{"trades" => [%{"trade_id" => "1"}]}})

    # Scalar arrays are not private list-of-maps rows (would inflate OHLCV-like shapes).
    refute ListBody.body_populated?([[1_700_000_000_000, 1.0, 2.0, 0.5, 1.5, 10.0]])
  end

  test "first_wire_row returns the first map under the primary row list" do
    assert ListBody.first_wire_row([%{"id" => "a"}, %{"id" => "b"}]) == %{"id" => "a"}

    assert ListBody.first_wire_row(%{"result" => %{"list" => [%{"execId" => "x"}]}}) == %{
             "execId" => "x"
           }

    assert ListBody.first_wire_row(%{"data" => []}) == nil
  end

  test "annotate is sticky once a cell has been populated" do
    empty_body = %{"body" => %{"result" => %{"list" => []}}}
    populated_body = %{"body" => %{"result" => %{"list" => [%{"symbol" => "BTCUSDT"}]}}}

    assert ListBody.annotate(empty_body)["body_populated"] == false
    assert ListBody.annotate(populated_body)["body_populated"] == true

    # Empty re-capture after a populated cell keeps the declaration true so the
    # replay gate can fail rather than silently downgrade to shape-only.
    sticky =
      ListBody.annotate(empty_body, %{"body_populated" => true, "body" => populated_body["body"]})

    assert sticky["body_populated"] == true
    refute ListBody.body_populated?(sticky["body"])
  end

  test "declared_populated? preserves a populated declaration from either durable source" do
    body = %{"result" => %{"list" => [%{"a" => 1}]}}

    assert ListBody.declared_populated?(%{"body_populated" => false, "body" => body}) == false
    assert ListBody.declared_populated?(%{"body" => body}, %{"body_populated" => true}) == true

    assert ListBody.declared_populated?(%{"body_populated" => false, "body" => []}, %{
             "body_populated" => true
           }) == true

    assert ListBody.declared_populated?(%{"body" => body}) == true
    assert ListBody.declared_populated?(%{"body" => %{"data" => []}}) == false
  end

  test "binds_wire_row? detects info and unified-field bindings" do
    raw = %{"orderId" => 42, "price" => "50000.0", "origQty" => "0.001"}

    order = struct(Bourse.Order, id: "42", price: 50_000.0, amount: 0.001, info: raw)
    order_info_only = struct(Bourse.Order, info: %{"orderId" => 42})
    unbound = struct(Bourse.Order, id: "99", price: 1.0, info: %{"other" => true})

    assert ListBody.binds_wire_row?(order, raw)
    assert ListBody.binds_wire_row?(order_info_only, raw)
    refute ListBody.binds_wire_row?(unbound, raw)
  end

  test "corpus list fixtures declare body_populated matching the wire body" do
    for venue <- Spec.oracle_venues(:private_real_recordings),
        method <- ListBody.list_methods(),
        RecordedResponseFixtures.capture_category(venue, method) == :private do
      path = RecordedResponseFixtures.fixture_path(venue, method)

      assert File.exists?(path), "missing list-returning private fixture #{venue}/#{method}"

      fixture = RecordedResponseFixtures.load_fixture!(path)
      actual = ListBody.body_populated?(fixture["body"])

      assert is_boolean(fixture["body_populated"]),
             "#{venue}/#{method} missing body_populated declaration"

      assert fixture["body_populated"] == actual,
             "#{venue}/#{method} body_populated=#{fixture["body_populated"]} but body actual=#{actual}"
    end
  end

  test "manifest mirrors body_populated for every list-returning private recording" do
    manifest =
      "test/fixtures/responses/_manifest.json"
      |> File.read!()
      |> Jason.decode!()

    list_recordings =
      Enum.filter(manifest["recordings"], fn recording ->
        recording["method"] in @list_fixture_methods
      end)

    expected_paths =
      for {venue, method} <- RecordedResponseFixtures.capture_targets(),
          method in ListBody.list_methods(),
          RecordedResponseFixtures.capture_category(venue, method) == :private do
        "#{venue}/#{method}.json"
      end

    assert MapSet.new(Enum.map(list_recordings, & &1["path"])) == MapSet.new(expected_paths)

    for recording <- list_recordings do
      assert is_boolean(recording["body_populated"]),
             "manifest #{recording["path"]} missing body_populated"

      fixture =
        recording["path"]
        |> then(&Path.join("test/fixtures/responses", &1))
        |> RecordedResponseFixtures.load_fixture!()

      assert recording["body_populated"] == fixture["body_populated"],
             "manifest/fixture mismatch for #{recording["path"]}"
    end
  end

  test "shape_only_marker is the explicit empty-body evidence string" do
    assert ListBody.shape_only_marker() == "empty-body: shape-only evidence"
  end
end
