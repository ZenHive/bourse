defmodule Bourse.Spec.Schema do
  @moduledoc """
  Validation contract for complete, hand-owned runtime specifications.

  Required slots distinguish three states: a missing slot is an authoring gap,
  `null` is an explicit not-applicable value only where a leaf permits it, and
  an empty map or list is an explicit declaration with no entries. Required
  non-empty slots reject all three incomplete states by naming the exact path.
  """

  @version 3

  @required_non_empty_maps [
    ~w(exchange),
    ~w(raw describe),
    ~w(raw describe api),
    ~w(raw url_templates),
    ~w(endpoints),
    ~w(endpoints unified),
    ~w(capabilities),
    ~w(capabilities has),
    ~w(auth),
    ~w(normalization),
    ~w(normalization field_maps),
    ~w(normalization response_envelopes),
    ~w(markets),
    ~w(markets patterns),
    ~w(oracles),
    ~w(oracles live_tier1),
    ~w(oracles private_real_recordings),
    ~w(errors),
    ~w(errors handle_errors),
    ~w(websocket)
  ]

  @required_maps [
    ~w(auth signing_config),
    ~w(auth sign_recipe),
    ~w(config),
    ~w(endpoints request),
    ~w(errors handle_errors exception_scopes),
    ~w(fees),
    ~w(markets symbol_patterns),
    ~w(rate_limits),
    ~w(testnet),
    ~w(urls),
    ~w(websocket auth),
    ~w(websocket dispatch),
    ~w(websocket heartbeat),
    ~w(websocket ohlcv_semantics),
    ~w(websocket orderbook_semantics),
    ~w(websocket subscribe),
    ~w(websocket trades_semantics),
    ~w(websocket urls)
  ]

  @required_lists [
    ~w(auth authenticated_sections),
    ~w(emulated_methods),
    ~w(errors handle_errors runtime_body_checks),
    ~w(errors handle_errors runtime_code_fields),
    ~w(errors handle_errors error_code_fields)
  ]

  # `fees.static_market_fees` is the authored trigger for populating market
  # maker/taker from the venue's own published fee schedule. It is required, not
  # defaulted: a venue that omits it is an authoring gap, never an implicit "no".
  @required_booleans [~w(fees static_market_fees)]

  @forbidden_paths [
    ~w(_divergence_notes),
    ~w(_provenance),
    ~w(ccxt_version),
    ~w(extracted_at),
    ~w(oracle_provenance),
    ~w(auth headers),
    ~w(auth sign_method),
    ~w(raw class_info),
    ~w(raw method_inventory),
    ~w(raw overrides_meta),
    ~w(endpoints interfaces),
    ~w(endpoints pagination),
    ~w(normalization parse_methods_digest),
    ~w(markets precision_mode),
    ~w(markets symbols_index),
    ~w(errors handle_errors http_exceptions),
    ~w(errors handle_errors method),
    ~w(errors handle_errors throw_dispatches)
    # errors.handle_errors.exceptions is deliberately NOT forbidden. The owned
    # documents carry provider-authoritative classifications consumed by
    # Mix.Tasks.Ccxt.ErrorAuthorityCorpus (for example Bybit 180023).
  ]

  @support_values [true, false, "emulated"]
  @signing_patterns ~w(
    api_key_secret_headers
    deribit
    derive
    hmac_sha256_headers
    hmac_sha256_iso_passphrase
    hmac_sha256_query
    hyperliquid
    lighter
  )
  @symbol_market_types ~w(future option spot swap)
  @symbol_patterns ~w(
    dash_upper
    future_ddmmmyy
    future_yymmdd
    implicit
    no_separator_upper
    option_base_yymmdd
    option_base_yyyymmdd
    option_ddmmmyy
    option_with_settle
    option_yymmdd
    suffix_perp
    suffix_perpetual
    suffix_swap
    underscore_upper
  )
  @symbol_cases ~w(lower mixed upper)
  @date_formats ~w(ddmmmyy yymmdd yyyymmdd)
  @oracle_names ~w(live_tier1 private_real_recordings)

  @doc "Returns the current owned runtime-schema version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Returns the closed oracle-profile vocabulary."
  @spec oracle_names() :: [String.t()]
  def oracle_names, do: @oracle_names

  @doc "Validates one complete owned runtime specification."
  @spec validate!(map(), String.t()) :: map()
  def validate!(spec, exchange_id) when is_map(spec) and is_binary(exchange_id) do
    validate_version!(spec, exchange_id)
    validate_owned_markers!(spec, exchange_id)
    Enum.each(@required_non_empty_maps, &require_path!(spec, exchange_id, &1, :non_empty_map))
    Enum.each(@required_maps, &require_path!(spec, exchange_id, &1, :map))
    Enum.each(@required_lists, &require_path!(spec, exchange_id, &1, :list))
    Enum.each(@required_booleans, &require_path!(spec, exchange_id, &1, :boolean))
    Enum.each(@forbidden_paths, &forbid_path!(spec, exchange_id, &1))
    validate_identity!(spec, exchange_id)
    validate_signing_contract!(spec, exchange_id)
    validate_symbol_patterns!(spec, exchange_id)
    validate_emulated_methods!(spec, exchange_id)
    validate_runtime_error_contract!(spec, exchange_id)
    validate_support!(spec, exchange_id)
    validate_oracles!(spec, exchange_id)
    validate_option_quantity!(spec, exchange_id)
    validate_greeks_conventions!(spec, exchange_id)
    validate_order_status_policy!(spec, exchange_id)
    spec
  end

  defp validate_version!(%{"schema_version" => @version}, _exchange_id), do: :ok

  defp validate_version!(spec, exchange_id) do
    gap!(exchange_id, "schema_version", "expected #{@version}, got #{inspect(spec["schema_version"])}")
  end

  defp validate_owned_markers!(%{"authored" => true, "hand_owned" => true, "frozen" => true}, _exchange_id), do: :ok

  defp validate_owned_markers!(_spec, exchange_id) do
    gap!(exchange_id, "ownership", "expected authored, hand_owned and frozen to all be true")
  end

  defp require_path!(spec, exchange_id, path, expected) do
    case fetch_path(spec, path) do
      :error -> gap!(exchange_id, path, "missing required slot")
      {:ok, nil} -> gap!(exchange_id, path, "required slot is null")
      {:ok, value} -> validate_path_type!(value, exchange_id, path, expected)
    end
  end

  defp validate_path_type!(value, _exchange_id, _path, :map) when is_map(value), do: :ok
  defp validate_path_type!(value, _exchange_id, _path, :list) when is_list(value), do: :ok
  defp validate_path_type!(value, _exchange_id, _path, :boolean) when is_boolean(value), do: :ok

  defp validate_path_type!(value, _exchange_id, _path, :non_empty_map) when is_map(value) and map_size(value) > 0, do: :ok

  defp validate_path_type!(value, exchange_id, path, expected) do
    gap!(exchange_id, path, "expected #{expected}, got #{inspect(value)}")
  end

  defp forbid_path!(spec, exchange_id, path) do
    case fetch_path(spec, path) do
      :error -> :ok
      {:ok, _value} -> gap!(exchange_id, path, "field is forbidden in an owned runtime spec")
    end
  end

  defp validate_identity!(spec, exchange_id) do
    case get_in(spec, ["exchange", "id"]) do
      ^exchange_id -> :ok
      id -> gap!(exchange_id, ~w(exchange id), "expected #{inspect(exchange_id)}, got #{inspect(id)}")
    end

    case get_in(spec, ["exchange", "name"]) do
      name when is_binary(name) and name != "" -> :ok
      name -> gap!(exchange_id, ~w(exchange name), "expected a non-empty string, got #{inspect(name)}")
    end
  end

  defp validate_signing_contract!(spec, exchange_id) do
    auth = Map.fetch!(spec, "auth")

    case {auth["authenticated_sections"], auth["signing_pattern"], auth["signing_config"], auth["sign_recipe"]} do
      {[], nil, signing_config, sign_recipe} when signing_config == %{} and sign_recipe == %{} ->
        :ok

      {_sections, pattern, _signing_config, sign_recipe}
      when pattern in @signing_patterns and is_map(sign_recipe) and map_size(sign_recipe) > 0 ->
        :ok

      {_sections, pattern, _signing_config, sign_recipe} when pattern in @signing_patterns ->
        gap!(
          exchange_id,
          ~w(auth sign_recipe),
          "expected non_empty_map for signing pattern #{inspect(pattern)}, got #{inspect(sign_recipe)}"
        )

      {_sections, pattern, _signing_config, _sign_recipe} ->
        gap!(
          exchange_id,
          ~w(auth signing_pattern),
          "expected nil for an empty public-only auth contract or one of #{Enum.join(@signing_patterns, ", ")}, got #{inspect(pattern)}"
        )
    end
  end

  defp validate_symbol_patterns!(spec, exchange_id) do
    spec
    |> get_in(["markets", "symbol_patterns"])
    |> Enum.each(fn {market_type, config} ->
      if market_type not in @symbol_market_types do
        gap!(exchange_id, ["markets", "symbol_patterns", market_type], "unsupported market type")
      end

      validate_symbol_pattern!(config, exchange_id, market_type)
    end)
  end

  defp validate_symbol_pattern!(config, exchange_id, market_type) do
    if valid_symbol_pattern_fields?(config) do
      validate_quote_settled_suffix!(config, exchange_id, market_type)
    else
      gap!(
        exchange_id,
        ["markets", "symbol_patterns", market_type],
        "expected a complete authored symbol-pattern config, got #{inspect(config)}"
      )
    end
  end

  defp valid_symbol_pattern_fields?(%{
         "pattern" => pattern,
         "separator" => separator,
         "case" => symbol_case,
         "date_format" => date_format,
         "suffix" => suffix,
         "prefix" => prefix
       }) do
    pattern in @symbol_patterns and is_binary(separator) and symbol_case in @symbol_cases and
      optional_member?(date_format, @date_formats) and optional_string?(suffix) and optional_string?(prefix)
  end

  defp valid_symbol_pattern_fields?(_config), do: false

  defp optional_member?(nil, _allowed), do: true
  defp optional_member?(value, allowed), do: value in allowed

  defp optional_string?(nil), do: true
  defp optional_string?(value), do: is_binary(value)

  defp validate_quote_settled_suffix!(config, exchange_id, market_type) do
    case Map.get(config, "quote_settled_suffix") do
      value when is_nil(value) or is_binary(value) ->
        :ok

      value ->
        gap!(exchange_id, ["markets", "symbol_patterns", market_type], "invalid quote_settled_suffix #{inspect(value)}")
    end
  end

  defp validate_emulated_methods!(spec, exchange_id) do
    spec
    |> Map.fetch!("emulated_methods")
    |> Enum.with_index()
    |> Enum.each(fn {entry, index} ->
      path = ["emulated_methods", Integer.to_string(index)]

      if !(is_map(entry) and is_binary(entry["name"]) and entry["name"] != "" and
             entry["scope"] in ["rest", "ws"] and is_list(entry["reasons"]) and
             Enum.all?(entry["reasons"], &is_binary/1)) do
        gap!(exchange_id, path, "must name a rest/ws method with string reasons")
      end
    end)
  end

  defp validate_runtime_error_contract!(spec, exchange_id) do
    checks = get_in(spec, ["errors", "handle_errors", "runtime_body_checks"])
    fields = get_in(spec, ["errors", "handle_errors", "runtime_code_fields"])

    checks
    |> Enum.with_index()
    |> Enum.each(fn {check, index} ->
      path = ["errors", "handle_errors", "runtime_body_checks", Integer.to_string(index)]

      if !valid_runtime_error_check?(check) do
        gap!(exchange_id, path, "invalid authored runtime error check")
      end
    end)

    if !(fields != [] and fields == Enum.uniq(fields) and
           Enum.all?(fields, &(is_binary(&1) and &1 != ""))) do
      gap!(
        exchange_id,
        ~w(errors handle_errors runtime_code_fields),
        "must be a non-empty unique list of field names"
      )
    end

    validate_exception_scopes!(spec, exchange_id)
  end

  # Authored section→scope declaration must biject with scoped exception sub-maps
  # (keys under exceptions that are maps carrying exact/broad). A declared scope
  # with no sub-map is an authoring gap; a scoped sub-map with no route is too.
  defp validate_exception_scopes!(spec, exchange_id) do
    case get_in(spec, ["errors", "handle_errors", "exception_scopes"]) do
      declaration when is_map(declaration) ->
        authored_scopes = spec |> scoped_exception_submaps() |> MapSet.new()
        validate_exception_scope_entries!(declaration, exchange_id)
        validate_exception_scope_bijection!(declaration, authored_scopes, exchange_id)
        validate_exception_scope_sections!(declaration, spec, authored_scopes, exchange_id)

      other ->
        gap!(
          exchange_id,
          ~w(errors handle_errors exception_scopes),
          "expected a map of API-section keys to exception-scope names, got #{inspect(other)}"
        )
    end
  end

  defp validate_exception_scope_entries!(declaration, exchange_id) do
    invalid =
      Enum.reject(declaration, fn {section, scope} ->
        is_binary(section) and section != "" and is_binary(scope) and scope != ""
      end)

    if invalid != [] do
      gap!(
        exchange_id,
        ~w(errors handle_errors exception_scopes),
        "expected a map of API-section keys to exception-scope names, got invalid entries #{inspect(invalid)}"
      )
    end
  end

  defp validate_exception_scope_sections!(declaration, spec, authored_scopes, exchange_id) do
    available_sections = exception_scope_sections(spec)
    declared_sections = declaration |> Map.keys() |> MapSet.new()

    validate_declared_sections!(declared_sections, available_sections, exchange_id)

    if MapSet.size(authored_scopes) > 0 do
      validate_routed_sections!(declared_sections, available_sections, exchange_id)
      validate_scope_url_collisions!(declaration, spec, exchange_id)
    end
  end

  defp validate_declared_sections!(declared, available, exchange_id) do
    case declared |> MapSet.difference(available) |> MapSet.to_list() |> Enum.sort() do
      [] ->
        :ok

      [section | _] ->
        gap!(
          exchange_id,
          ~w(errors handle_errors exception_scopes) ++ [section],
          "declares an API section with no base URL"
        )
    end
  end

  defp validate_routed_sections!(declared, available, exchange_id) do
    case available |> MapSet.difference(declared) |> MapSet.to_list() |> Enum.sort() do
      [] ->
        :ok

      [section | _] ->
        gap!(
          exchange_id,
          ~w(errors handle_errors exception_scopes) ++ [section],
          "API section has no exception-scope declaration"
        )
    end
  end

  defp exception_scope_sections(spec) do
    spec
    |> exception_scope_entries()
    |> MapSet.new(&elem(&1, 0))
  end

  defp exception_scope_entries(spec) do
    Enum.flat_map(
      [get_in(spec, ["raw", "describe", "urls", "api"]), get_in(spec, ["testnet", "urls"])],
      &url_section_entries/1
    )
  end

  defp url_section_entries(map) when is_map(map) do
    Enum.flat_map(map, fn
      {section, url} when is_binary(section) and is_binary(url) ->
        [{section, url}]

      {section, nested} when is_binary(section) and is_map(nested) ->
        for {child, url} <- url_section_entries(nested), do: {"#{section}.#{child}", url}

      _ ->
        []
    end)
  end

  defp url_section_entries(_map), do: []

  defp validate_scope_url_collisions!(declaration, spec, exchange_id) do
    spec
    |> exception_scope_entries()
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.each(fn {url, sections} ->
      scopes = sections |> Enum.map(&Map.fetch!(declaration, &1)) |> Enum.uniq() |> Enum.sort()

      if length(scopes) > 1 do
        gap!(
          exchange_id,
          ~w(errors handle_errors exception_scopes),
          "base URL #{inspect(url)} routes to conflicting scopes #{inspect(scopes)}"
        )
      end
    end)
  end

  defp validate_exception_scope_bijection!(declaration, authored_scopes, exchange_id) do
    declared_scopes = declaration |> Map.values() |> MapSet.new()

    case declared_scopes |> MapSet.difference(authored_scopes) |> MapSet.to_list() |> Enum.sort() do
      [] ->
        :ok

      [scope | _] ->
        gap!(
          exchange_id,
          ~w(errors handle_errors exception_scopes),
          "declares scope #{inspect(scope)} with no exception sub-map"
        )
    end

    case authored_scopes |> MapSet.difference(declared_scopes) |> MapSet.to_list() |> Enum.sort() do
      [] ->
        :ok

      [scope | _] ->
        gap!(
          exchange_id,
          ~w(errors handle_errors exception_scopes),
          "scoped exception sub-map #{inspect(scope)} has no declaration routing to it"
        )
    end
  end

  defp scoped_exception_submaps(spec) do
    raw = exception_map(get_in(spec, ["raw", "describe", "exceptions"]))
    authored = exception_map(get_in(spec, ["errors", "handle_errors", "exceptions"]))
    merged = deep_merge_exception_maps(raw, authored)

    for {key, value} <- merged,
        key not in ["exact", "broad"],
        is_map(value),
        is_map(Map.get(value, "exact")) or is_map(Map.get(value, "broad")),
        do: key
  end

  defp exception_map(map) when is_map(map), do: map
  defp exception_map(_), do: %{}

  defp deep_merge_exception_maps(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge_exception_maps(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp valid_runtime_error_check?(%{
         "field" => field,
         "field2" => field2,
         "roles" => roles,
         "sentinel_values" => sentinels
       })
       when is_binary(field) and field != "" and (is_nil(field2) or is_binary(field2)) and is_list(roles) and
              is_list(sentinels) do
    roles != [] and Enum.all?(roles, &(&1 in ["error_code", "status_sentinel"])) and
      Enum.all?(sentinels, fn
        %{"operator" => operator, "value" => value}
        when operator in ["===", "!=="] and is_binary(value) ->
          true

        _ ->
          false
      end)
  end

  defp valid_runtime_error_check?(_check), do: false

  defp validate_support!(spec, exchange_id) do
    support = get_in(spec, ["capabilities", "has"])
    unified = get_in(spec, ["endpoints", "unified"])

    Enum.each(support, fn {method, declaration} ->
      if declaration not in @support_values do
        gap!(exchange_id, ["capabilities", "has", method], "expected true, false or \"emulated\"")
      end
    end)

    Enum.each(unified, fn {method, endpoints} ->
      validate_unified_support!(Map.fetch(support, method), endpoints, exchange_id, method)
    end)
  end

  defp validate_unified_support!(:error, _endpoints, exchange_id, method) do
    gap!(exchange_id, ["capabilities", "has", method], "missing support declaration")
  end

  defp validate_unified_support!({:ok, false}, endpoints, exchange_id, method) do
    require_endpoint_list_type!(endpoints, exchange_id, method)
  end

  defp validate_unified_support!({:ok, declaration}, endpoints, exchange_id, method)
       when declaration in [true, "emulated"] do
    require_endpoint_list!(endpoints, exchange_id, method)
  end

  defp require_endpoint_list_type!(endpoints, _exchange_id, _method) when is_list(endpoints), do: :ok

  defp require_endpoint_list_type!(_endpoints, exchange_id, method) do
    gap!(exchange_id, ["endpoints", "unified", method], "expected an endpoint list")
  end

  defp require_endpoint_list!(endpoints, _exchange_id, _method) when is_list(endpoints) and endpoints != [], do: :ok

  defp require_endpoint_list!(endpoints, exchange_id, method) do
    gap!(exchange_id, ["endpoints", "unified", method], "expected a non-empty endpoint list, got #{inspect(endpoints)}")
  end

  defp validate_oracles!(spec, exchange_id) do
    oracles = Map.fetch!(spec, "oracles")
    unexpected = Map.keys(oracles) -- @oracle_names

    if unexpected != [] do
      gap!(exchange_id, "oracles", "unsupported declarations: #{Enum.join(Enum.sort(unexpected), ", ")}")
    end

    Enum.each(@oracle_names, fn oracle ->
      validate_oracle!(Map.fetch!(oracles, oracle), exchange_id, oracle)
    end)
  end

  defp validate_oracle!(%{"grades" => true}, _exchange_id, _oracle), do: :ok

  defp validate_oracle!(%{"grades" => false, "reason" => reason} = declaration, exchange_id, oracle)
       when is_binary(reason) do
    if String.trim(reason) == "", do: invalid_oracle!(declaration, exchange_id, oracle), else: :ok
  end

  defp validate_oracle!(declaration, exchange_id, oracle) do
    invalid_oracle!(declaration, exchange_id, oracle)
  end

  @spec invalid_oracle!(term(), String.t(), String.t()) :: no_return()
  defp invalid_oracle!(declaration, exchange_id, oracle) do
    gap!(
      exchange_id,
      ["oracles", oracle],
      "expected grades=true or grades=false with a non-empty reason, got #{inspect(declaration)}"
    )
  end

  defp validate_option_quantity!(spec, exchange_id) do
    case get_in(spec, ["markets", "option_quantity"]) do
      nil ->
        :ok

      %{
        "canonical_unit" => "base",
        "wire_unit" => unit,
        "wire_field" => field,
        "contract_size" => recipe
      }
      when unit in ["base", "contracts"] and is_binary(field) and field != "" ->
        validate_contract_size_recipe!(recipe, unit, exchange_id)

      config ->
        gap!(
          exchange_id,
          ~w(markets option_quantity),
          "expected canonical base unit, named wire field, and base/contracts wire unit; got #{inspect(config)}"
        )
    end
  end

  defp validate_contract_size_recipe!(nil, "base", _exchange_id), do: :ok

  defp validate_contract_size_recipe!(%{"kind" => "field", "field" => field}, _unit, _exchange_id)
       when is_binary(field) and field != "", do: :ok

  defp validate_contract_size_recipe!(%{"kind" => "product", "fields" => [left, right]}, _unit, _exchange_id)
       when is_binary(left) and left != "" and is_binary(right) and right != "", do: :ok

  defp validate_contract_size_recipe!(recipe, unit, exchange_id) do
    gap!(
      exchange_id,
      ~w(markets option_quantity contract_size),
      "#{unit} quantities require null, one field, or a two-field product; got #{inspect(recipe)}"
    )
  end

  @greek_names ~w(delta gamma vega theta rho)

  defp validate_greeks_conventions!(spec, exchange_id) do
    case get_in(spec, ["markets", "greeks_conventions"]) do
      nil ->
        :ok

      table when is_map(table) ->
        Enum.each(@greek_names, &validate_greek_convention!(table, exchange_id, &1))

      other ->
        gap!(
          exchange_id,
          ~w(markets greeks_conventions),
          "expected a map of greek conventions; got #{inspect(other)}"
        )
    end
  end

  defp validate_greek_convention!(table, exchange_id, name) do
    case Map.fetch(table, name) do
      :error ->
        gap!(exchange_id, ["markets", "greeks_conventions", name], "missing greek convention")

      {:ok, entry} ->
        validate_greek_convention_entry!(entry, exchange_id, name)
    end
  end

  defp validate_greek_convention_entry!(%{"supported" => false} = entry, exchange_id, name) do
    if Map.get(entry, "native_field") in [nil, ""] do
      :ok
    else
      gap!(
        exchange_id,
        ["markets", "greeks_conventions", name],
        "unsupported greek must omit native_field; got #{inspect(entry)}"
      )
    end
  end

  defp validate_greek_convention_entry!(
         %{
           "supported" => true,
           "native_field" => field,
           "denomination" => denomination,
           "unit" => unit,
           "bump_size" => bump,
           "time_basis" => time_basis
         },
         _exchange_id,
         _name
       )
       when is_binary(field) and field != "" and is_binary(denomination) and denomination != "" and is_binary(unit) and
              unit != "" and is_number(bump) and (is_binary(time_basis) or is_nil(time_basis)) do
    :ok
  end

  defp validate_greek_convention_entry!(entry, exchange_id, name) do
    gap!(
      exchange_id,
      ["markets", "greeks_conventions", name],
      "expected supported flag plus native_field/denomination/unit/bump_size/time_basis; got #{inspect(entry)}"
    )
  end

  defp validate_order_status_policy!(spec, exchange_id) do
    spec
    |> get_in(["normalization", "field_maps", "order"])
    |> order_field_maps()
    |> Enum.each(&validate_order_status_rule!(&1["status"], exchange_id))
  end

  defp order_field_maps(%{"branches" => branches}) when is_list(branches) do
    Enum.flat_map(branches, fn
      %{"field_map" => field_map} when is_map(field_map) -> [field_map]
      _branch -> []
    end)
  end

  defp order_field_maps(%{"field_map" => field_map}) when is_map(field_map), do: [field_map]
  defp order_field_maps(_order_mapping), do: []

  defp validate_order_status_rule!(nil, _exchange_id), do: :ok

  defp validate_order_status_rule!(%{"enum_map" => enum_map} = rule, exchange_id)
       when is_map(enum_map) and map_size(enum_map) > 0 do
    if Map.has_key?(rule, "enum_default") do
      gap!(
        exchange_id,
        ~w(normalization field_maps order status enum_default),
        "order status must fail loudly unless enum_passthrough is explicitly true"
      )
    end
  end

  defp validate_order_status_rule!(%{"enum_passthrough" => true}, _exchange_id), do: :ok

  defp validate_order_status_rule!(rule, exchange_id) do
    gap!(
      exchange_id,
      ~w(normalization field_maps order status),
      "expected a non-empty enum_map or explicit enum_passthrough=true, got #{inspect(rule)}"
    )
  end

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch_path(value, rest)
      :error -> :error
    end
  end

  defp fetch_path(_value, _path), do: :error

  @spec gap!(String.t(), String.t() | [String.t()], String.t()) :: no_return()
  defp gap!(exchange_id, path, reason) when is_list(path) do
    gap!(exchange_id, Enum.join(path, "."), reason)
  end

  defp gap!(exchange_id, path, reason) do
    raise ArgumentError, "owned spec #{inspect(exchange_id)} gap #{path}: #{reason}"
  end
end
