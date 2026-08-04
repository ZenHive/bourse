defmodule Bourse.Order.Sanity do
  @moduledoc """
  Pre-submit order validation against market metadata.

  Checks order shape, exchange order-type support, market limits, tick-size
  precision, and optional price deviation before an order is submitted.

  Unified `Bourse.create_order` and `Bourse.edit_order` calls opt in with
  `sanity: true`. The default is `false` so existing callers retain the
  exchange's validation contract; validation is skipped when markets have not
  been loaded with `Bourse.load_markets/1`.

  ## Options

  - `:has` — the exchange capability map, used to reject unsupported order types.
  - `:partial` — when `true`, an absent `amount` or `price` is treated as a field
    that is not being changed rather than a missing required field. The unified
    path sets this for `edit_order`, which carries only the changed fields.
  - `:reference_price` / `:deviation_threshold` — opt into the price-deviation warning.
  - `:warnings` — `:strict` promotes warnings to errors.
  """

  alias Bourse.Order.Builder

  @default_deviation_threshold 0.10
  @epsilon_multiplier 1.0e-6
  @percent 100
  @decimal_base 10

  @type reason :: {atom(), String.t()}
  @type result :: {:ok, map()} | {:ok, map(), [reason()]} | {:error, {:sanity_check, [reason()]}}

  @type_to_has %{
    "limit" => "createLimitOrder",
    "market" => "createMarketOrder",
    "stop" => "createStopOrder",
    "stop_limit" => "createStopLimitOrder",
    "stop_market" => "createStopMarketOrder",
    "stop_loss" => "createStopLossOrder",
    "trigger" => "createTriggerOrder"
  }

  @valid_sides ~w(buy sell)

  @doc "Runs all applicable sanity checks and collects every hard failure."
  @spec validate(map() | Builder.t(), map() | nil, keyword()) :: result()
  def validate(order_params, market, opts \\ []) do
    params = normalize_order_params(order_params)
    {errors, warnings} = run_checks(params, market, opts)
    format_result(params, errors, warnings, opts)
  end

  @doc "Validates order side."
  @spec check_side(any()) :: :ok | {:error, String.t()}
  def check_side(side) when side in @valid_sides, do: :ok
  def check_side(side), do: {:error, "Invalid side: #{inspect(side)}. Must be \"buy\" or \"sell\""}

  @doc "Validates order type and optional exchange capability support."
  @spec check_order_type(any(), keyword()) :: :ok | {:error, String.t()}
  def check_order_type(type, opts \\ [])

  def check_order_type(type, opts) when is_binary(type) do
    case Map.fetch(@type_to_has, type) do
      {:ok, has_key} -> check_has_capability(type, has_key, opts[:has])
      :error -> {:error, "Unknown order type: #{inspect(type)}. Known types: #{known_types()}"}
    end
  end

  def check_order_type(type, _opts), do: {:error, "Order type must be a string, got: #{inspect(type)}"}

  @doc "Validates order symbol against market metadata."
  @spec check_symbol(any(), map()) :: :ok | {:error, String.t()}
  def check_symbol(order_symbol, market) when is_binary(order_symbol) and is_map(market) do
    market_symbol = get_field(market, "symbol", :symbol)

    cond do
      market_symbol != order_symbol ->
        {:error, "Symbol mismatch: order has #{inspect(order_symbol)} but market is #{inspect(market_symbol)}"}

      get_field(market, "active", :active) == false ->
        {:error, "Market #{inspect(order_symbol)} is inactive"}

      true ->
        :ok
    end
  end

  def check_symbol(order_symbol, _market), do: {:error, "Invalid symbol: #{inspect(order_symbol)}"}

  @doc "Validates order amount against market limits and precision."
  @spec check_amount(any(), map() | nil, keyword()) :: :ok | {:error, String.t()}
  def check_amount(amount, market, opts \\ [])

  def check_amount(amount, _market, _opts) when not is_number(amount) or amount <= 0 do
    {:error, "Amount must be a positive number, got: #{inspect(amount)}"}
  end

  def check_amount(_amount, nil, _opts), do: :ok

  def check_amount(amount, market, opts) when is_map(market) do
    with :ok <- check_limit(amount, "amount", "min", market, :>=),
         :ok <- check_limit(amount, "amount", "max", market, :<=) do
      check_precision(amount, "amount", market, opts)
    end
  end

  @doc "Validates order price against order type, market limits, and precision."
  @spec check_price(any(), String.t() | nil, map() | nil, keyword()) :: :ok | {:error, String.t()}
  def check_price(price, order_type, market, opts \\ [])

  def check_price(nil, "limit", _market, _opts), do: {:error, "Limit orders require a price"}
  def check_price(nil, _order_type, _market, _opts), do: :ok

  def check_price(price, _order_type, _market, _opts) when not is_number(price) or price <= 0 do
    {:error, "Price must be a positive number, got: #{inspect(price)}"}
  end

  def check_price(_price, _order_type, nil, _opts), do: :ok

  def check_price(price, _order_type, market, opts) when is_map(market) do
    with :ok <- check_limit(price, "price", "min", market, :>=),
         :ok <- check_limit(price, "price", "max", market, :<=) do
      check_precision(price, "price", market, opts)
    end
  end

  @doc "Validates order notional against market cost limits."
  @spec check_cost(any(), any(), map() | nil) :: :ok | {:error, String.t()}
  def check_cost(_amount, _price, nil), do: :ok
  def check_cost(amount, price, _market) when not is_number(amount) or not is_number(price), do: :ok

  def check_cost(amount, price, market) when is_map(market) do
    notional = calculate_notional(amount, price, market)

    with :ok <- check_cost_limit(notional, "min", market, :>=) do
      check_cost_limit(notional, "max", market, :<=)
    end
  end

  @doc "Warns when price deviates beyond the configured reference-price threshold."
  @spec check_price_deviation(any(), any(), keyword()) :: :ok | {:warning, String.t()}
  def check_price_deviation(price, reference_price, opts \\ [])

  def check_price_deviation(price, reference_price, opts)
      when is_number(price) and is_number(reference_price) and reference_price > 0 do
    threshold = opts[:deviation_threshold] || @default_deviation_threshold
    deviation = abs(price - reference_price) / reference_price

    if deviation > threshold do
      pct = Float.round(deviation * @percent, 2)
      threshold_pct = Float.round(threshold * @percent, 2)

      {:warning, "Price #{price} deviates #{pct}% from reference #{reference_price} (threshold: #{threshold_pct}%)"}
    else
      :ok
    end
  end

  def check_price_deviation(_price, _reference_price, _opts), do: :ok

  defp run_checks(params, market, opts) do
    checks = [
      {:check_side, fn -> check_side(params.side) end},
      {:check_order_type, fn -> check_order_type(params.type, opts) end},
      {:check_symbol, fn -> run_symbol_check(params.symbol, market) end},
      {:check_amount, fn -> skip_if_absent(params.amount, opts, fn -> check_amount(params.amount, market, opts) end) end},
      {:check_price,
       fn -> skip_if_absent(params.price, opts, fn -> check_price(params.price, params.type, market, opts) end) end},
      {:check_cost, fn -> check_cost(params.amount, params.price, market) end},
      {:check_price_deviation, fn -> run_deviation_check(params.price, opts) end}
    ]

    checks
    |> Enum.reduce({[], []}, fn {name, check}, {errors, warnings} ->
      case check.() do
        :ok -> {errors, warnings}
        :skip -> {errors, warnings}
        {:error, message} -> {[{name, message} | errors], warnings}
        {:warning, message} -> {errors, [{name, message} | warnings]}
      end
    end)
    |> then(fn {errors, warnings} -> {Enum.reverse(errors), Enum.reverse(warnings)} end)
  end

  defp format_result(params, errors, warnings, opts) do
    {errors, warnings} =
      if opts[:warnings] == :strict do
        {errors ++ warnings, []}
      else
        {errors, warnings}
      end

    cond do
      errors != [] -> {:error, {:sanity_check, errors}}
      warnings != [] -> {:ok, params, warnings}
      true -> {:ok, params}
    end
  end

  defp normalize_order_params(%Builder{} = builder) do
    %{
      symbol: builder.symbol,
      type: to_string_safe(builder.type),
      side: to_string_safe(builder.side),
      amount: builder.amount,
      price: Keyword.get(builder.params, :price)
    }
  end

  defp normalize_order_params(params) when is_map(params) do
    %{
      symbol: get_field(params, "symbol", :symbol),
      type: params |> get_field("type", :type) |> to_string_safe(),
      side: params |> get_field("side", :side) |> to_string_safe(),
      amount: get_field(params, "amount", :amount),
      price: get_field(params, "price", :price)
    }
  end

  defp to_string_safe(nil), do: nil
  defp to_string_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_safe(value) when is_binary(value), do: value

  # Under `partial: true` (edit_order) an absent field means "not being changed",
  # so it is skipped rather than reported as a missing required field.
  defp skip_if_absent(nil, opts, check) do
    if opts[:partial], do: :skip, else: check.()
  end

  defp skip_if_absent(_value, _opts, check), do: check.()

  defp run_symbol_check(_symbol, nil), do: :skip
  defp run_symbol_check(symbol, market), do: check_symbol(symbol, market)

  defp run_deviation_check(price, opts) do
    case opts[:reference_price] do
      nil -> :skip
      reference_price -> check_price_deviation(price, reference_price, opts)
    end
  end

  defp check_has_capability(_type, _has_key, nil), do: :ok

  defp check_has_capability(type, has_key, has) when is_map(has) do
    case map_get_dual(has, has_key, safe_to_atom(has_key)) do
      false -> {:error, "Exchange does not support #{inspect(type)} orders (has.#{has_key} == false)"}
      _ -> :ok
    end
  end

  defp check_has_capability(_type, _has_key, _has), do: :ok

  defp known_types, do: Enum.map_join(@type_to_has, ", ", fn {type, _has} -> type end)

  defp get_field(%{__struct__: _} = struct, _string_key, atom_key), do: Map.get(struct, atom_key)

  defp get_field(map, string_key, atom_key) when is_map(map) do
    map_get_dual(map, string_key, atom_key)
  end

  defp map_get_dual(map, primary_key, fallback_key) do
    case Map.fetch(map, primary_key) do
      {:ok, value} -> value
      :error -> Map.get(map, fallback_key)
    end
  end

  defp safe_to_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp check_limit(value, category, bound, market, op) do
    market
    |> get_nested_limit(category, bound)
    |> compare_limit(value, category, op)
  end

  defp check_cost_limit(value, bound, market, op) do
    market
    |> get_nested_limit("cost", bound)
    |> compare_limit(value, "cost", op)
  end

  defp compare_limit(nil, _value, _category, _op), do: :ok

  defp compare_limit(limit, value, category, :>=) when is_number(limit) do
    if value >= limit, do: :ok, else: {:error, "#{category} #{value} is below minimum #{limit}"}
  end

  defp compare_limit(limit, value, category, :<=) when is_number(limit) do
    if value <= limit, do: :ok, else: {:error, "#{category} #{value} exceeds maximum #{limit}"}
  end

  defp compare_limit(_limit, _value, _category, _op), do: :ok

  defp get_nested_limit(market, category, bound) do
    with %{} = limits <- get_field(market, "limits", :limits),
         %{} = category_limits <- map_get_dual(limits, category, safe_to_atom(category)) do
      map_get_dual(category_limits, bound, safe_to_atom(bound))
    else
      _ -> nil
    end
  end

  defp check_precision(value, field, market, opts) do
    market
    |> get_field("precision", :precision)
    |> precision_increment(field, opts[:precision_mode])
    |> validate_increment(value, field)
  end

  defp precision_increment(nil, _field, _mode), do: nil

  defp precision_increment(precision, field, mode) when is_map(precision) do
    precision
    |> map_get_dual(field, safe_to_atom(field))
    |> normalize_increment(mode)
  end

  defp normalize_increment(value, mode) when is_integer(value) and mode in [:decimal_places, "decimal_places"] do
    :math.pow(@decimal_base, -value)
  end

  defp normalize_increment(value, _mode) when is_number(value), do: value
  defp normalize_increment(_value, _mode), do: nil

  defp validate_increment(nil, _value, _field), do: :ok

  defp validate_increment(increment, value, field) when is_number(increment) and increment > 0 do
    remainder = :math.fmod(value, increment)
    epsilon = increment * @epsilon_multiplier

    if remainder < epsilon or increment - remainder < epsilon do
      :ok
    else
      {:error, "#{field} #{value} does not respect increment #{increment}"}
    end
  end

  defp validate_increment(_increment, _value, _field), do: :ok

  defp calculate_notional(amount, price, market) do
    contract? = get_field(market, "contract", :contract)
    contract_size = get_field(market, "contractSize", :contract_size) || 1
    inverse? = get_field(market, "inverse", :inverse)

    cond do
      contract? && inverse? -> amount * contract_size / price
      contract? -> amount * contract_size * price
      true -> amount * price
    end
  end
end
