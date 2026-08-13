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
  @confrontation_section ~r/^\*\*(C-T(\d+)[a-z]?)\s+—.*?(?=^<!-- carve-evidence-status)/ms
  @rate_keys ~w(
    fundingRate interestRate nextFundingRate previousFundingRate rate percentage maker taker
    initialMarginPercentage maintenanceMarginPercentage maintenanceMarginRate
    impliedVolatility markImpliedVolatility askImpliedVolatility bidImpliedVolatility
  )
  @unit_multipliers %{fraction: 1, percent_points: 100, basis_points: 10_000}
  @slot_contracts %{
    "adl_rank" => Bourse.ADLRank,
    "borrow_interest" => Bourse.BorrowInterest,
    "borrow_rate" => Bourse.BorrowRate,
    "fees" => Bourse.TradingFee,
    "funding_history" => Bourse.FundingHistory,
    "funding_rate" => Bourse.FundingRate,
    "funding_rate_history" => Bourse.FundingRateHistory,
    "greeks" => Bourse.Greeks,
    "leverage_tiers" => Bourse.LeverageTier,
    "market" => Bourse.Market,
    "option" => Bourse.OptionData,
    "option_position" => Bourse.Position,
    "order" => Bourse.Fee,
    "position" => Bourse.Position,
    "ticker" => Bourse.Ticker,
    "trade" => Bourse.Fee,
    "trading_fee" => Bourse.TradingFee,
    "trading_fees" => Bourse.TradingFee
  }

  # Declaration-consistency only: this compares authored spec slots + carve
  # markers against the struct docstrings. It does NOT parse venue bodies —
  # emitted-output coverage lives in the per-venue authored-spec tests.
  test "every authored unit declaration agrees with its public unified struct contract" do
    assert_declarations_match!(emitted_entries())
  end

  test "a contradictory venue declaration makes the contract guard red" do
    [entry | _rest] = emitted_entries()
    contradictory_unit = if entry.contract_unit == :fraction, do: :percent_points, else: :fraction

    assert_raise ExUnit.AssertionError, fn ->
      assert_declarations_match!([%{entry | declared_unit: contradictory_unit}])
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

        for scale <- authored_scales(value) do
          source_unit = declared_source_unit!(venue, path)
          expected_scale = unit_multiplier(unit) / unit_multiplier(source_unit)

          assert_in_delta abs(scale), expected_scale, 1.0e-12,
            message:
              "#{venue}: #{path} scales #{source_unit} by #{scale}, which cannot emit #{unit} (expected magnitude #{expected_scale})"
        end
      end
    end
  end

  test "confrontation supersession follows date and then task number, not file position" do
    path = "normalization.field_maps.ticker.field_map.percentage"

    register = """
    ## 2026-08-13 — amendment
    **C-T1a — newer rate-unit block (task 1).**
    <!-- rate-unit path="#{path}" unit="percent_points" -->
    <!-- carve-evidence-status {} -->
    ## 2026-08-12 — appended later in the file
    **C-T999a — older rate-unit block (task 999).**
    <!-- rate-unit path="#{path}" unit="fraction" -->
    <!-- carve-evidence-status {} -->
    """

    assert confrontation_line_from!(register, path) =~ ~s(unit="percent_points")

    same_date = String.replace(register, "2026-08-13", "2026-08-12")
    assert confrontation_line_from!(same_date, path) =~ ~s(unit="fraction")
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

  defp emitted_entries do
    for venue <- @venues,
        {path, value} <- rate_slots(Bourse.Spec.load!(venue)),
        not is_nil(value) do
      %{
        venue: venue,
        path: path,
        declared_unit: declared_unit!(venue, path),
        contract_unit: public_contract_unit!(path)
      }
    end
  end

  defp declaration_errors(entries) do
    Enum.flat_map(entries, fn entry ->
      if entry.declared_unit == entry.contract_unit do
        []
      else
        [
          "#{entry.venue}: #{entry.path} declares #{entry.declared_unit}, public contract requires #{entry.contract_unit}"
        ]
      end
    end)
  end

  defp assert_declarations_match!(entries), do: assert([] == declaration_errors(entries))

  defp public_contract_unit!(path) do
    module = Map.fetch!(@slot_contracts, parse_slot(path))
    field = public_contract_field(path)
    property = module.schema() |> Map.fetch!("properties") |> Map.fetch!(field)
    description = property |> Map.fetch!("description") |> String.downcase()

    cond do
      property["type"] == "boolean" -> :boolean
      String.contains?(description, ["percent points", "percentile"]) -> :percent_points
      String.contains?(description, ["fraction", "decimal"]) -> :fraction
      true -> flunk("#{inspect(module)}.#{field} does not document a rate unit")
    end
  end

  defp public_contract_field("fees." <> rest) do
    cond do
      String.contains?(rest, ".maker") -> "maker"
      String.contains?(rest, ".taker") -> "taker"
      true -> rest |> String.split(".") |> List.last() |> Macro.underscore()
    end
  end

  defp public_contract_field(path), do: path |> rate_key() |> Macro.underscore()

  defp rate_key(path) do
    path
    |> String.split(".")
    |> List.last()
    |> String.replace(~r/^.*\]/, "")
  end

  defp parse_slot("normalization.field_maps." <> rest), do: rest |> String.split(".") |> hd()
  defp parse_slot("fees." <> _rest), do: "fees"

  defp declared_unit!(venue, path) do
    line = confrontation_line!(venue, path)

    case marker_attributes(line) do
      %{"unit" => unit} -> String.to_existing_atom(unit)
      %{} -> table_unit!(venue, path, line)
    end
  end

  defp declared_source_unit!(venue, path) do
    case marker_attributes(confrontation_line!(venue, path)) do
      %{"source-unit" => unit} -> String.to_existing_atom(unit)
      _attributes -> flunk("#{venue}: #{path} has scale but no source-unit declaration")
    end
  end

  defp marker_attributes(line) do
    ~r/([a-z-]+)="([^"]+)"/
    |> Regex.scan(line, capture: :all_but_first)
    |> Map.new(fn [key, value] -> {key, value} end)
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
    @registers
    |> Map.fetch!(venue)
    |> confrontation_line_from!(path)
  end

  defp confrontation_line_from!(register, path) do
    candidates =
      @confrontation_section
      |> Regex.scan(register, return: :index)
      |> Enum.flat_map(fn [{section_start, section_length}, {id_start, id_length}, {task_start, task_length}] ->
        section = binary_part(register, section_start, section_length)

        case Enum.find(String.split(section, "\n"), &confronts_path?(&1, path)) do
          nil ->
            []

          line ->
            prefix = binary_part(register, 0, section_start)
            date = latest_heading_date(prefix)
            id = binary_part(register, id_start, id_length)
            task = register |> binary_part(task_start, task_length) |> String.to_integer()
            [%{date: date, task: task, id: id, line: line}]
        end
      end)

    case Enum.max_by(candidates, &{&1.date, &1.task, &1.id}, fn -> nil end) do
      nil -> flunk("no dated C-T rate-unit block confronts #{path}")
      candidate -> candidate.line
    end
  end

  defp confronts_path?(line, path) do
    String.contains?(line, "`#{path}`") or String.contains?(line, ~s(path="#{path}"))
  end

  defp latest_heading_date(prefix) do
    case Regex.scan(~r/^## (\d{4}-\d{2}-\d{2})\b/m, prefix, capture: :all_but_first) do
      [] -> flunk("rate-unit confrontation has no dated heading")
      dates -> dates |> List.last() |> hd()
    end
  end

  defp authored_scales(%{} = value) do
    own = if is_number(value["scale"]), do: [value["scale"]], else: []
    own ++ Enum.flat_map(value, fn {_key, child} -> authored_scales(child) end)
  end

  defp authored_scales(value) when is_list(value), do: Enum.flat_map(value, &authored_scales/1)
  defp authored_scales(_value), do: []

  defp unit_multiplier(unit), do: Map.fetch!(@unit_multipliers, unit)
end
