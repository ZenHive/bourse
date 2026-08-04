defmodule Bourse.OptionProposal.Hedge do
  @moduledoc """
  Pure spot/perp hedge quantity calculation for a caller-chosen target delta.

  Rounds to venue amount precision and reports the residual delta after
  rounding. Candidate selection follows only the caller's venue policy and
  candidate list — this module never invents instruments or strategy.
  """

  alias Bourse.Market

  @decimal_base 10
  @type venue_policy :: :same_only | :prefer_same_venue | :cross_allowed

  @type candidate :: %{
          required(:id) => term(),
          required(:venue) => String.t(),
          required(:account) => term(),
          required(:symbol) => String.t(),
          required(:market) => Market.t(),
          optional(:kind) => term(),
          optional(:price) => number(),
          optional(:quote) => number() | map()
        }

  @doc "Returns the venue quantity step and delta carried by one signed candidate unit."
  @spec candidate_terms(map()) ::
          {:ok,
           %{
             market: Market.t(),
             kind: term(),
             amount_step: float(),
             delta_per_unit: float()
           }}
          | {:error, atom()}
  def candidate_terms(candidate) when is_map(candidate) do
    with {:ok, market} <- require_market(candidate),
         :ok <- market_active(market),
         {:ok, delta_per_unit} <- delta_per_unit(candidate, market),
         {:ok, step} <- amount_step(market) do
      {:ok,
       %{
         market: market,
         kind: candidate_kind(candidate, market),
         amount_step: step,
         delta_per_unit: delta_per_unit
       }}
    end
  end

  @doc """
  Selects a hedge candidate under `venue_policy` and sizes it to `target_delta`.

  `current_delta` is post-option, pre-hedge exposure in underlying units.
  A zero needed hedge returns quantity `0` with residual `current - target`.
  Inverse candidates use a positive caller `:price`, then a price-bearing
  caller `:quote`, before falling back to price fields in `market.info`.
  """
  @spec calculate(number(), number(), [candidate()], venue_policy(), [String.t()]) ::
          {:ok, map()} | {:error, atom() | {atom(), term()}}
  def calculate(current_delta, target_delta, candidates, venue_policy, option_venues)
      when is_number(current_delta) and is_number(target_delta) and is_list(candidates) and is_list(option_venues) do
    needed = target_delta - current_delta

    with {:ok, ordered} <- order_candidates(candidates, venue_policy, option_venues),
         {:ok, candidate} <- pick_candidate(ordered) do
      size_candidate(candidate, current_delta, target_delta, needed, venue_policy, option_venues)
    end
  end

  defp order_candidates(candidates, policy, option_venues) do
    with :ok <- validate_candidates(candidates) do
      venues = MapSet.new(option_venues)
      {same, cross} = Enum.split_with(candidates, &MapSet.member?(venues, &1.venue))

      case policy do
        :same_only when same == [] -> {:error, :no_same_venue_hedge_candidate}
        :same_only -> {:ok, same}
        :prefer_same_venue -> {:ok, same ++ cross}
        :cross_allowed -> {:ok, candidates}
        other -> {:error, {:invalid_venue_policy, other}}
      end
    end
  end

  defp validate_candidates(candidates) do
    case Enum.find(candidates, &(not valid_candidate?(&1))) do
      nil -> :ok
      candidate -> {:error, {:invalid_hedge_candidate, candidate}}
    end
  end

  defp valid_candidate?(%{id: _, venue: venue, account: account, symbol: symbol})
       when is_binary(venue) and not is_nil(account) and is_binary(symbol), do: true

  defp valid_candidate?(_candidate), do: false

  defp pick_candidate([]), do: {:error, :no_hedge_candidate}
  defp pick_candidate([candidate | _rest]), do: {:ok, candidate}

  defp size_candidate(candidate, current_delta, target_delta, needed, venue_policy, option_venues) do
    with {:ok, %{delta_per_unit: delta_per_unit} = terms} <- candidate_terms(candidate),
         {:ok, raw_qty} <- raw_quantity(needed, delta_per_unit) do
      %{market: market, kind: kind, amount_step: step, delta_per_unit: delta_per_unit} = terms
      {rounded, residual} = round_to_target(raw_qty, current_delta, target_delta, delta_per_unit, step)
      side = if rounded >= 0, do: "buy", else: "sell"
      abs_qty = abs(rounded)
      hedge_delta = rounded * delta_per_unit

      {:ok,
       %{
         candidate_id: candidate.id,
         venue: candidate.venue,
         account: candidate.account,
         symbol: candidate.symbol,
         market: market,
         kind: kind,
         side: side,
         quantity: abs_qty,
         signed_quantity: rounded,
         raw_quantity: raw_qty,
         amount_step: step,
         delta_per_unit: delta_per_unit,
         hedge_delta: hedge_delta,
         current_delta: current_delta,
         target_delta: target_delta,
         residual_delta: residual,
         venue_policy: venue_policy,
         cross_venue?: candidate.venue not in option_venues,
         feasible?: true,
         reason: nil
       }}
    end
  end

  defp require_market(%{market: %Market{} = market}), do: {:ok, market}
  defp require_market(_), do: {:error, :missing_hedge_market}

  defp market_active(%Market{active: false}), do: {:error, :inactive_market}
  defp market_active(%Market{}), do: :ok

  defp candidate_kind(%{kind: kind}, _market) when not is_nil(kind), do: kind
  defp candidate_kind(_candidate, %Market{spot: true}), do: :spot
  defp candidate_kind(_candidate, %Market{swap: true}), do: :perp
  defp candidate_kind(_candidate, %Market{type: "swap"}), do: :perp
  defp candidate_kind(_candidate, %Market{type: "spot"}), do: :spot
  defp candidate_kind(_candidate, _market), do: :perp

  defp delta_per_unit(_candidate, %Market{spot: true}), do: {:ok, 1.0}

  defp delta_per_unit(_candidate, %Market{option: true}), do: {:error, :hedge_candidate_is_option}

  defp delta_per_unit(candidate, %Market{inverse: true} = market) do
    case inverse_price(candidate, market) do
      {:ok, price} ->
        size = market.contract_size

        if is_number(size) and size > 0 do
          # One inverse contract ≈ contract_size / price units of base.
          {:ok, size / price}
        else
          {:error, :missing_contract_multiplier}
        end

      error ->
        error
    end
  end

  defp delta_per_unit(_candidate, %Market{contract_size: size}) when is_number(size) and size > 0 do
    {:ok, size * 1.0}
  end

  defp delta_per_unit(_candidate, %Market{contract: true}), do: {:error, :missing_contract_multiplier}

  defp delta_per_unit(_candidate, %Market{}), do: {:ok, 1.0}

  defp inverse_price(candidate, %Market{} = market) do
    candidate_price(candidate) || market_price(market)
  end

  defp candidate_price(candidate) do
    positive_price(Map.get(candidate, :price)) ||
      quote_price(Map.get(candidate, :quote))
  end

  defp quote_price(quote) when is_map(quote) do
    Enum.find_value(
      [:mark_price, :markPrice, :index_price, :indexPrice, :last, :price],
      &positive_price(Map.get(quote, &1))
    ) ||
      Enum.find_value(
        ["mark_price", "markPrice", "index_price", "indexPrice", "last", "price"],
        &positive_price(Map.get(quote, &1))
      )
  end

  defp quote_price(quote), do: positive_price(quote)

  defp market_price(%Market{info: info}) when is_map(info) do
    Enum.find_value(
      ["mark_price", "markPrice", "index_price", "indexPrice", "last", "price"],
      &positive_price(Map.get(info, &1))
    ) || {:error, :inverse_hedge_requires_price}
  end

  defp market_price(_market), do: {:error, :inverse_hedge_requires_price}

  defp positive_price(value) when is_number(value) and value > 0, do: {:ok, value}
  defp positive_price(_value), do: nil

  defp amount_step(%Market{precision: precision, precision_mode: mode}) when is_map(precision) do
    step = Map.get(precision, "amount", Map.get(precision, :amount))
    precision_step(step, mode)
  end

  defp amount_step(%Market{}), do: {:error, :missing_amount_precision}

  defp precision_step(step, mode) when is_integer(step) and mode in ["decimal_places", :decimal_places] and step >= 0,
    do: {:ok, :math.pow(@decimal_base, -step)}

  defp precision_step(step, _mode) when is_number(step) and step > 0, do: {:ok, step * 1.0}
  defp precision_step(_step, _mode), do: {:error, :missing_amount_precision}

  defp raw_quantity(needed, delta_per_unit) when delta_per_unit != 0 do
    {:ok, needed / delta_per_unit}
  end

  defp raw_quantity(_needed, _delta_per_unit), do: {:error, :zero_delta_per_unit}

  defp round_to_target(raw_qty, current_delta, target_delta, delta_per_unit, step) do
    raw_decimal = decimal!(raw_qty)
    step_decimal = decimal!(step)

    if Decimal.lt?(Decimal.abs(raw_decimal), Decimal.div(step_decimal, 2)) do
      {0.0, current_delta - target_delta}
    else
      steps = Decimal.div(raw_decimal, step_decimal)
      floor_steps = Decimal.round(steps, 0, :floor)
      ceil_steps = Decimal.round(steps, 0, :ceiling)

      candidates =
        [floor_steps, ceil_steps]
        |> Enum.uniq()
        |> Enum.map(fn n ->
          qty = n |> Decimal.mult(step_decimal) |> Decimal.to_float()
          residual = current_delta + qty * delta_per_unit - target_delta
          {qty, residual, abs(residual)}
        end)

      {qty, residual, _abs} =
        Enum.min_by(candidates, fn {qty, residual, abs_res} ->
          {abs_res, abs(qty), abs(residual)}
        end)

      {qty, residual}
    end
  end

  defp decimal!(value) do
    {:ok, decimal} = Decimal.cast(value)
    decimal
  end
end
