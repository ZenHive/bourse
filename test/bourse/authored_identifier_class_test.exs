defmodule Bourse.AuthoredIdentifierClassTest do
  use ExUnit.Case, async: true

  alias Bourse.Registry
  alias Bourse.Spec

  test "bill identifiers are never fallback substitutes for another id class" do
    violations =
      for venue <- Registry.exchanges(),
          rule <- nested_maps(Spec.load!(venue)["normalization"]),
          rule["key"] != "billId",
          "billId" in List.wrap(rule["fallback_keys"]),
          do: {venue, rule["key"], rule["fallback_keys"]}

    assert violations == []
  end

  defp nested_maps(value) when is_map(value) do
    [value | Enum.flat_map(Map.values(value), &nested_maps/1)]
  end

  defp nested_maps(value) when is_list(value), do: Enum.flat_map(value, &nested_maps/1)
  defp nested_maps(_value), do: []
end
