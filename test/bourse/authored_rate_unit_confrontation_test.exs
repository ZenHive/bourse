defmodule Bourse.AuthoredRateUnitConfrontationTest do
  @moduledoc false
  use ExUnit.Case, async: true

  @runtime_support_path "priv/specs/json/runtime_support.json"
  @external_resource @runtime_support_path
  @venues @runtime_support_path |> File.read!() |> Jason.decode!() |> Map.fetch!("venues")
  for venue <- @venues do
    @external_resource Path.join("docs/authored-spec-carves", "#{venue}.md")
  end

  @registers Map.new(@venues, fn venue ->
               path = Path.join("docs/authored-spec-carves", "#{venue}.md")
               {venue, File.read!(path)}
             end)
  @confrontation_section ~r/^\*\*C-T(?:594|600)[a-z]*\b.*?(?=^<!-- carve-evidence-status)/ms
  @rate_keys ~w(
    fundingRate interestRate nextFundingRate previousFundingRate rate percentage maker taker
    initialMarginPercentage maintenanceMarginPercentage maintenanceMarginRate
    impliedVolatility markImpliedVolatility askImpliedVolatility bidImpliedVolatility
  )
  @fraction_keys ~w(
    fundingRate interestRate nextFundingRate previousFundingRate rate maker taker
    initialMarginPercentage maintenanceMarginPercentage maintenanceMarginRate
    impliedVolatility markImpliedVolatility askImpliedVolatility bidImpliedVolatility
  )

  test "one unit is emitted per unified rate-like field across every runtime venue" do
    entries =
      for venue <- @venues,
          {path, value} <- rate_slots(Bourse.Spec.load!(venue)),
          not is_nil(value) do
        unit = declared_unit!(venue, path)

        assert unit == expected_unit!(path),
               "#{venue}: #{path} declares #{unit}, expected #{expected_unit!(path)}"

        {unified_field(path), venue, path, unit}
      end

    for {field, field_entries} <- Enum.group_by(entries, &elem(&1, 0)) do
      units = field_entries |> Enum.map(&elem(&1, 3)) |> Enum.uniq()

      assert [_one_unit] = units,
             "#{field} emits contradictory units: #{inspect(field_entries)}"
    end
  end

  test "every authored rate-like slot has an unambiguous confrontation in both directions" do
    for venue <- @venues,
        {path, value} <- rate_slots(Bourse.Spec.load!(venue)) do
      unit = declared_unit!(venue, path)

      if is_nil(value) do
        assert unit == :absent,
               "#{venue}: #{path} is authored null but declares #{unit}"
      else
        refute unit == :absent,
               "#{venue}: #{path} emits a value but its confrontation claims absent"

        case value do
          %{"scale" => scale} when is_number(scale) and scale > 0 and scale < 1 ->
            assert unit in [:fraction, :percent_points],
                   "#{venue}: #{path} scales a percent-family source but declares #{unit}"

          _ ->
            :ok
        end
      end
    end
  end

  test "every venue funding-rate slot cites a provider-owned unit statement or arithmetic" do
    for venue <- @venues,
        {path, _value} <- rate_slots(Bourse.Spec.load!(venue)),
        String.contains?(path, "funding_") and not String.ends_with?(path, ".percentage") do
      line = confrontation_line!(venue, path)

      assert String.contains?(line, "https://"),
             "#{venue}: #{path} has no provider citation in its rate-unit confrontation"
    end
  end

  test "extras carrying a rate in unified_key participate in slot derivation" do
    field_maps = %{
      "income" => %{
        "extras" => [
          %{"coercion" => "safeNumber", "key" => "feeRate", "unified_key" => "rate"}
        ],
        "field_map" => %{}
      }
    }

    assert [{"normalization.field_maps.income.extras[0].rate", %{"unified_key" => "rate"}}] =
             field_maps
             |> collect_field_map_paths(~w(normalization field_maps))
             |> Enum.map(fn {path, rule} -> {path, Map.take(rule, ["unified_key"])} end)
  end

  defp rate_slots(spec) do
    field_map_slots =
      spec
      |> get_in(~w(normalization field_maps))
      |> collect_field_map_paths(~w(normalization field_maps))

    static_fee_slots = collect_static_fee_paths(spec["fees"], ["fees"])

    Enum.sort_by(field_map_slots ++ static_fee_slots, &elem(&1, 0))
  end

  defp collect_field_map_paths(%{} = map, path) do
    extra =
      case map do
        %{"unified_key" => key} when key in @rate_keys ->
          [{format_path(path ++ [key]), map}]

        _ ->
          []
      end

    children =
      Enum.flat_map(map, fn {key, value} ->
        child_path = path ++ [key]

        current =
          if key in @rate_keys and (is_map(value) or is_nil(value)),
            do: [{format_path(child_path), value}],
            else: []

        current ++ collect_field_map_paths(value, child_path)
      end)

    extra ++ children
  end

  defp collect_field_map_paths(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> collect_field_map_paths(value, path ++ [index]) end)
  end

  defp collect_field_map_paths(_value, _path), do: []

  defp collect_static_fee_paths(%{} = map, path) do
    Enum.flat_map(map, fn {key, value} ->
      child_path = path ++ [key]

      cond do
        key in ~w(maker taker) and is_number(value) ->
          [{format_path(child_path), value}]

        key in ~w(maker taker) and is_list(value) and value != [] ->
          [{format_path(child_path ++ [:all, "rate"]), value}]

        true ->
          collect_static_fee_paths(value, child_path)
      end
    end)
  end

  defp collect_static_fee_paths(_value, _path), do: []

  defp format_path(path) do
    Enum.reduce(path, "", fn
      index, acc when is_integer(index) -> "#{acc}[#{index}]"
      :all, acc -> "#{acc}[*]"
      key, "" -> key
      key, acc -> "#{acc}.#{key}"
    end)
  end

  defp expected_unit!(path) do
    key = rate_key(path)

    cond do
      key in @fraction_keys -> :fraction
      key == "percentage" and fee_percentage_path?(path) -> :boolean
      key == "percentage" -> :percent_points
      true -> flunk("no unified rate-unit contract for #{path}")
    end
  end

  defp unified_field(path) do
    key = rate_key(path)

    cond do
      key in ~w(maker taker) -> "fee.#{key}"
      key == "rate" and String.contains?(path, ".fee.sub_field_map.rate") -> "fee.rate"
      key in ~w(rate percentage) -> "#{parse_slot(path)}.#{key}"
      true -> key
    end
  end

  defp rate_key(path) do
    path
    |> String.split(".")
    |> List.last()
    |> String.replace(~r/^.*\]/, "")
  end

  defp parse_slot("normalization.field_maps." <> rest), do: rest |> String.split(".") |> hd()
  defp parse_slot("fees." <> _rest), do: "fees"

  defp fee_percentage_path?(path) do
    parse_slot(path) in ~w(market trading_fee trading_fees)
  end

  defp declared_unit!(venue, path) do
    line = confrontation_line!(venue, path)

    case Regex.run(~r/<!-- rate-unit path="[^"]+" unit="([a-z_]+)" -->/, line, capture: :all_but_first) do
      [unit] ->
        String.to_existing_atom(unit)

      nil ->
        table_unit!(venue, path, line)
    end
  end

  defp table_unit!(venue, path, line) do
    unit_cell = line |> String.split("|") |> Enum.at(2, "") |> String.trim()

    if String.starts_with?(unit_cell, "absent") do
      :absent
    else
      units =
        [
          {:fraction, "fraction"},
          {:percent_points, "percent points"},
          {:basis_points, "basis points"},
          {:boolean, "boolean"}
        ]
        |> Enum.filter(fn {_unit, marker} -> String.contains?(unit_cell, marker) end)
        |> Enum.map(&elem(&1, 0))

      case units do
        [unit] -> unit
        [] -> flunk("#{venue}: #{path} has no explicit unit in: #{line}")
        _ -> flunk("#{venue}: #{path} has an ambiguous grouped unit; add a per-slot rate-unit marker")
      end
    end
  end

  defp confrontation_line!(venue, path) do
    lines =
      @registers
      |> Map.fetch!(venue)
      |> then(&Regex.scan(@confrontation_section, &1))
      |> Enum.flat_map(fn [section] -> String.split(section, "\n") end)
      |> Enum.reverse()

    Enum.find(lines, fn line ->
      String.contains?(line, "`#{path}`") or String.contains?(line, ~s(path="#{path}"))
    end) || flunk("#{venue}: Task 594/600 does not confront #{path}")
  end
end
