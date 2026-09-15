defmodule Bourse.AuthoredIdentifierClassTest do
  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Registry
  alias Bourse.Spec

  @incompatible_identifier_classes [
    MapSet.new(~w(billId bill_id)),
    MapSet.new(~w(transId transferId transfer_id)),
    MapSet.new(~w(orderId ordId order_id oid algoId)),
    MapSet.new(~w(clientOrderId clOrdId clientOid orderLinkId client_order_id)),
    MapSet.new(~w(tradeId trade_id execId tid))
  ]

  test "authored id maps never fall back onto a different identifier class" do
    violations =
      for venue <- Registry.exchanges(),
          rule <- nested_maps(Spec.load!(venue)["normalization"]),
          is_map(rule),
          is_binary(rule["key"]),
          fallbacks = List.wrap(rule["fallback_keys"]),
          fallbacks != [],
          keys = [rule["key"] | fallbacks],
          classes = identifier_classes(keys),
          MapSet.size(classes) > 1,
          do: {venue, rule["key"], fallbacks, MapSet.to_list(classes)}

    assert violations == [],
           "id field maps must not fallback across identifier classes: #{inspect(violations)}"
  end

  test "okx fetch_transfer refuses a bills-archive billId without a venue request" do
    exchange = Exchange.new!("okx", api_key: "k", secret: "s", password: "p")
    bill_id = "3858573567752257536"

    assert {:error, %Error{type: :invalid_parameters} = error} =
             Bourse.fetch_transfer(exchange, bill_id, base_url: "http://127.0.0.1:1")

    assert error.raw["reason"] == "identifier_class_mismatch"
    assert error.message =~ "bills-archive"
    refute to_string(error.code) in ["51000", "58129"]
  end

  test "okx fetch_transfer still forwards a transId-shaped id" do
    exchange = Exchange.new!("okx", api_key: "k", secret: "s", password: "p")

    assert {:error, %Error{type: type}} =
             Bourse.fetch_transfer(exchange, "999999999999", base_url: "http://127.0.0.1:1")

    refute type == :invalid_parameters
  end

  defp identifier_classes(keys) do
    keys
    |> Enum.flat_map(&classes_for_key/1)
    |> MapSet.new()
  end

  defp classes_for_key(key) do
    Enum.filter(@incompatible_identifier_classes, &MapSet.member?(&1, key))
  end

  defp nested_maps(value) when is_map(value) do
    [value | Enum.flat_map(Map.values(value), &nested_maps/1)]
  end

  defp nested_maps(value) when is_list(value), do: Enum.flat_map(value, &nested_maps/1)
  defp nested_maps(_value), do: []
end
