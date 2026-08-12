defmodule Bourse.AuthoredRateUnitConfrontationTest do
  @moduledoc false
  use ExUnit.Case, async: true

  @venues ~w(
    alpaca binance binancecoinm binanceusdm bybit coinbaseexchange deribit derive
    hyperliquid okx
  )
  @rate_keys ~w(
    fundingRate interestRate nextFundingRate previousFundingRate rate percentage maker taker
    initialMarginPercentage maintenanceMarginPercentage maintenanceMarginRate
  )
  @unit_markers ["fraction", "percent points", "basis points", "absent", "unverified", "boolean"]

  test "every authored rate-like slot has a Task 594 venue-unit confrontation" do
    for venue <- @venues,
        {path, value} <- rate_slots(Bourse.Spec.load!(venue)) do
      line = confrontation_line!(venue, path)

      assert Enum.any?(@unit_markers, &String.contains?(line, &1)),
             "#{venue}: #{path} has no explicit unit in its Task 594 confrontation"

      if is_nil(value) do
        assert String.contains?(line, "absent"),
               "#{venue}: #{path} is authored null but its confrontation does not claim absent"
      end

      case value do
        %{"scale" => 100} ->
          assert String.contains?(line, "percent points"),
                 "#{venue}: #{path} scales x100 into percent points but its confrontation does not say so"

        %{"scale" => scale} when is_number(scale) and scale > 0 and scale < 1 ->
          assert String.contains?(line, "percent") or String.contains?(line, "basis points"),
                 "#{venue}: #{path} scales down from a percent-family source but its confrontation does not say percent or basis points"

        _ ->
          :ok
      end
    end
  end

  test "every venue funding-rate slot cites a provider-owned unit statement or arithmetic" do
    for venue <- @venues,
        {path, _value} <- rate_slots(Bourse.Spec.load!(venue)),
        String.contains?(path, "funding_") and not String.ends_with?(path, ".percentage") do
      line = confrontation_line!(venue, path)

      assert String.contains?(line, "https://"),
             "#{venue}: #{path} has no provider citation in its Task 594 confrontation"
    end
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
    Enum.flat_map(map, fn {key, value} ->
      child_path = path ++ [key]

      current =
        if key in @rate_keys and (is_map(value) or is_nil(value)),
          do: [{format_path(child_path), value}],
          else: []

      current ++ collect_field_map_paths(value, child_path)
    end)
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

  defp confrontation_line!(venue, path) do
    register =
      "../../docs/authored-spec-carves/#{venue}.md"
      |> Path.expand(__DIR__)
      |> File.read!()

    task_section =
      case String.split(register, "**C-T594", parts: 2) do
        [_, rest] -> "**C-T594" <> hd(String.split(rest, "<!-- carve-evidence-status", parts: 2))
        _ -> flunk("#{venue}: missing Task 594 rate-unit confrontation")
      end

    Enum.find(String.split(task_section, "\n"), fn line -> String.contains?(line, "`#{path}`") end) ||
      flunk("#{venue}: Task 594 does not confront #{path}")
  end
end
