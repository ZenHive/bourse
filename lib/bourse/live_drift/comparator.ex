defmodule Bourse.LiveDrift.Comparator do
  @moduledoc """
  Compares live wire shapes with consumed paths from a committed recording.

  Values and unconsumed provider keys do not participate in failure decisions.
  """

  alias Bourse.LiveDrift.Failure
  alias Bourse.Registry

  @type comparison :: %{required(:failures) => [map()], required(:observations) => [map()]}

  @doc "Compares the consumed envelope and field types for one public method."
  @spec compare(String.t(), atom(), String.t(), String.t(), map(), map()) :: comparison()
  def compare(venue, method, parse_type, js_method, baseline_fixture, live_fixture) do
    module = Registry.lookup!(venue)
    envelope = get_in(module.__response_envelopes__(), [parse_type, js_method])
    mapping = Map.get(module.__field_maps__(), parse_type, %{})
    baseline_body = Map.fetch!(baseline_fixture, "body")
    live_body = Map.fetch!(live_fixture, "body")

    with {:ok, baseline_payload, envelope_path} <- payload(baseline_body, envelope),
         {:ok, live_payload, ^envelope_path} <- payload_at(live_body, envelope_path),
         :ok <- same_type(baseline_payload, live_payload) do
      compare_payload(
        venue,
        method,
        mapping,
        envelope,
        baseline_payload,
        live_payload,
        envelope_path
      )
    else
      {:error, field, expected, actual} ->
        %{failures: [failure(venue, method, field, expected, actual)], observations: []}
    end
  end

  @doc "Returns the targeted recapture command and authored-spec path for a stale method."
  @spec repair_paths(String.t(), atom()) :: %{
          required(:recapture) => String.t(),
          required(:reauthor) => String.t()
        }
  def repair_paths(venue, method) do
    %{
      recapture: "mix ccxt.record_fixtures #{venue} #{method}",
      reauthor: "priv/specs/json/output/authored/#{venue}.json"
    }
  end

  defp payload(body, %{"key" => key} = envelope) when is_binary(key) do
    keys = [key | Map.get(envelope, "fallback_keys", [])]

    case Enum.find(keys, &path_present?(body, split_path(&1))) do
      nil -> {:error, "$envelope", "configured_path", "missing"}
      selected -> {:ok, get_path(body, split_path(selected)), selected}
    end
  end

  defp payload(body, _envelope), do: {:ok, body, "$"}

  defp payload_at(body, "$"), do: {:ok, body, "$"}

  defp payload_at(body, path) do
    segments = split_path(path)

    if path_present?(body, segments) do
      {:ok, get_path(body, segments), path}
    else
      {:error, "$envelope.#{path}", "present", "missing"}
    end
  end

  defp same_type(baseline, live) do
    expected = json_type(baseline)
    actual = json_type(live)
    if expected == actual, do: :ok, else: {:error, "$envelope", expected, actual}
  end

  defp compare_payload(venue, method, mapping, envelope, baseline, live, envelope_path) do
    baseline_row = representative(baseline)
    live_row = representative(live)
    consumed_fields = consumed_fields(mapping, envelope)

    failures = Enum.flat_map(consumed_fields, &compare_field(&1, baseline_row, live_row, venue, method))

    observations = additive_observations(venue, method, baseline_row, live_row, envelope_path, consumed_fields)
    %{failures: failures, observations: observations}
  end

  defp consumed_fields(mapping, envelope) do
    transform_fields =
      case get_in(envelope || %{}, ["transform", "fields"]) do
        fields when is_map(fields) -> Enum.map(fields, fn {field, path} -> {field, [path]} end)
        _ -> []
      end

    transform_fields ++ mapping_fields(mapping)
  end

  defp mapping_fields(%{"branches" => branches}) when is_list(branches) do
    Enum.flat_map(branches, &mapping_fields/1)
  end

  defp mapping_fields(%{"field_map" => field_map} = mapping) when is_map(field_map) do
    fields = Enum.flat_map(field_map, fn {field, rule} -> rule_sources(field, rule) end)
    extras = Enum.flat_map(Map.get(mapping, "extras", []), &rule_sources(Map.get(&1, "unified_key", "extra"), &1))
    fields ++ extras
  end

  defp mapping_fields(_mapping), do: []

  defp rule_sources(_field, nil), do: []

  defp rule_sources(field, rule) when is_map(rule) do
    direct =
      case {Map.get(rule, "key"), Map.get(rule, "index")} do
        {key, _index} when is_binary(key) ->
          paths = [key | List.wrap(Map.get(rule, "fallback_keys"))]
          [{field, Enum.map(paths, &split_path/1)}]

        {nil, index} when is_integer(index) ->
          [{field, [[index]]}]

        _ ->
          []
      end

    nested =
      rule
      |> Map.drop(~w(key index fallback_keys))
      |> Map.values()
      |> Enum.flat_map(&rule_sources(field, &1))

    Enum.concat(direct, nested)
  end

  defp rule_sources(_field, _rule), do: []

  defp compare_field({field, candidates}, baseline, live, venue, method) do
    case Enum.find(candidates, &path_present?(baseline, &1)) do
      nil ->
        []

      path ->
        expected = baseline |> get_path(path) |> json_type()
        actual = if path_present?(live, path), do: live |> get_path(path) |> json_type(), else: "missing"

        if expected == actual do
          []
        else
          [failure(venue, method, "#{field}:#{render_path(path)}", expected, actual)]
        end
    end
  end

  defp additive_observations(venue, method, baseline, live, envelope_path, consumed_fields)
       when (is_map(baseline) and is_map(live)) or (is_list(baseline) and is_list(live)) do
    consumed_paths =
      consumed_fields
      |> Enum.flat_map(fn {_field, paths} -> paths end)
      |> MapSet.new()

    baseline
    |> added_paths(live, [])
    |> Enum.reject(&MapSet.member?(consumed_paths, &1))
    |> Enum.sort()
    |> Enum.map(fn path ->
      %{
        field: "#{envelope_path}.#{render_path(path)}",
        method: method,
        observation: "additive_unconsumed_key",
        venue: venue
      }
    end)
  end

  defp additive_observations(_venue, _method, _baseline, _live, _envelope_path, _consumed_fields), do: []

  defp added_paths(baseline, live, prefix) when is_map(baseline) and is_map(live) do
    baseline_keys = Map.keys(baseline)
    added = Enum.map(Map.keys(live) -- baseline_keys, &Enum.reverse([&1 | prefix]))

    nested =
      baseline_keys
      |> Enum.filter(&Map.has_key?(live, &1))
      |> Enum.flat_map(&added_paths(Map.fetch!(baseline, &1), Map.fetch!(live, &1), [&1 | prefix]))

    Enum.concat(added, nested)
  end

  defp added_paths([baseline | _], [live | _], prefix), do: added_paths(baseline, live, prefix)
  defp added_paths(_baseline, _live, _prefix), do: []

  defp failure(venue, method, field, expected, actual) do
    repair = repair_paths(venue, method)
    Failure.new(venue, method, field, expected, actual, repair.recapture, repair.reauthor)
  end

  defp representative([row | _]), do: row
  defp representative([]), do: []
  defp representative(value), do: value

  defp split_path(path), do: String.split(path, ".", trim: true)

  defp path_present?(_value, []), do: true

  defp path_present?(map, [key | rest]) when is_map(map) and is_binary(key) do
    Map.has_key?(map, key) and path_present?(Map.fetch!(map, key), rest)
  end

  defp path_present?(list, [index | rest]) when is_list(list) and is_integer(index) do
    case Enum.fetch(list, index) do
      {:ok, value} -> path_present?(value, rest)
      :error -> false
    end
  end

  defp path_present?(_value, _path), do: false

  defp get_path(value, []), do: value
  defp get_path(map, [key | rest]) when is_map(map), do: get_path(Map.fetch!(map, key), rest)
  defp get_path(list, [index | rest]) when is_list(list), do: get_path(Enum.fetch!(list, index), rest)

  defp render_path(path) do
    Enum.map_join(path, ".", fn
      index when is_integer(index) -> "[#{index}]"
      key -> key
    end)
  end

  defp json_type(value) when is_map(value), do: "object"
  defp json_type(value) when is_list(value), do: "array"
  defp json_type(value) when is_binary(value), do: "string"
  defp json_type(value) when is_number(value), do: "number"
  defp json_type(value) when is_boolean(value), do: "boolean"
  defp json_type(nil), do: "null"
  defp json_type(_value), do: "other"
end
