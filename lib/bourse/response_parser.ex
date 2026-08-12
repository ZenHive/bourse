defmodule Bourse.ResponseParser do
  @moduledoc """
  Applies v4 normalization field maps to exchange responses.
  """

  alias Bourse.Precise
  alias Bourse.Safe

  @default_network_code_replacements %{
    "ETH" => %{"primary" => "ETH", "secondary" => "ERC20"},
    "CRO" => %{"primary" => "CRONOS", "secondary" => "CRC20"},
    "TRX" => %{"primary" => "TRX", "secondary" => "TRC20"},
    "BTC" => %{"primary" => "BTC", "secondary" => "BRC20"}
  }
  @milliseconds_per_hour 3_600_000

  @type parser_config :: map()
  @type context :: map() | keyword()
  @type parse_result :: {:ok, struct() | [struct()]} | {:error, term()}

  @doc """
  Applies a parser mapping to raw response data and builds the configured target struct.
  """
  @spec apply_mappings(term(), parser_config(), context()) :: parse_result()
  def apply_mappings(data, mapping, context) when is_map(mapping) do
    context = normalize_context(context)

    with {:ok, target} <- fetch_target(context),
         {:ok, parsed} <- parse_data(data, mapping, context) do
      {:ok, build_result(parsed, target)}
    end
  end

  def apply_mappings(_data, _mapping, _context), do: {:error, :invalid_mapping}

  @doc """
  Resolves the unified network code for a raw row against an authored `network_code` rule.

  Public because row *selection* (choosing which raw row answers a requested network,
  in the internal unified read-parse layer) must resolve the network exactly as the
  field extraction does. Two implementations would let the selected row and its
  parsed `network` disagree.

  The authored alias table answers first; a chain it does not know is resolved
  against the loaded currency catalog and the venue's network options, so a
  network listed after the last authoring pass surfaces with its unified code.
  Returns `nil` when neither knows the chain id. Carve C-T421 records the ordering.

      iex> rule = %{"network_aliases" => %{"USDT-TRC20" => "TRC20"}}
      iex> Bourse.ResponseParser.network_code_for_row(%{"chain" => "USDT-TRC20", "ccy" => "USDT"}, rule)
      "TRC20"

      iex> rule = %{"network_aliases" => %{"USDT-TRC20" => "TRC20"}}
      iex> Bourse.ResponseParser.network_code_for_row(%{"chain" => "USDT-Unlisted", "ccy" => "USDT"}, rule)
      nil
  """
  @spec network_code_for_row(term(), map()) :: String.t() | nil
  def network_code_for_row(data, rule) do
    network_code_for_row(data, rule, %{})
  end

  @doc false
  @spec network_code_for_row(term(), map(), map()) :: String.t() | nil
  def network_code_for_row(data, rule, currencies) when is_map(rule) and is_map(currencies) do
    id = Safe.string(Safe.value(data, rule["network_key"] || "chain", nil))
    currency = Safe.string(Safe.value(data, rule["currency_key"] || "ccy", nil))

    aliased_network_code(id, currency, rule) || catalog_network_code(currencies, currency, id)
  end

  def network_code_for_row(_data, _rule, _currencies), do: nil

  defp parse_data(data, mapping, context) when is_list(data) do
    cond do
      data == [] ->
        {:ok, []}

      list_of_records?(data, mapping, context) ->
        data
        |> Enum.map(&parse_one(&1, mapping, context))
        |> collect_results()

      true ->
        parse_one(data, mapping, context)
    end
  end

  defp parse_data(data, mapping, context), do: parse_one(data, mapping, context)

  defp list_of_records?([first | _], mapping, context) when is_map(first) or is_list(first) do
    match?({:ok, _field_map}, select_field_map(first, mapping, context))
  end

  defp list_of_records?(_data, _mapping, _context), do: false

  defp parse_one(data, mapping, context) do
    with {:ok, field_map} <- select_field_map(data, mapping, context) do
      extract_field_map(data, field_map, context)
    end
  end

  defp select_field_map(data, %{"branches" => branches}, context) when is_list(branches) do
    branches
    |> Enum.find(&branch_matches?(&1, data, context))
    |> case do
      %{"field_map" => field_map} when is_map(field_map) -> {:ok, field_map}
      _ -> {:error, :no_matching_parser_branch}
    end
  end

  defp select_field_map(_data, %{"field_map" => field_map, "route_field_maps" => route_field_maps}, %{route: route})
       when is_map(field_map) and is_map(route_field_maps) do
    case Map.fetch(route_field_maps, route) do
      {:ok, overrides} when is_map(overrides) -> {:ok, Map.merge(field_map, overrides)}
      _missing_route -> {:error, :no_matching_parser_branch}
    end
  end

  defp select_field_map(_data, %{"route_field_maps" => route_field_maps}, _context) when is_map(route_field_maps),
    do: {:error, :no_matching_parser_branch}

  defp select_field_map(_data, %{"field_map" => field_map}, _context) when is_map(field_map), do: {:ok, field_map}
  defp select_field_map(_data, field_map, _context) when is_map(field_map), do: {:ok, field_map}

  defp branch_matches?(%{"guard" => %{"input_shape" => "array"}}, data, _context), do: is_list(data)
  defp branch_matches?(%{"guard" => %{"input_shape" => "object"}}, data, _context), do: is_map(data)

  defp branch_matches?(%{"guard" => %{"has_key" => key}}, data, _context) when is_map(data) and is_binary(key),
    do: Map.has_key?(data, key)

  defp branch_matches?(%{"guard" => %{"kind" => "always"}}, _data, _context), do: true
  defp branch_matches?(%{"guard" => guard}, data, _context) when is_map(guard), do: payload_guard_matches?(guard, data)
  defp branch_matches?(_branch, _data, _context), do: false

  defp payload_guard_matches?(%{"field" => field, "in" => values}, data)
       when is_binary(field) and is_list(values) and is_map(data) do
    observed = data |> Safe.value(field, nil) |> to_string()
    Enum.any?(values, &(to_string(&1) == observed))
  end

  defp payload_guard_matches?(%{"field" => field, "equals" => value}, data) when is_binary(field) and is_map(data) do
    to_string(Safe.value(data, field, nil)) == to_string(value)
  end

  defp payload_guard_matches?(_guard, _data), do: false

  defp extract_field_map(data, field_map, context) do
    Enum.reduce_while(field_map, {:ok, %{}}, fn {field, rule}, {:ok, acc} ->
      output_field = normalize_output_key(field, context)
      field_context = Map.put(context, :field, output_field)

      case extract_field(data, rule, field_context) do
        {:error, _reason} = error -> {:halt, error}
        nil -> {:cont, {:ok, acc}}
        value -> {:cont, {:ok, Map.put(acc, output_field, value)}}
      end
    end)
  end

  defp extract_field(_data, nil, _context), do: nil

  defp extract_field(data, %{"kind" => "discriminated"} = rule, context) do
    branch_key = if truthy?(context_value(context, rule["discriminator"])), do: "true", else: "false"

    case Map.get(rule, branch_key) do
      branch when is_map(branch) -> extract_field(data, branch, context)
      _ -> nil
    end
  end

  # Payload-gated rule: evaluate `then` when the raw-row guard matches, else `else`.
  # Used when volume-unit semantics depend on a venue discriminator present on the
  # row itself (e.g. OKX `instType`), not on request-context market flags.
  defp extract_field(data, %{"kind" => "when"} = rule, context) do
    branch =
      if payload_guard_matches?(rule["guard"], data) do
        Map.get(rule, "then")
      else
        Map.get(rule, "else")
      end

    extract_field(data, branch, context)
  end

  defp extract_field(data, %{"kind" => "keyed_collection"} = rule, _context) do
    value_keys = keyed_collection_value_keys(rule)

    data
    |> Safe.value(rule["collection_key"], nil)
    |> keyed_collection_entries(data)
    |> Enum.reduce(%{}, fn entry, acc ->
      key = entry |> Safe.value(rule["index_key"], nil) |> coerce(rule["index_coercion"])
      value = keyed_collection_value(entry, value_keys, rule)

      if is_nil(key) or is_nil(value), do: acc, else: Map.put(acc, key, value)
    end)
  end

  defp extract_field(data, %{"kind" => "absolute"} = rule, _context) do
    data
    |> Safe.value_any(source_keys(rule), nil)
    |> decimal_absolute()
    |> coerce(rule["coercion"])
  end

  defp extract_field(data, %{"kind" => "sign_direction"} = rule, _context) do
    case data |> Safe.value_any(source_keys(rule), nil) |> decimal_compare_zero() do
      :lt -> rule["negative"]
      :eq -> rule["zero"]
      :gt -> rule["positive"]
      nil -> nil
    end
  end

  defp extract_field(data, %{"kind" => "trade_fee"} = rule, _context) do
    case data |> Safe.value_any(List.wrap(rule["cost_keys"]), nil) |> Safe.number() do
      nil ->
        nil

      cost ->
        Map.reject(
          %{
            "cost" => cost,
            "currency" => trade_fee_currency(data, rule, cost),
            "rate" => data |> Safe.value_any(List.wrap(rule["rate_keys"]), nil) |> Safe.number()
          },
          fn {_key, value} -> is_nil(value) end
        )
    end
  end

  defp extract_field(data, %{"kind" => "first_fee_entry"} = rule, _context) do
    case data |> Safe.value(rule["key"], nil) |> first_fee_entry() do
      {currency, cost} ->
        fee = %{"cost" => Safe.number(cost), "currency" => String.upcase(currency)}
        if rule["wrap_list"], do: [fee], else: fee

      nil ->
        nil
    end
  end

  defp extract_field(data, %{"kind" => "native_symbol"} = rule, context) do
    context[:symbol] || native_symbol(data, rule)
  end

  defp extract_field(data, %{"kind" => "currency_networks"} = rule, _context) do
    data
    |> currency_chains(rule)
    |> Map.new(&currency_network(&1, data, rule))
  end

  defp extract_field(data, %{"kind" => "currency_id"} = rule, context) do
    data
    |> Safe.value_any(source_keys(rule), nil)
    |> currency_code_for_id(context)
    |> coerce(rule["coercion"])
  end

  # The authored aliases are the fully-resolved projection of the two-step
  # `indexBy(networks, 'id')` -> `networkIdToCode(network)`; the catalog alone only
  # supplies step one. So aliases answer first and the catalog recovers the chains
  # they never saw, which would otherwise resolve to nil and drop the row. C-T421.
  defp extract_field(data, %{"kind" => "network_code"} = rule, context) do
    network_code_for_row(data, rule, context)
  end

  defp extract_field(data, %{"kind" => "currency_network_summary"} = rule, _context) do
    data
    |> currency_chains(rule)
    |> currency_network_summary(rule["field"], rule)
  end

  defp extract_field(data, %{"sub_field_map" => sub_field_map} = rule, context) when is_map(sub_field_map) do
    with {:ok, value} <- extract_field_map(data, sub_field_map, context) do
      cond do
        rule["omit_if_empty"] == true and map_size(value) == 0 -> nil
        rule["wrap_list"] -> [value]
        true -> value
      end
    end
  end

  # A computed scalar: read each operand as
  # a raw decimal string and combine money-exact. `op` is the linear operation;
  # when the market is inverse (`market.inverse` truthy in context) and an
  # `inverse_op` is authored, it wins — mirroring deribit `parseTrade`'s
  # `cost = inverse ? stringDiv(amount, price) : stringMul(amount, price)`.
  defp extract_field(data, %{"kind" => "computed"} = rule, context) do
    operands = Enum.map(Map.get(rule, "operands", []), &computed_operand(data, &1))

    if Enum.any?(operands, &is_nil/1) do
      nil
    else
      operands
      |> compute(computed_op(rule, context))
      |> scale(rule["scale"])
      |> round(rule["round"])
      |> truncate(rule["truncate"])
      |> truncate_to_market_price_precision(rule, context)
      |> coerce(rule["coercion"])
      |> format_value(rule["format"])
    end
  end

  defp extract_field(data, %{"kind" => "collection_member"} = rule, _context) do
    data
    |> Safe.value(rule["collection_key"], [])
    |> find_collection_member(rule)
    |> collection_member_value(rule)
    |> coerce(rule["coercion"])
  end

  defp extract_field(data, rule, context) when is_map(rule) do
    value = Safe.value_any(data, source_keys(rule), rule["default"])

    case map_enum(value, rule, context) do
      {:error, _reason} = error ->
        error

      mapped ->
        mapped
        # Scale before coerce so `Precise.string_mul` gets a decimal string (same as
        # the computed-field path). Used by Derive ticker percentage = change * 100.
        |> maybe_scale(rule["scale"])
        |> coerce(rule)
        |> maybe_zero_as_nil(rule)
        |> format_value(rule["format"])
    end
  end

  defp extract_field(_data, _rule, _context), do: nil

  # Scale before coerce so `Precise.string_mul` gets a decimal string.
  defp maybe_scale(value, nil), do: value
  defp maybe_scale(value, factor) when is_number(factor), do: value |> Safe.string() |> scale(factor)
  defp maybe_scale(value, _factor), do: value

  defp maybe_zero_as_nil(value, %{"zero_as_nil" => true}) when value in [0, 0.0], do: nil
  defp maybe_zero_as_nil(value, _rule), do: value

  defp source_keys(rule) do
    rule
    |> Map.take(["key", "index", "key2"])
    |> Map.values()
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(Map.get(rule, "fallback_keys", []))
  end

  defp keyed_collection_entries(entries, _data) when is_list(entries), do: entries
  # When the authored collection_key is absent (nil extraction) but the payload
  # itself is already a list of currency rows (OKX funding `asset/balances`),
  # treat the payload as the collection rather than dropping every row.
  defp keyed_collection_entries(_entries, data) when is_list(data), do: data
  defp keyed_collection_entries(_entries, data) when is_map(data), do: [data]
  defp keyed_collection_entries(_entries, _data), do: []

  # Prefer `value_key` then `value_key2` then any `fallback_keys` — mirrors
  # Chained fallback keys used by OKX trading free/total
  # (`availEq`/`availBal`, `eq`/`cashBal`) and funding `bal`.
  defp keyed_collection_value_keys(rule) when is_map(rule) do
    case rule["operand_keys"] do
      keys when is_list(keys) -> Enum.reject(keys, &is_nil/1)
      _ -> Enum.reject([rule["value_key"], rule["value_key2"] | List.wrap(rule["fallback_keys"])], &is_nil/1)
    end
  end

  defp keyed_collection_value(entry, value_keys, %{"when_keys_absent" => keys} = rule) when is_list(keys) do
    if Enum.all?(keys, &is_nil(Safe.value(entry, &1, nil))) do
      keyed_collection_value(entry, value_keys, Map.delete(rule, "when_keys_absent"))
    end
  end

  defp keyed_collection_value(entry, value_keys, %{"value_op" => "add"} = rule) do
    case value_keys |> Enum.map(&(entry |> Safe.value(&1, nil) |> Safe.string())) |> Enum.reject(&is_nil/1) do
      [] -> nil
      [value | values] -> values |> Enum.reduce(value, &Precise.string_add(&2, &1)) |> coerce(rule["coercion"])
    end
  end

  defp keyed_collection_value(entry, [left_key | rest_keys], %{"value_op" => "subtract"} = rule) do
    case entry |> Safe.value(left_key, nil) |> Safe.string() do
      nil ->
        nil

      base ->
        rest_keys
        |> Enum.reduce(base, &subtract_keyed_operand(entry, &1, &2))
        |> coerce(rule["coercion"])
    end
  end

  defp keyed_collection_value(entry, value_keys, rule) do
    entry |> Safe.value_any(value_keys, nil) |> coerce(rule["coercion"])
  end

  defp subtract_keyed_operand(entry, key, total) do
    case entry |> Safe.value(key, nil) |> Safe.string() do
      nil -> total
      operand -> total |> Decimal.new() |> Decimal.sub(Decimal.new(operand)) |> Decimal.to_string(:normal)
    end
  end

  defp first_fee_entry(fees) when is_map(fees) do
    Enum.find_value(fees, fn
      {currency, cost} when is_binary(currency) -> {currency, cost}
      _ -> nil
    end)
  end

  defp first_fee_entry(_fees), do: nil

  defp decimal_absolute(nil), do: nil

  defp decimal_absolute(value) do
    value
    |> Safe.string()
    |> Decimal.new()
    |> Decimal.abs()
    |> Decimal.to_string(:normal)
  rescue
    Decimal.Error -> nil
  end

  defp decimal_compare_zero(nil), do: nil

  defp decimal_compare_zero(value) do
    value
    |> Safe.string()
    |> Decimal.new()
    |> Decimal.compare(Decimal.new(0))
  rescue
    Decimal.Error -> nil
  end

  defp trade_fee_currency(data, rule, cost) do
    explicit = data |> Safe.value_any(List.wrap(rule["currency_keys"]), nil) |> Safe.string()

    if explicit do
      String.upcase(explicit)
    else
      derived_trade_fee_currency(data, rule, cost)
    end
  end

  defp derived_trade_fee_currency(data, rule, cost) do
    with native when is_binary(native) <- Safe.string(Safe.value(data, rule["symbol_key"], nil)),
         {base, quote} <- split_native_symbol(native, rule) do
      if contract_trade?(data, rule) do
        quote
      else
        spot_fee_currency(base, quote, Safe.string(Safe.value(data, rule["side_key"], nil)), cost)
      end
    else
      _ -> nil
    end
  end

  defp contract_trade?(data, rule) do
    Enum.any?(List.wrap(rule["contract_keys"]), &(Safe.value(data, &1, nil) != nil)) or
      Safe.value(data, rule["contract_type_key"], nil) in List.wrap(rule["contract_type_values"])
  end

  defp spot_fee_currency(base, quote, side, cost) do
    positive? = decimal_compare_zero(cost) == :gt

    case {String.downcase(side || ""), positive?} do
      {"buy", true} -> base
      {"sell", true} -> quote
      {"buy", false} -> quote
      {"sell", false} -> base
      _ -> nil
    end
  end

  defp native_symbol(data, rule) do
    if Safe.value(data, rule["when_key"], nil) == rule["when_value"] do
      build_native_symbol(data, rule)
    end
  end

  defp build_native_symbol(data, rule) do
    with native when is_binary(native) <- Safe.string(Safe.value(data, rule["key"], nil)),
         {base, quote} <- split_native_symbol(native, rule) do
      format_native_symbol(base, quote, rule["market_type"])
    else
      _ -> nil
    end
  end

  defp format_native_symbol(base, quote, "contract"), do: "#{base}/#{quote}:#{quote}"
  defp format_native_symbol(base, quote, _market_type), do: "#{base}/#{quote}"

  defp split_native_symbol(native, rule) do
    rule
    |> Map.get("quote_currencies", [])
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.find_value(fn quote ->
      base = String.replace_suffix(native, quote, "")
      if base != native and base != "", do: {base, quote}
    end)
  end

  defp currency_chains(data, rule) do
    case Safe.value(data, rule["collection_key"] || "chains", []) do
      chains when is_list(chains) -> chains
      _ -> []
    end
  end

  # Currency-wide rollup of the per-chain rows (collapse each network's
  # flags/fees onto the parent currency).
  #
  # `active` uses the same per-chain deposit/withdraw rule as network-level
  # `active` (`active_requires_both` — see `network_active?/3`). Owned currency
  # maps declare the flag explicitly.
  defp currency_network_summary(chains, "active", rule) do
    Enum.any?(chains, fn chain ->
      deposit? = network_enabled?(chain, deposit_key(rule))
      withdraw? = network_enabled?(chain, withdraw_key(rule))
      network_active?(deposit?, withdraw?, rule)
    end)
  end

  defp currency_network_summary(chains, "deposit", rule), do: Enum.any?(chains, &network_enabled?(&1, deposit_key(rule)))

  defp currency_network_summary(chains, "withdraw", rule),
    do: Enum.any?(chains, &network_enabled?(&1, withdraw_key(rule)))

  defp currency_network_summary(chains, "fee", rule), do: minimum_number(enabled_fee_chains(chains, rule), fee_key(rule))
  defp currency_network_summary(chains, "precision", rule), do: minimum_precision(chains, rule)
  defp currency_network_summary(chains, "limits", rule), do: currency_limits(chains, rule)
  defp currency_network_summary(_chains, _field, _rule), do: nil

  defp deposit_key(rule), do: rule["deposit_key"] || "chainDeposit"
  defp withdraw_key(rule), do: rule["withdraw_key"] || "chainWithdraw"
  defp fee_key(rule), do: rule["fee_key"] || "withdrawFee"

  defp currency_network(chain, currency, rule) do
    id = Safe.string(Safe.value(chain, rule["network_key"] || "chain", nil))
    code = network_code(id, Safe.string(Safe.value(currency, rule["currency_key"] || "coin", nil)), rule)
    deposit? = network_enabled?(chain, deposit_key(rule))
    withdraw? = network_enabled?(chain, withdraw_key(rule))

    {code,
     %{
       "info" => chain,
       "id" => id,
       "network" => code,
       "active" => network_active?(deposit?, withdraw?, rule),
       "deposit" => deposit?,
       "withdraw" => withdraw?,
       "fee" => Safe.number(Safe.value(chain, rule["fee_key"] || "withdrawFee", nil)),
       "precision" => chain_precision(chain, rule),
       "limits" => network_limits(chain, rule)
     }}
  end

  defp network_code(id, currency, rule) do
    code =
      rule
      |> get_in(["network_aliases", currency])
      |> case do
        aliases when is_map(aliases) -> Map.get(aliases, id, network_alias(id, rule))
        _ -> network_alias(id, rule)
      end

    # Native-chain codes collapse to the currency code
    # (ETH/ERC20 → ETH for ETH, TRX/TRC20 → TRX for TRX) after id→code aliasing.
    case get_in(rule, ["implied_networks", currency, code]) do
      implied when is_binary(implied) -> implied
      _ -> code
    end
  end

  defp aliased_network_code(id, currency, rule) when is_binary(id) do
    code =
      case get_in(rule, ["network_aliases", currency]) do
        aliases when is_map(aliases) -> Map.get(aliases, id) || get_in(rule, ["network_aliases", id])
        _ -> get_in(rule, ["network_aliases", id])
      end

    case get_in(rule, ["implied_networks", currency, code]) do
      implied when is_binary(implied) -> implied
      _ -> code
    end
  end

  defp aliased_network_code(_id, _currency, _rule), do: nil

  defp catalog_network_code(context, currency, id) when is_binary(currency) and is_binary(id) do
    currencies = Map.get(context, :currencies, context)
    aliases = Map.get(context, :common_currencies, %{})
    options = Map.get(context, :options, %{})

    currencies
    |> Map.get(currency_code(currency, aliases))
    |> currency_networks()
    |> Enum.find_value(fn {code, network} ->
      if network_id(network) == id and is_binary(code) do
        network
        |> network_code(code)
        |> network_id_to_code(currency_code(currency, aliases), options)
      end
    end)
  end

  defp catalog_network_code(_currencies, _currency, _id), do: nil

  defp currency_networks(%{networks: networks}) when is_map(networks), do: networks
  defp currency_networks(%{"networks" => networks}) when is_map(networks), do: networks
  defp currency_networks(_currency), do: %{}

  defp currency_code_for_id(id, %{currencies: currencies}) when is_map(currencies) do
    case Safe.string(id) do
      nil -> nil
      id -> Enum.find_value(currencies, &currency_code_matching_id(&1, id))
    end
  end

  defp currency_code_for_id(_id, _context), do: nil

  defp currency_code_matching_id({fallback_code, currency}, id) do
    if Safe.string(Safe.value(currency, "id", nil)) == id do
      Safe.string(Safe.value(currency, "code", fallback_code))
    end
  end

  defp network_id(%{id: id}), do: Safe.string(id)
  defp network_id(%{"id" => id}), do: Safe.string(id)
  defp network_id(_network), do: nil

  defp network_code(%{network: network}, _fallback), do: Safe.string(network)
  defp network_code(%{"network" => network}, _fallback), do: Safe.string(network)
  defp network_code(_network, fallback), do: fallback

  # Venue overrides map raw network ids first, then the
  # base default replacement keeps native-chain and token-chain codes distinct.
  defp network_id_to_code(network_id, currency, options) when is_binary(network_id) and is_map(options) do
    options
    |> network_codes_by_id()
    |> Map.get(network_id, network_id)
    |> preferred_network_code(currency, default_network_code_replacements(options))
  end

  defp network_id_to_code(_network_id, _currency, _options), do: nil

  # The runtime network id-to-code table is the
  # inversion of `options.networks`, with any hand-authored `networksById`
  # extended over it. `describe` carries only the overrides (okx ships 3 of them
  # against 73 `networks` entries), so without the inversion the lookup is a
  # near-identity and the port would resolve almost nothing.
  defp network_codes_by_id(options) do
    options
    |> Map.get("networks", Map.get(options, :networks, %{}))
    |> invert_networks()
    |> Map.merge(Map.get(options, "networksById", Map.get(options, :networksById, %{})))
  end

  # Mirrors `invertFlatStringDictionary`: string pairs only. Two codes sharing an
  # id (okx maps both `ETH` and `ERC20` to id `ERC20`) collide arbitrarily here
  # by insertion order; the authored `networksById`
  # override merged on top is what makes those cases deterministic.
  defp invert_networks(networks) when is_map(networks) do
    for {code, id} <- networks, is_binary(code), is_binary(id), into: %{}, do: {id, code}
  end

  defp invert_networks(_networks), do: %{}

  defp default_network_code_replacements(options) do
    Map.get(
      options,
      "defaultNetworkCodeReplacements",
      Map.get(options, :defaultNetworkCodeReplacements, @default_network_code_replacements)
    )
  end

  defp preferred_network_code(code, currency, replacements) when is_map(replacements) do
    Enum.find_value(replacements, code, &replacement_network_code(&1, code, currency))
  end

  defp preferred_network_code(code, _currency, _replacements), do: code

  defp replacement_network_code({base, replacement}, code, currency) do
    primary = Safe.string(Safe.value(replacement, "primary", nil))
    secondary = Safe.string(Safe.value(replacement, "secondary", nil))

    replacement_network_code(code, currency, base, primary, secondary)
  end

  defp replacement_network_code(code, currency, base, primary, secondary) when code in [primary, secondary] do
    if currency == base, do: primary, else: secondary
  end

  defp replacement_network_code(_code, _currency, _base, _primary, _secondary), do: nil

  defp currency_code(currency, aliases) when is_binary(currency) and is_map(aliases) do
    currency = String.upcase(currency)
    Map.get(aliases, currency, currency)
  end

  defp currency_code(currency, _aliases), do: currency

  defp network_alias(id, rule) do
    case get_in(rule, ["network_aliases", id]) do
      alias_code when is_binary(alias_code) -> alias_code
      _ -> id
    end
  end

  defp network_enabled?(chain, key), do: Safe.value(chain, key, nil) in [true, 1, "1"]

  # Per-chain (and currency-summary) active from directional deposit/withdraw flags.
  # Owned venues author `active_requires_both` explicitly on every rule that
  # rolls active from directional flags.
  defp network_active?(deposit?, withdraw?, %{"active_requires_both" => true}), do: deposit? and withdraw?
  defp network_active?(deposit?, withdraw?, %{"active_requires_both" => false}), do: deposit? or withdraw?

  # Binance `withdrawIntegerMultiple` is already a tick size (float step); bybit /
  # okx `minAccuracy` / `wdTickSz` are decimal-place counts → 10^-digits.
  defp chain_precision(chain, %{"precision_mode" => "tick_size"} = rule) do
    key = rule["precision_key"] || "withdrawIntegerMultiple"
    fallback = rule["precision_fallback_key"] || "withdrawInternalMin"

    positive_number(Safe.value(chain, key, nil)) || positive_number(Safe.value(chain, fallback, nil))
  end

  defp chain_precision(chain, rule) do
    case Safe.integer(Safe.value(chain, rule["precision_key"] || "minAccuracy", nil)) do
      digits when is_integer(digits) and digits >= 0 -> :math.pow(10, -digits)
      _ -> nil
    end
  end

  defp positive_number(value) do
    case Safe.number(value) do
      n when is_number(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp minimum_precision(chains, rule) do
    values =
      chains
      |> maybe_filter_precision_chains(rule)
      |> Enum.map(&chain_precision(&1, rule))
      |> Enum.reject(&is_nil/1)

    # Pick the coarsest tick (max step) when networks
    # disagree; bybit/okx keep the finest (min step). Authored via aggregate.
    case rule["precision_aggregate"] do
      "max" -> maximum(values)
      _ -> minimum(values)
    end
  end

  defp maybe_filter_precision_chains(chains, %{"precision_enabled_key" => key}) do
    Enum.filter(chains, &(Safe.value(&1, key, nil) in [true, 1, "1"]))
  end

  defp maybe_filter_precision_chains(chains, _rule), do: chains

  defp enabled_fee_chains(chains, %{"fee_enabled_key" => key}) do
    Enum.filter(chains, &(Safe.value(&1, key, nil) in [true, 1, "1"]))
  end

  defp enabled_fee_chains(chains, _rule), do: chains

  defp minimum_number(chains, key) do
    chains
    |> Enum.map(&(&1 |> Safe.value(key, nil) |> Safe.number()))
    |> Enum.reject(&is_nil/1)
    |> minimum()
  end

  defp minimum([]), do: nil
  defp minimum(values), do: Enum.min(values)

  defp maximum([]), do: nil
  defp maximum(values), do: Enum.max(values)

  defp currency_limits(chains, rule) do
    limits = %{
      "withdraw" => %{
        "min" => minimum_number(chains, rule["withdraw_min_key"] || "withdrawMin"),
        "max" => maximum_number(chains, rule["withdraw_max_key"])
      },
      "deposit" => %{"min" => minimum_number(chains, rule["deposit_min_key"] || "depositMin"), "max" => nil}
    }

    # Binance static fixtures omit the empty `amount` shell that okx/bybit goldens
    # carry; author `include_amount_limits: false` when the venue fixture has no amount key.
    if rule["include_amount_limits"] == false do
      limits
    else
      Map.put(limits, "amount", %{"min" => nil, "max" => nil})
    end
  end

  defp network_limits(chain, rule) do
    limits = %{
      "withdraw" => %{
        "min" => Safe.number(Safe.value(chain, rule["withdraw_min_key"] || "withdrawMin", nil)),
        "max" => Safe.number(Safe.value(chain, rule["withdraw_max_key"], nil))
      }
    }

    if rule["include_deposit_limits"] == false do
      limits
    else
      Map.put(limits, "deposit", %{
        "min" => Safe.number(Safe.value(chain, rule["deposit_min_key"] || "depositMin", nil)),
        "max" => nil
      })
    end
  end

  defp maximum_number(_chains, nil), do: nil

  defp maximum_number(chains, key) do
    chains
    |> Enum.map(&(&1 |> Safe.value(key, nil) |> Safe.number()))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      values -> Enum.max(values)
    end
  end

  defp map_enum(nil, _rule, _context), do: nil

  defp map_enum(value, %{"enum_map" => enum_map} = rule, context) when is_map(enum_map) do
    case Map.fetch(enum_map, to_string(value)) do
      {:ok, mapped} -> mapped
      :error -> enum_fallback(value, rule, context)
    end
  end

  defp map_enum(value, _rule, _context), do: value

  # Most unmapped enum values drop to the authored `enum_default` (nil when absent).
  # Ledger types and order statuses are strict because losing a provider addition is
  # silent data corruption. Two authored opt-ins keep the venue's own identifier:
  # `"enum_fallback": "raw"` (Binance network ids — the real vocabulary is open-ended,
  # nil-ing an identifier the venue DID supply loses more than leaving it unnormalized)
  # and `"enum_passthrough": true` (fall back to the raw enum value when no mapping
  # exists).
  defp enum_fallback(value, %{"enum_passthrough" => true}, _context), do: value

  defp enum_fallback(value, rule, %{target: Bourse.LedgerEntry, field: "type"} = context) do
    {:error,
     {:unmapped_ledger_type,
      %{
        venue: context.venue,
        field: rule["key"] || "type",
        raw_value: value
      }}}
  end

  defp enum_fallback(value, rule, %{target: Bourse.Order, field: "status"} = context) do
    {:error,
     {:unmapped_order_status,
      %{
        venue: context.venue,
        field: rule["key"] || "status",
        raw_value: value
      }}}
  end

  defp enum_fallback(value, %{"enum_fallback" => "raw"}, _context), do: value
  defp enum_fallback(_value, rule, _context), do: rule["enum_default"]

  defp find_collection_member(entries, rule) when is_list(entries) do
    Enum.find_value(collection_match_values(rule), fn match_value ->
      Enum.find(entries, fn entry ->
        Safe.value(entry, rule["match_key"], nil) == match_value
      end)
    end)
  end

  defp find_collection_member(_entries, _rule), do: nil

  # Prefer an ordered `match_values` list (e.g. Binance NOTIONAL before MIN_NOTIONAL);
  # fall back to singular `match_value` for existing field maps.
  defp collection_match_values(%{"match_values" => values}) when is_list(values), do: values
  defp collection_match_values(%{"match_value" => value}), do: [value]
  defp collection_match_values(_rule), do: []

  defp collection_member_value(nil, rule), do: rule["default"]

  defp collection_member_value(member, rule) when is_map(member) do
    Safe.value_any(member, source_keys(rule), rule["default"])
  end

  defp collection_member_value(_member, rule), do: rule["default"]

  defp computed_op(rule, context) do
    if truthy?(context_value(context, "market.inverse")) and rule["inverse_op"] do
      rule["inverse_op"]
    else
      rule["op"]
    end
  end

  defp computed_operand(data, key) when is_binary(key), do: data |> Safe.value(key, nil) |> Safe.string()

  defp computed_operand(data, rule) when is_map(rule) do
    data
    |> Safe.value_any(source_keys(rule), nil)
    |> Safe.string()
  end

  defp computed_operand(_data, _operand), do: nil

  defp compute([left, right], "mul"), do: Precise.string_mul(left, right)
  defp compute([left, right], "div"), do: Precise.string_div(left, right)
  defp compute([left, right], "add"), do: Precise.string_add(left, right)

  defp compute([left, right], "average") do
    left
    |> Precise.string_add(right)
    |> Precise.string_div("2")
  end

  defp compute([left, right], "sub") do
    left
    |> Decimal.new()
    |> Decimal.sub(Decimal.new(right))
    |> Decimal.to_string(:normal)
  end

  # Ticker percentage = (last - open) / open * 100 (OKX and similar venues).
  defp compute([left, right], "percent_change") do
    open = Decimal.new(right)

    if Decimal.equal?(open, 0) do
      nil
    else
      left
      |> Decimal.new()
      |> Decimal.sub(open)
      |> Decimal.div(open)
      |> Decimal.mult(Decimal.new(100))
      |> Decimal.to_string(:normal)
    end
  end

  # Position percentage divides unrealized PnL by initial margin at four decimal
  # places before multiplying by 100. The division is truncated before the
  # multiplication, which is why Deribit's inverse-perp case reads -1.45 and not the
  # -1.4592 a full-precision divide would give. That ordering cannot be expressed
  # by composing `div` with the rule pipeline's `scale`/`truncate` knobs (scale
  # runs first), so the recipe lives here as one op.
  defp compute([left, right], "pnl_percentage") do
    left
    |> Precise.string_div(right, 4)
    |> Precise.string_mul("100")
  end

  defp compute(_operands, _op), do: nil

  defp scale(nil, _factor), do: nil
  defp scale(value, factor) when is_number(factor), do: Precise.string_mul(value, to_string(factor))
  defp scale(value, _factor), do: value

  defp round(nil, _precision), do: nil

  defp round(value, precision) when is_integer(precision) and precision >= 0 do
    value
    |> Decimal.new()
    |> Decimal.round(precision, :half_even)
    |> Decimal.to_string(:normal)
  end

  defp round(value, _precision), do: value

  defp truncate(nil, _precision), do: nil

  defp truncate(value, precision) when is_integer(precision) and precision >= 0 do
    value
    |> Decimal.new()
    |> Decimal.round(precision, :down)
    |> Decimal.to_string(:normal)
  end

  defp truncate(value, _precision), do: value

  # Round a derived ticker average to the loaded market's price
  # precision when a market cache is available. Preserve full precision when it
  # is not, so ordinary parser callers remain cache-independent.
  defp truncate_to_market_price_precision(value, %{"op" => "average"}, context) do
    truncate(value, market_price_precision(context[:market]))
  end

  defp truncate_to_market_price_precision(value, _rule, _context), do: value

  defp market_price_precision(%{precision: precision}) when is_map(precision), do: price_precision(precision[:price])
  defp market_price_precision(%{"precision" => precision}) when is_map(precision), do: price_precision(precision["price"])
  defp market_price_precision(_market), do: nil

  defp price_precision(value) when is_number(value), do: value |> to_string() |> price_precision()

  defp price_precision(value) when is_binary(value) do
    case String.split(value, ".", parts: 2) do
      [_integer, fraction] -> fraction |> String.trim_trailing("0") |> String.length()
      _ -> 0
    end
  end

  defp price_precision(_value), do: nil

  defp coerce(value, coercion) when coercion in ["safeString", "safeString2"], do: Safe.string(value)
  defp coerce(value, coercion) when coercion in ["safeStringLower", "safeStringLower2"], do: Safe.string_lower(value)

  # Symbol resolution uses the loaded market cache. The parser owns no
  # cache; symbol-scoped unified reads supply the authoritative request symbol in
  # ReadParse, while multi-symbol reads retain the native id for indexing.
  defp coerce(value, "safeSymbol"), do: Safe.string(value)

  defp coerce(value, "safeCurrencyCode") do
    case Safe.string(value) do
      nil -> nil
      code -> String.upcase(code)
    end
  end

  defp coerce(value, coercion) when coercion in ["safeInteger", "safeInteger2"], do: Safe.integer(value)
  defp coerce(value, "safeIntegerOmitZero"), do: omit_zero_integer(value)
  defp coerce(value, "safeIntegerProduct"), do: seconds_to_ms(value)
  defp coerce(value, "safeTimestamp2"), do: seconds_to_ms(value)
  defp coerce(value, %{"coercion" => "safeTimestamp", "format" => "s"}), do: seconds_to_ms(value)
  defp coerce(value, %{"coercion" => "safeTimestamp", "format" => "ms"}), do: Safe.integer(value)

  # `"format": null` is the catalog's pervasive "not annotated" idiom (it appears
  # on safeString rules too), NOT an unsupported format — five runtime rules carry
  # it. Matching only on key absence dropped all five to nil; they take the
  # documented-seconds default alongside a genuinely absent key. Only an explicit
  # format we do not recognise drops the value.
  defp coerce(value, %{"coercion" => "safeTimestamp", "format" => nil}), do: seconds_to_ms(value)

  defp coerce(value, %{"coercion" => "safeTimestamp"} = rule) when not is_map_key(rule, "format"),
    do: seconds_to_ms(value)

  defp coerce(_value, %{"coercion" => "safeTimestamp"}), do: nil

  # Authored field maps tag datetime slots with coercion "iso8601". Resolution
  # follows the rule's declared `format` the same way `safeTimestamp` does —
  # deepcoin CreateTime / whitebit fundingTime declare `"format": "s"` and are
  # Unix seconds on the wire; most other catalog rules declare `"ms"`. Absent or
  # null format keeps the historical milliseconds default (unlike safeTimestamp,
  # whose unannotated default is seconds).
  defp coerce(value, %{"coercion" => "iso8601", "format" => "s"}), do: iso8601_from_seconds(value)
  defp coerce(value, %{"coercion" => "iso8601", "format" => "ms"}), do: iso8601_from_ms(value)
  defp coerce(value, %{"coercion" => "iso8601", "format" => nil}), do: iso8601_from_ms(value)

  defp coerce(value, %{"coercion" => "iso8601"} = rule) when not is_map_key(rule, "format"), do: iso8601_from_ms(value)

  defp coerce(_value, %{"coercion" => "iso8601"}), do: nil
  defp coerce(value, rule) when is_map(rule), do: coerce(value, rule["coercion"])
  defp coerce(value, "epochMsOrDatetime"), do: epoch_ms_or_datetime(value)

  defp coerce(value, coercion) when coercion in ["safeNumber", "safeNumber2", "parseNumber(safeString)"],
    do: Safe.number(value)

  defp coerce(value, "parseNumber(omitZero(safeString))"), do: omit_zero_number(value)
  defp coerce(value, "parseNumber(parsePrecision(safeString))"), do: precision_to_tick_size(value)
  defp coerce(value, "parse8601"), do: parse_iso8601(value)
  defp coerce(value, "safeNumberCanonical"), do: canonical_number(value)
  defp coerce(value, "decimalPlacesToTickSize") when is_integer(value) and value >= 0, do: :math.pow(10, -value)

  defp coerce(value, "decimalPlacesToTickSize") when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> :math.pow(10, -n)
      _ -> nil
    end
  end

  defp coerce(value, "safeBool"), do: Safe.bool(value)

  # String-only path (computed / collection_member drop the rule map): treat the
  # source as epoch milliseconds, matching the absent/null-format map default.
  defp coerce(value, "iso8601"), do: iso8601_from_ms(value)

  defp coerce(value, _coercion), do: value

  defp seconds_to_ms(value) do
    case Safe.integer(value) do
      seconds when is_integer(seconds) -> seconds * 1_000
      _ -> nil
    end
  end

  defp omit_zero_integer(value) do
    case Safe.integer(value) do
      0 -> nil
      integer -> integer
    end
  end

  defp omit_zero_number(value) do
    case Safe.number(value) do
      number when number in [0, 0.0] -> nil
      number -> number
    end
  end

  defp precision_to_tick_size(value) do
    case Safe.integer(value) do
      precision when is_integer(precision) -> :math.pow(10, -precision)
      _ -> nil
    end
  end

  defp parse_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:error, _reason} -> parse_naive_timestamp(value)
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
    end
  end

  defp parse_iso8601(_value), do: nil

  defp iso8601_from_ms(value) do
    case Safe.integer(value) do
      n when is_integer(n) -> Bourse.Timestamp.iso8601_from_ms(n)
      _ -> nil
    end
  end

  defp iso8601_from_seconds(value) do
    case seconds_to_ms(value) do
      n when is_integer(n) -> Bourse.Timestamp.iso8601_from_ms(n)
      _ -> nil
    end
  end

  # Epoch-ms sources that a venue may serialize either as a number/numeric string
  # or as a naive `"YYYY-MM-DD HH:MM:SS"` UTC datetime (Binance capital history
  # sends `insertTime` as epoch ms but `applyTime` as the datetime form).
  #
  # Deliberately not named `safe_timestamp`: this helper means
  # seconds -> milliseconds, which this does not do. `safeTimestamp` now has
  # resolution-aware runtime handling; see docs/safe-timestamp-audit.md.
  defp epoch_ms_or_datetime(value) when is_integer(value), do: value
  defp epoch_ms_or_datetime(value) when is_float(value), do: trunc(value)

  defp epoch_ms_or_datetime(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {timestamp, ""} -> timestamp
      _ -> parse_naive_timestamp(value)
    end
  end

  defp epoch_ms_or_datetime(_value), do: nil

  defp parse_naive_timestamp(value) when is_binary(value) do
    with {:ok, naive} <- value |> String.replace(" ", "T") |> NaiveDateTime.from_iso8601(),
         {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
      DateTime.to_unix(datetime, :millisecond)
    else
      _ -> nil
    end
  end

  defp canonical_number(value) do
    case Safe.number(value) do
      number when is_float(number) and trunc(number) == number -> trunc(number)
      number -> number
    end
  end

  defp format_value(value, "hours") when is_binary(value), do: value <> "h"
  defp format_value(value, "hours") when is_integer(value), do: Integer.to_string(value) <> "h"

  # Bybit funding cadence: `fundingIntervalHour` is whole hours ("8");
  # `fundingInterval` is minutes (480). Prefer hours when the matched value is
  # small (≤24); otherwise treat as minutes. Never invent a periods-per-day constant.
  defp format_value(value, "funding_interval") do
    cond do
      is_binary(value) and String.ends_with?(value, "h") ->
        value

      is_binary(value) ->
        case Integer.parse(value) do
          {n, _} -> format_funding_interval_number(n)
          :error -> nil
        end

      is_integer(value) ->
        format_funding_interval_number(value)

      true ->
        nil
    end
  end

  defp format_value(value, "funding_interval_milliseconds")
       when is_integer(value) and value > 0 and rem(value, @milliseconds_per_hour) == 0,
       do: Integer.to_string(div(value, @milliseconds_per_hour)) <> "h"

  defp format_value(_value, "funding_interval_milliseconds"), do: nil

  defp format_value(value, _format), do: value

  defp format_funding_interval_number(n) when is_integer(n) and n > 0 and n <= 24, do: Integer.to_string(n) <> "h"
  defp format_funding_interval_number(n) when is_integer(n) and n > 24, do: Integer.to_string(div(n, 60)) <> "h"
  defp format_funding_interval_number(_), do: nil

  defp build_result(parsed, target) when is_list(parsed), do: Enum.map(parsed, &build_struct(&1, target))
  defp build_result(parsed, target), do: build_struct(parsed, target)

  defp build_struct(string_keyed, target) do
    schema = target.schema()
    allowed = target.__struct__() |> Map.keys() |> MapSet.new()

    attrs =
      schema
      |> JSONSpec.atomize(string_keyed)
      |> preserve_dynamic_keys(string_keyed, target)
      |> Map.filter(fn {key, _value} -> is_atom(key) and MapSet.member?(allowed, key) end)

    struct(target, attrs)
  end

  defp preserve_dynamic_keys(attrs, string_keyed, Bourse.Balance) do
    Enum.reduce([:free, :used, :total, :debt], attrs, fn key, acc ->
      case Map.fetch(string_keyed, Atom.to_string(key)) do
        {:ok, value} when is_map(value) -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp preserve_dynamic_keys(attrs, _string_keyed, _target), do: attrs

  defp normalize_output_key("order", %{target: Bourse.Trade}), do: "order_id"
  defp normalize_output_key(field, %{target: Bourse.Balance}) when is_binary(field), do: field

  defp normalize_output_key(field, _context) when is_binary(field), do: Macro.underscore(field)
  defp normalize_output_key(field, _context), do: to_string(field)

  defp fetch_target(%{target: target}) when is_atom(target) do
    if Code.ensure_loaded?(target) and function_exported?(target, :schema, 0) do
      {:ok, target}
    else
      {:error, {:invalid_target, target}}
    end
  end

  defp fetch_target(_context), do: {:error, :missing_target}

  defp normalize_context(context) when is_list(context), do: context |> Map.new() |> normalize_context()

  defp normalize_context(context) when is_map(context) do
    %{
      target: context_option(context, :target) || context_option(context, :target_module),
      market: context_option(context, :market) || %{},
      symbol: context_option(context, :symbol),
      currencies: context_option(context, :currencies) || %{},
      common_currencies: context_option(context, :common_currencies) || %{},
      options: context_option(context, :options) || %{},
      route: context_option(context, :route),
      venue: context_option(context, :venue)
    }
  end

  defp normalize_context(_context),
    do: %{
      target: nil,
      market: %{},
      symbol: nil,
      currencies: %{},
      common_currencies: %{},
      options: %{},
      route: nil,
      venue: nil
    }

  defp context_option(context, key), do: Map.get(context, key) || Map.get(context, Atom.to_string(key))

  defp context_value(_context, nil), do: nil

  defp context_value(context, path) when is_binary(path) do
    path
    |> String.split(".")
    |> Enum.reduce(context, fn key, acc ->
      case acc do
        map when is_map(map) -> Map.get(map, key) || existing_atom_value(map, key)
        _ -> nil
      end
    end)
  end

  defp existing_atom_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp truthy?(value), do: value in [true, "true", 1, "1"]

  defp collect_results(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
