defmodule Bourse.Spec.Schema.OrderbookContinuity do
  @moduledoc """
  Validates `websocket.orderbook_semantics.continuity` for books that the venue
  maintains incrementally (`apply_mode` `incremental` or `both`).

  An incremental book without a continuity rule merges whatever arrives, so a
  dropped delta corrupts it with no signal. A venue in either mode must
  therefore author a rule whose fields are exactly its `sequence_fields`, or
  declare `"rule": "none"` with a reason and the provider document that shows
  the venue publishes no continuity id.
  """

  @incremental_modes ~w(incremental both)

  @rule_roles %{
    "first_follows_last" => ~w(first last),
    "previous_last" => ~w(first last previous),
    "previous_current" => ~w(current previous),
    "increment" => ~w(current)
  }

  @snapshot_sources ~w(rest stream)
  @unmarked_frames ~w(snapshot reject)

  @doc "Returns the continuity rules the runtime implements, mapped to the field roles each reads."
  @spec rule_roles() :: %{String.t() => [String.t()]}
  def rule_roles, do: @rule_roles

  @doc "Raises `ArgumentError` naming the gap when an incremental book's continuity contract is incomplete."
  @spec validate!(map(), String.t()) :: :ok
  def validate!(spec, exchange_id) do
    semantics = get_in(spec, ["websocket", "orderbook_semantics"]) || %{}

    if Map.get(semantics, "apply_mode") in @incremental_modes do
      validate_contract!(semantics, exchange_id)
    else
      :ok
    end
  end

  defp validate_contract!(semantics, exchange_id) do
    sequence_fields = Map.get(semantics, "sequence_fields")

    case Map.get(semantics, "continuity") do
      %{"rule" => "none"} = continuity ->
        validate_no_continuity!(continuity, sequence_fields, exchange_id)

      %{"rule" => rule} = continuity when is_map_key(@rule_roles, rule) ->
        validate_rule!(continuity, rule, sequence_fields, exchange_id)

      nil ->
        gap!(
          exchange_id,
          "continuity",
          "an incremental order book needs a continuity rule over its sequence_fields, " <>
            "or rule \"none\" with a doc-cited reason (sequence_fields: #{inspect(sequence_fields)})"
        )

      other ->
        gap!(exchange_id, "continuity rule", "unknown continuity #{inspect(other)}")
    end
  end

  defp validate_no_continuity!(continuity, sequence_fields, exchange_id) do
    require_string!(continuity, "reason", exchange_id)
    require_doc!(continuity, exchange_id)

    if sequence_fields != [] do
      gap!(exchange_id, "sequence_fields", "rule \"none\" declares no continuity id, so sequence_fields must be []")
    end

    :ok
  end

  defp validate_rule!(continuity, rule, sequence_fields, exchange_id) do
    roles = Map.fetch!(@rule_roles, rule)
    fields = Map.get(continuity, "fields")

    if !(is_map(fields) and Enum.sort(Map.keys(fields)) == roles and Enum.all?(Map.values(fields), &non_empty?/1)) do
      gap!(
        exchange_id,
        "continuity fields",
        "rule #{inspect(rule)} reads exactly #{inspect(roles)}, got #{inspect(fields)}"
      )
    end

    if !(is_list(sequence_fields) and Enum.sort(sequence_fields) == Enum.sort(Map.values(fields))) do
      gap!(
        exchange_id,
        "sequence_fields",
        "must be exactly the fields the continuity rule consumes (#{inspect(Enum.sort(Map.values(fields)))}), " <>
          "got #{inspect(sequence_fields)}"
      )
    end

    require_doc!(continuity, exchange_id)
    require_member!(continuity, "unmarked_frames", @unmarked_frames, exchange_id)
    require_member!(continuity, "snapshot_source", @snapshot_sources, exchange_id)
    validate_optional_string!(continuity, "market_path", exchange_id)
    validate_partial_depth_channel!(continuity, exchange_id)
    validate_snapshot_source!(continuity, exchange_id)
  end

  defp validate_snapshot_source!(%{"snapshot_source" => "rest"} = continuity, exchange_id) do
    case Map.get(continuity, "rest_snapshot") do
      %{"function" => f, "symbol_param" => s, "id_field" => i} = rest ->
        if !(Enum.all?([f, s, i], &non_empty?/1) and is_map(Map.get(rest, "params", %{}))) do
          gap!(exchange_id, "continuity rest_snapshot", "function, symbol_param and id_field must be strings")
        end

        require_string!(continuity, "market_path", exchange_id)

      other ->
        gap!(
          exchange_id,
          "continuity rest_snapshot",
          "a rest-bootstrapped book names its snapshot call, got #{inspect(other)}"
        )
    end
  end

  defp validate_snapshot_source!(%{"snapshot_source" => "stream"} = continuity, exchange_id) do
    require_string!(continuity, "subscription_path", exchange_id)
  end

  defp validate_partial_depth_channel!(continuity, exchange_id) do
    case Map.get(continuity, "partial_depth_channel") do
      nil ->
        :ok

      pattern when is_binary(pattern) ->
        case Regex.compile(pattern) do
          {:ok, regex} ->
            require_market_group!(regex, exchange_id)

          {:error, reason} ->
            gap!(exchange_id, "continuity partial_depth_channel", "invalid pattern: #{inspect(reason)}")
        end

      other ->
        gap!(exchange_id, "continuity partial_depth_channel", "expected a pattern or null, got #{inspect(other)}")
    end
  end

  defp require_market_group!(regex, exchange_id) do
    if "market" not in Regex.names(regex) do
      gap!(exchange_id, "continuity partial_depth_channel", "pattern must capture a named market group")
    end

    :ok
  end

  defp require_doc!(continuity, exchange_id) do
    case Map.get(continuity, "doc") do
      "https://" <> _ -> :ok
      other -> gap!(exchange_id, "continuity doc", "expected a provider documentation URL, got #{inspect(other)}")
    end
  end

  defp require_member!(continuity, key, allowed, exchange_id) do
    value = Map.get(continuity, key)

    if value not in allowed do
      gap!(exchange_id, "continuity #{key}", "expected one of #{inspect(allowed)}, got #{inspect(value)}")
    end
  end

  defp require_string!(continuity, key, exchange_id) do
    if !non_empty?(Map.get(continuity, key)) do
      gap!(exchange_id, "continuity #{key}", "required string is missing")
    end

    :ok
  end

  defp validate_optional_string!(continuity, key, exchange_id) do
    case Map.get(continuity, key) do
      nil -> :ok
      value when is_binary(value) and value != "" -> :ok
      other -> gap!(exchange_id, "continuity #{key}", "expected a string or null, got #{inspect(other)}")
    end
  end

  defp non_empty?(value), do: is_binary(value) and value != ""

  @spec gap!(String.t(), String.t(), String.t()) :: no_return()
  defp gap!(exchange_id, path, reason) do
    raise ArgumentError,
          "owned spec #{inspect(exchange_id)} gap websocket.orderbook_semantics.#{String.replace(path, " ", ".")}: #{reason}"
  end
end
