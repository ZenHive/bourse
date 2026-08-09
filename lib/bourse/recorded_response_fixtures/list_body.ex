defmodule Bourse.RecordedResponseFixtures.ListBody do
  @moduledoc """
  Evidence classification for list-returning private recorded fixtures.

  `Enum.all?([], _)` is true, so a list-shape assert on an empty capture only
  proves "the parser returned a list." This module makes empty vs populated
  mechanical: fixtures declare `body_populated`, empty bodies emit an explicit
  shape-only marker, and a silent empty re-capture cannot downgrade a populated
  cell while staying green (task 469).
  """

  @list_methods [
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
  @shape_only_marker "empty-body: shape-only evidence"

  @doc "List-returning private methods whose empty-body assert is vacuous without classification."
  @spec list_methods() :: [atom()]
  def list_methods, do: @list_methods

  @doc "True when `method` is a list-returning private capture method."
  @spec list_method?(atom() | String.t()) :: boolean()
  def list_method?(method) when is_atom(method), do: method in @list_methods
  def list_method?(method) when is_binary(method), do: method in Enum.map(@list_methods, &Atom.to_string/1)

  @doc "Explicit marker printed for empty-body list fixtures."
  @spec shape_only_marker() :: String.t()
  def shape_only_marker, do: @shape_only_marker

  @doc """
  Whether a recorded response body carries at least one list-of-maps row.

  Walks nested envelopes (`data`, `result.list`, `result.orders`, …) and counts
  the longest list that contains map rows. Scalar arrays (OHLCV bars, etc.) do
  not count as populated private-list evidence.
  """
  @spec body_populated?(term()) :: boolean()
  def body_populated?(body), do: max_row_list_length(body) > 0

  @doc "Longest list-of-maps length under a recorded body (0 when empty)."
  @spec max_row_list_length(term()) :: non_neg_integer()
  def max_row_list_length(body), do: do_max_row_list_length(body)

  @doc "First map row from the primary list-of-maps under a body, or nil."
  @spec first_wire_row(term()) :: map() | nil
  def first_wire_row(body) do
    case first_row_list(body) do
      [row | _] when is_map(row) -> row
      _other -> nil
    end
  end

  @doc """
  Declared population for a fixture.

  A populated declaration in either the fixture or recording manifest is
  sticky. When neither carries a declaration, derive it from the body so
  pre-annotation fixtures still classify correctly.
  """
  @spec declared_populated?(map(), map() | nil) :: boolean()
  def declared_populated?(fixture, recording \\ nil) do
    declarations = Enum.map([fixture, recording], &population_declaration/1)

    cond do
      true in declarations -> true
      false in declarations -> false
      true -> body_populated?(Map.get(fixture, "body"))
    end
  end

  @doc """
  Sticky population annotation for a captured fixture.

  Once a cell has been recorded as populated, an empty re-capture keeps
  `body_populated: true` so the oracle gate fails instead of silently
  downgrading to shape-only evidence.
  """
  @spec annotate(map(), map() | nil) :: map()
  def annotate(fixture, previous \\ nil) when is_map(fixture) do
    actual = body_populated?(Map.get(fixture, "body"))
    previous_declared = previous_declared_populated?(previous)

    body_populated =
      cond do
        actual -> true
        previous_declared -> true
        true -> false
      end

    Map.put(fixture, "body_populated", body_populated)
  end

  @doc "True when a parsed struct bound at least one scalar from the raw wire row."
  @spec binds_wire_row?(struct() | map(), map()) :: boolean()
  def binds_wire_row?(parsed, raw_row) when is_map(raw_row) do
    info_bound?(parsed, raw_row) or unified_field_bound?(parsed, raw_row)
  end

  defp previous_declared_populated?(%{"body_populated" => true}), do: true
  defp previous_declared_populated?(_), do: false

  defp population_declaration(%{"body_populated" => value}) when is_boolean(value), do: value
  defp population_declaration(_), do: nil

  defp info_bound?(%{info: info}, raw_row) when is_map(info) do
    Enum.any?(raw_row, fn {key, value} ->
      Map.has_key?(info, key) and values_equal?(Map.get(info, key), value)
    end)
  end

  defp info_bound?(_parsed, _raw_row), do: false

  defp unified_field_bound?(%_{} = parsed, raw_row) do
    fields =
      parsed
      |> Map.from_struct()
      |> Map.delete(:info)

    raw_values =
      raw_row
      |> Map.values()
      |> Enum.flat_map(&expand_comparable/1)

    Enum.any?(fields, fn {_key, value} ->
      value != nil and Enum.any?(raw_values, &values_equal?(value, &1))
    end)
  end

  defp unified_field_bound?(_parsed, _raw_row), do: false

  defp expand_comparable(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> [value, number]
      _other -> [value]
    end
  end

  defp expand_comparable(value) when is_integer(value), do: [value, value * 1.0]
  defp expand_comparable(value) when is_float(value), do: [value]
  defp expand_comparable(_value), do: []

  defp values_equal?(left, right) when left == right, do: true

  defp values_equal?(left, right) when is_binary(left) and is_binary(right), do: left == right

  defp values_equal?(left, right) when is_number(left) and is_number(right), do: left == right

  defp values_equal?(left, right) when is_binary(left) and is_number(right) do
    case Float.parse(left) do
      {number, ""} -> number == right * 1.0 or number == right
      _other -> false
    end
  end

  defp values_equal?(left, right) when is_number(left) and is_binary(right), do: values_equal?(right, left)

  defp values_equal?(_left, _right), do: false

  defp do_max_row_list_length(list) when is_list(list) do
    here = if row_list?(list), do: length(list), else: 0
    nested = list |> Enum.map(&do_max_row_list_length/1) |> Enum.max(fn -> 0 end)
    max(here, nested)
  end

  defp do_max_row_list_length(map) when is_map(map) do
    map
    |> Map.values()
    |> Enum.map(&do_max_row_list_length/1)
    |> Enum.max(fn -> 0 end)
  end

  defp do_max_row_list_length(_other), do: 0

  defp first_row_list(list) when is_list(list) do
    if row_list?(list) and list != [] do
      list
    else
      Enum.find_value(list, &first_row_list/1)
    end
  end

  defp first_row_list(map) when is_map(map) do
    map
    |> Map.values()
    |> Enum.find_value(&first_row_list/1)
  end

  defp first_row_list(_other), do: nil

  # A "row list" is a list of maps (possibly empty). Scalar arrays are not
  # private list evidence (they would inflate OHLCV / number tuples).
  defp row_list?([]), do: true
  defp row_list?([head | _]) when is_map(head), do: true
  defp row_list?(_other), do: false
end
