defmodule Bourse.OptionProposal.Projection do
  @moduledoc """
  Pure post-trade exposure projection for caller-supplied option legs.

  Quantities use the unified canonical base unit and are checked for exact
  representability in the venue's confronted native unit before Greeks are
  applied. This module never chooses trades or places orders.
  """

  alias Bourse.InstrumentGreeks
  alias Bourse.Market
  alias Bourse.Unified.OptionQuantity

  @greeks [:delta, :gamma, :vega, :theta]
  @convention_keys ~w(denomination unit bump_size time_basis)
  @delta_convention %{
    denomination: "underlying",
    unit: "ratio",
    bump_size: 1.0,
    time_basis: nil
  }

  @type leg :: %{
          required(:id) => term(),
          required(:venue) => String.t(),
          required(:account) => term(),
          required(:symbol) => String.t(),
          required(:side) => String.t(),
          required(:amount) => number(),
          required(:market) => Market.t(),
          required(:greeks) => InstrumentGreeks.t(),
          optional(:price) => number() | nil,
          optional(:type) => String.t()
        }

  @doc "Projects signed Greek, notional and per-domain margin effects for option legs."
  @spec project_legs([leg()], [map()]) :: {:ok, map()} | {:error, atom() | {atom(), term()}}
  def project_legs(legs, baseline_contributions \\ []) when is_list(legs) and is_list(baseline_contributions) do
    with {:ok, underlying} <- one_underlying(legs),
         {:ok, leg_effects} <- Enum.reduce_while(legs, {:ok, []}, &reduce_leg/2),
         :ok <- compatible_conventions(leg_effects),
         {:ok, baseline} <- baseline_greeks(baseline_contributions, underlying, leg_effects) do
      leg_effects = Enum.reverse(leg_effects)
      legs_total = sum_effects(leg_effects)
      post_trade = merge_greeks(baseline, legs_total)

      {:ok,
       %{
         baseline: baseline,
         legs: leg_effects,
         legs_total: legs_total,
         post_trade_before_hedge: post_trade,
         notional: Enum.reduce(leg_effects, 0.0, &(&1.notional + &2)),
         premium: Enum.reduce(leg_effects, 0.0, &((&1.premium || 0.0) + &2)),
         margin_domains: margin_domains(leg_effects)
       }}
    end
  end

  @doc "Applies a signed hedge delta contribution to a projected post-trade map."
  @spec apply_hedge_delta(map(), number()) :: map()
  def apply_hedge_delta(post_trade, hedge_delta) when is_map(post_trade) and is_number(hedge_delta) do
    current = Map.get(post_trade, :delta, 0.0)
    Map.put(post_trade, :delta, current + hedge_delta)
  end

  defp reduce_leg(leg, {:ok, acc}) do
    case project_leg(leg) do
      {:ok, effect} -> {:cont, {:ok, [effect | acc]}}
      {:error, _} = err -> {:halt, err}
    end
  end

  defp project_leg(leg) do
    with :ok <- validate_leg(leg),
         {:ok, sign} <- side_sign(leg.side),
         {:ok, quantity, multiplier} <- option_quantity(leg.market, leg.amount),
         {:ok, greeks} <- leg_greeks(leg.greeks),
         {:ok, notional} <- signed_notional(sign * quantity, leg) do
      signed_qty = sign * quantity
      greek_values = Map.new(@greeks, fn name -> {name, signed_qty * Map.fetch!(greeks, name)} end)

      {:ok,
       %{
         id: leg.id,
         venue: leg.venue,
         account: leg.account,
         symbol: leg.symbol,
         side: leg.side,
         amount: leg.amount,
         signed_quantity: signed_qty,
         quantity_unit: "underlying",
         contract_multiplier: multiplier,
         notional: notional,
         premium: signed_premium(signed_qty, Map.get(leg, :price)),
         settlement_currency: leg.market.settle || leg.market.quote,
         underlying: leg.market.base,
         greeks: greek_values,
         unit_conventions: greeks.conventions
       }}
    end
  end

  defp validate_leg(%{
         id: _,
         venue: venue,
         account: account,
         symbol: symbol,
         market: %Market{} = market,
         greeks: %InstrumentGreeks{}
       })
       when is_binary(venue) and not is_nil(account) and is_binary(symbol) do
    if market.option == true or market.type == "option",
      do: :ok,
      else: {:error, {:leg_not_option, symbol}}
  end

  defp validate_leg(_leg), do: {:error, :invalid_leg}

  defp side_sign("buy"), do: {:ok, 1}
  defp side_sign("sell"), do: {:ok, -1}
  defp side_sign(_), do: {:error, :invalid_side}

  defp option_quantity(%Market{quantity_unit: "base"} = market, amount) when is_number(amount) and amount > 0 do
    case OptionQuantity.to_native(market, amount) do
      {:ok, _native_amount} ->
        {:ok, amount, market.contract_size}

      {:error, %{raw: %{"reason" => "missing_contract_size"}}} ->
        {:error, :missing_contract_multiplier}

      {:error, error} ->
        {:error, {:quantity_not_representable, error}}
    end
  end

  defp option_quantity(%Market{}, amount) when not is_number(amount) or amount <= 0, do: {:error, :invalid_amount}
  defp option_quantity(%Market{}, _amount), do: {:error, :missing_option_quantity_semantics}

  defp leg_greeks(%InstrumentGreeks{} = greeks) do
    with {:ok, values} <- greek_values(greeks),
         {:ok, conventions} <- greek_conventions(greeks.conventions) do
      {:ok,
       %{
         delta: values.delta,
         gamma: values.gamma,
         vega: values.vega,
         theta: values.theta,
         conventions: conventions
       }}
    end
  end

  defp greek_values(greeks) do
    Enum.reduce_while(@greeks, {:ok, %{}}, fn name, {:ok, acc} ->
      case Map.get(greeks, name) do
        value when is_number(value) -> {:cont, {:ok, Map.put(acc, name, value)}}
        nil -> {:halt, {:error, {:missing_greek, name}}}
        _other -> {:halt, {:error, {:invalid_greek, name}}}
      end
    end)
  end

  defp greek_conventions(conventions) when is_map(conventions) do
    Enum.reduce_while(@greeks, {:ok, %{}}, fn greek, {:ok, acc} ->
      entry = Map.get(conventions, Atom.to_string(greek))

      if valid_convention?(entry) do
        {:cont, {:ok, Map.put(acc, greek, Map.take(entry, @convention_keys))}}
      else
        {:halt, {:error, {:invalid_greek_convention, greek}}}
      end
    end)
  end

  defp greek_conventions(_conventions), do: {:error, {:invalid_greek_convention, :delta}}

  defp valid_convention?(%{
         "supported" => true,
         "denomination" => denomination,
         "unit" => unit,
         "bump_size" => bump_size,
         "time_basis" => time_basis
       }) do
    valid_text?(denomination) and
      valid_text?(unit) and
      is_number(bump_size) and
      (is_binary(time_basis) or is_nil(time_basis))
  end

  defp valid_convention?(_entry), do: false
  defp valid_text?(value), do: is_binary(value) and value != ""

  defp signed_notional(signed_qty, %{greeks: %InstrumentGreeks{} = greeks, market: %Market{} = market}) do
    case greeks.underlying_price || market_underlying_price(market) do
      price when is_number(price) and price > 0 -> {:ok, signed_qty * price}
      _ -> {:error, :missing_underlying_price}
    end
  end

  defp signed_premium(signed_qty, price) when is_number(price) and price > 0, do: signed_qty * price
  defp signed_premium(_signed_qty, _price), do: nil

  defp market_underlying_price(%Market{info: info}) when is_map(info) do
    Enum.find_value(["underlying_price", "underlyingPrice", "index_price"], fn key ->
      case Map.get(info, key) do
        value when is_number(value) and value > 0 -> value
        _ -> nil
      end
    end)
  end

  defp market_underlying_price(_market), do: nil

  defp one_underlying(legs) do
    underlyings =
      legs
      |> Enum.map(&get_in(&1, [:market, Access.key(:base)]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    case underlyings do
      [underlying] -> {:ok, underlying}
      [] -> {:error, :missing_underlying}
      many -> {:error, {:mixed_underlyings, many}}
    end
  end

  defp compatible_conventions([]), do: :ok

  defp compatible_conventions([first | rest]) do
    Enum.reduce_while(rest, :ok, fn effect, :ok ->
      case Enum.find(@greeks, &(effect.unit_conventions[&1] != first.unit_conventions[&1])) do
        nil -> {:cont, :ok}
        greek -> {:halt, {:error, {:incompatible_greek_convention, greek}}}
      end
    end)
  end

  defp baseline_greeks(contributions, underlying, effects) do
    conventions =
      case effects do
        [effect | _rest] -> effect.unit_conventions
        [] -> %{}
      end

    contributions
    |> Enum.filter(&(Map.get(&1, :underlying) == underlying))
    |> Enum.reduce_while({:ok, empty_greeks()}, fn contribution, {:ok, acc} ->
      case accumulate_contribution_greeks(contribution, acc, conventions) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp accumulate_contribution_greeks(contribution, acc, conventions) do
    Enum.reduce_while(@greeks, {:ok, acc}, fn greek, {:ok, greek_acc} ->
      accumulate_contribution_greek(contribution, greek, greek_acc, conventions)
    end)
  end

  defp accumulate_contribution_greek(contribution, greek, acc, conventions) do
    case get_in(contribution, [:greeks, greek]) do
      nil ->
        {:cont, {:ok, acc}}

      %{value: value, unit_convention: convention} when is_number(value) ->
        accumulate_baseline_value(greek, value, convention, {acc, conventions})

      _other ->
        {:halt, {:error, {:invalid_baseline_contribution, greek}}}
    end
  end

  defp accumulate_baseline_value(greek, value, convention, {acc, conventions}) do
    if normalize_convention(convention) == conventions[greek] do
      {:cont, {:ok, Map.update!(acc, greek, &(&1 + value))}}
    else
      {:halt, {:error, {:incompatible_baseline_convention, greek}}}
    end
  end

  defp normalize_convention(convention) when is_map(convention) do
    Map.new(@convention_keys, fn key ->
      atom = String.to_existing_atom(key)
      {key, Map.get(convention, atom, Map.get(convention, key))}
    end)
  end

  defp sum_effects(effects) do
    Enum.reduce(effects, empty_greeks(), fn effect, acc ->
      Enum.reduce(@greeks, acc, fn greek, greek_acc ->
        Map.update!(greek_acc, greek, &(&1 + Map.fetch!(effect.greeks, greek)))
      end)
    end)
  end

  defp merge_greeks(left, right) do
    Map.new(@greeks, fn greek -> {greek, Map.fetch!(left, greek) + Map.fetch!(right, greek)} end)
  end

  defp empty_greeks, do: %{delta: 0.0, gamma: 0.0, vega: 0.0, theta: 0.0}

  defp margin_domains(effects) do
    effects
    |> Enum.group_by(&{&1.venue, &1.account})
    |> Enum.map(fn {{venue, account}, rows} ->
      %{
        venue: venue,
        account: account,
        settlement_currencies: rows |> Enum.map(& &1.settlement_currency) |> Enum.uniq() |> Enum.reject(&is_nil/1),
        leg_ids: Enum.map(rows, & &1.id),
        delta: Enum.reduce(rows, 0.0, &(&1.greeks.delta + &2)),
        gamma: Enum.reduce(rows, 0.0, &(&1.greeks.gamma + &2)),
        vega: Enum.reduce(rows, 0.0, &(&1.greeks.vega + &2)),
        theta: Enum.reduce(rows, 0.0, &(&1.greeks.theta + &2)),
        notional: Enum.reduce(rows, 0.0, &(&1.notional + &2)),
        premium: Enum.reduce(rows, 0.0, &((&1.premium || 0.0) + &2)),
        portfolio_margin_netting: false
      }
    end)
    |> Enum.sort_by(&{&1.venue, to_string(&1.account)})
  end

  @doc false
  @spec delta_convention() :: map()
  def delta_convention, do: @delta_convention
end
