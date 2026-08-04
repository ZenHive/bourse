defmodule Bourse.PortfolioRisk.Exposure do
  @moduledoc """
  Pure exposure math for portfolio-risk snapshots.

  Option position quantities are converted to canonical underlying units before
  Greeks are applied. Aggregation keys include the underlying, both currencies,
  and the complete semantic unit convention, so incompatible risks cannot be
  added accidentally.
  """

  alias Bourse.Balance
  alias Bourse.InstrumentGreeks
  alias Bourse.Market
  alias Bourse.Order
  alias Bourse.Position

  @greeks [:delta, :gamma, :vega, :theta, :rho]
  @delta_convention %{
    denomination: "underlying",
    unit: "ratio",
    bump_size: 1.0,
    time_basis: nil
  }

  @type provenance :: %{
          required(:venue) => String.t(),
          required(:account) => term(),
          required(:observed_at) => integer()
        }

  @type lot :: %{
          required(:venue) => String.t(),
          required(:account) => term(),
          required(:symbol) => String.t(),
          required(:underlying) => String.t(),
          required(:settlement_currency) => String.t() | nil,
          required(:quantity) => number(),
          required(:quantity_unit) => String.t(),
          required(:source) => atom(),
          required(:pending) => boolean(),
          required(:observed_at) => integer(),
          required(:market) => Market.t() | nil,
          optional(:contract_multiplier) => number() | nil,
          optional(:source_timestamp) => integer() | nil
        }

  @doc "Builds signed asset and debt lots from a balance."
  @spec balance_lots(provenance(), Balance.t()) :: [lot()]
  def balance_lots(provenance, %Balance{} = balance) do
    asset_lots =
      balance.total
      |> Enum.reject(fn {_currency, amount} -> zero?(amount) end)
      |> Enum.map(fn {currency, amount} ->
        currency_lot(provenance, currency, amount, :balance, balance.timestamp)
      end)

    debt_lots =
      balance.debt
      |> Enum.reject(fn {_currency, amount} -> zero?(amount) end)
      |> Enum.map(fn {currency, amount} ->
        currency_lot(provenance, currency, -amount, :debt, balance.timestamp)
      end)

    asset_lots ++ debt_lots
  end

  @doc "Builds a signed current-exposure lot from one position and its market."
  @spec position_lot(provenance(), Position.t(), Market.t()) :: {:ok, lot()} | {:error, atom()}
  def position_lot(provenance, %Position{} = position, %Market{} = market) do
    with {:ok, sign} <- position_sign(position.side),
         {:ok, quantity, multiplier} <- position_quantity(position, market) do
      {:ok,
       market_lot(
         provenance,
         market,
         market.symbol,
         sign * quantity,
         :position,
         false,
         position.last_update_timestamp || position.timestamp,
         multiplier
       )}
    end
  end

  @doc "Builds signed pending-exposure lots from one open order and its market."
  @spec order_lots(provenance(), Order.t(), Market.t()) :: {:ok, [lot()]} | {:error, atom()}
  def order_lots(provenance, %Order{} = order, %Market{} = market) do
    with {:ok, sign} <- order_sign(order.side),
         {:ok, remaining} <- remaining_quantity(order) do
      order_market_lots(provenance, order, market, sign, remaining)
    end
  end

  @doc "Converts a non-option lot into a signed delta contribution."
  @spec delta_contribution(lot()) :: map()
  def delta_contribution(lot) do
    risk = %{
      value: lot.quantity,
      valuation_currency: lot.underlying,
      unit_convention: @delta_convention
    }

    contribution(lot, %{delta: risk})
  end

  @doc """
  Applies per-instrument Greeks to an option lot.

  Missing supported Greeks become blocked buckets; unsupported Greeks are
  omitted because the venue declares that no such bucket exists.
  """
  @spec option_contribution(lot(), InstrumentGreeks.t()) :: {map() | nil, [map()]}
  def option_contribution(%{market: %Market{} = market} = lot, %InstrumentGreeks{} = greeks) do
    {risks, blocked} =
      Enum.reduce(@greeks, {%{}, []}, fn greek, {risks, blocked} ->
        convention = convention(greeks.conventions, greek)
        value = Map.get(greeks, greek)

        cond do
          convention["supported"] == false ->
            {risks, blocked}

          is_number(value) ->
            risk = %{
              value: lot.quantity * value,
              valuation_currency: valuation_currency(market, convention),
              native_field: convention["native_field"],
              unit_convention: semantic_convention(convention)
            }

            {Map.put(risks, greek, risk), blocked}

          true ->
            blocker = blocker(lot, greek, convention, {:missing_greek, greek}, greeks.source_timestamp)
            {risks, [blocker | blocked]}
        end
      end)

    contribution = if map_size(risks) == 0, do: nil, else: contribution(lot, risks, greeks.source_timestamp)
    {contribution, Enum.reverse(blocked)}
  end

  @doc "Blocks every supported option-Greek bucket for a lot after a read failure."
  @spec block_option(lot(), map(), term()) :: [map()]
  def block_option(%{market: %Market{}} = lot, conventions, reason) when is_map(conventions) do
    Enum.flat_map(@greeks, fn greek ->
      convention = convention(conventions, greek)

      if convention["supported"] == true do
        [blocker(lot, greek, convention, reason, nil)]
      else
        []
      end
    end)
  end

  @doc """
  Aggregates contributions only inside exact semantic buckets.

  A bucket with any blocker exposes only `partial_value`; its coherent `value`
  is `nil`.
  """
  @spec aggregate([map()], [map()]) :: [map()]
  def aggregate(contributions, blockers) when is_list(contributions) and is_list(blockers) do
    values = Enum.reduce(contributions, %{}, &accumulate_contribution/2)

    blocked =
      Enum.reduce(blockers, %{}, fn blocker, acc ->
        Map.update(acc, bucket_key(blocker.bucket), [blocker], &[blocker | &1])
      end)

    values
    |> Map.keys()
    |> Kernel.++(Map.keys(blocked))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&aggregate_bucket(&1, values, blocked))
  end

  defp accumulate_contribution(contribution, acc) do
    Enum.reduce(contribution.greeks, acc, fn {greek, risk}, risk_acc ->
      accumulate_risk(risk_acc, contribution, greek, risk)
    end)
  end

  defp accumulate_risk(acc, contribution, greek, risk) do
    bucket = bucket(contribution, greek, risk)

    Map.update(
      acc,
      bucket_key(bucket),
      %{bucket: bucket, value: risk.value, contribution_count: 1},
      fn existing ->
        %{existing | value: existing.value + risk.value, contribution_count: existing.contribution_count + 1}
      end
    )
  end

  defp position_quantity(%Position{} = position, %Market{option: true} = market) do
    option_position_quantity(position, market)
  end

  defp position_quantity(%Position{} = position, %Market{} = market) do
    derivative_quantity(position, market)
  end

  defp option_position_quantity(%Position{contracts: contracts}, %Market{native_quantity_unit: "base"})
       when is_number(contracts) do
    {:ok, abs(contracts), 1}
  end

  defp option_position_quantity(%Position{contracts: contracts}, %Market{
         native_quantity_unit: "contracts",
         contract_size: multiplier
       })
       when is_number(contracts) and is_number(multiplier) and multiplier > 0 do
    {:ok, abs(contracts) * multiplier, multiplier}
  end

  defp option_position_quantity(%Position{}, %Market{native_quantity_unit: "contracts"}),
    do: {:error, :missing_contract_multiplier}

  defp option_position_quantity(%Position{}, %Market{}), do: {:error, :missing_option_quantity_semantics}

  defp derivative_quantity(%Position{notional: notional, mark_price: mark_price}, _market)
       when is_number(notional) and is_number(mark_price) and mark_price > 0 do
    {:ok, abs(notional) / mark_price, nil}
  end

  defp derivative_quantity(%Position{contracts: contracts}, %Market{inverse: true, contract_size: multiplier})
       when is_number(contracts) and is_number(multiplier) do
    {:error, :missing_mark_price_for_inverse_contract}
  end

  defp derivative_quantity(%Position{contracts: contracts}, %Market{contract_size: multiplier})
       when is_number(contracts) and is_number(multiplier) and multiplier > 0 do
    {:ok, abs(contracts) * multiplier, multiplier}
  end

  defp derivative_quantity(%Position{}, %Market{}), do: {:error, :missing_position_quantity}

  defp order_market_lots(_provenance, _order, _market, _sign, 0), do: {:ok, []}

  defp order_market_lots(provenance, order, %Market{option: true, quantity_unit: "base"} = market, sign, remaining) do
    {:ok,
     [
       market_lot(
         provenance,
         market,
         market.symbol,
         sign * remaining,
         :open_order,
         true,
         order.last_update_timestamp || order.timestamp,
         market.contract_size
       )
     ]}
  end

  defp order_market_lots(_provenance, _order, %Market{option: true}, _sign, _remaining),
    do: {:error, :missing_option_quantity_semantics}

  defp order_market_lots(provenance, order, %Market{spot: true} = market, sign, remaining) when is_number(order.price) do
    base =
      market_lot(
        provenance,
        market,
        market.symbol,
        sign * remaining,
        :open_order,
        true,
        order.last_update_timestamp || order.timestamp,
        nil
      )

    quote =
      currency_lot(
        provenance,
        market.quote,
        -sign * remaining * order.price,
        :open_order,
        order.last_update_timestamp || order.timestamp,
        order.symbol
      )

    {:ok, [%{base | pending: true}, %{quote | pending: true}]}
  end

  defp order_market_lots(_provenance, _order, %Market{spot: true}, _sign, _remaining), do: {:error, :missing_order_price}

  defp order_market_lots(provenance, order, %Market{} = market, sign, remaining) do
    with {:ok, quantity, multiplier} <- derivative_order_quantity(order, market, remaining) do
      {:ok,
       [
         market_lot(
           provenance,
           market,
           market.symbol,
           sign * quantity,
           :open_order,
           true,
           order.last_update_timestamp || order.timestamp,
           multiplier
         )
       ]}
    end
  end

  defp derivative_order_quantity(%Order{price: price}, %Market{inverse: true, contract_size: multiplier}, remaining)
       when is_number(price) and price > 0 and is_number(multiplier) and multiplier > 0 do
    {:ok, remaining * multiplier / price, multiplier}
  end

  defp derivative_order_quantity(_order, %Market{inverse: true}, _remaining),
    do: {:error, :missing_inverse_order_price_or_multiplier}

  defp derivative_order_quantity(_order, %Market{contract_size: multiplier}, remaining)
       when is_number(multiplier) and multiplier > 0 do
    {:ok, remaining * multiplier, multiplier}
  end

  defp derivative_order_quantity(_order, %Market{}, _remaining), do: {:error, :missing_contract_multiplier}

  defp remaining_quantity(%Order{remaining: remaining}) when is_number(remaining) and remaining >= 0, do: {:ok, remaining}

  defp remaining_quantity(%Order{amount: amount, filled: filled})
       when is_number(amount) and is_number(filled) and amount >= filled do
    {:ok, amount - filled}
  end

  defp remaining_quantity(%Order{}), do: {:error, :missing_remaining_quantity}

  defp position_sign("long"), do: {:ok, 1}
  defp position_sign("short"), do: {:ok, -1}
  defp position_sign(_), do: {:error, :missing_position_side}

  defp order_sign("buy"), do: {:ok, 1}
  defp order_sign("sell"), do: {:ok, -1}
  defp order_sign(_), do: {:error, :missing_order_side}

  defp currency_lot(provenance, currency, quantity, source, source_timestamp, symbol \\ nil) do
    %{
      venue: provenance.venue,
      account: provenance.account,
      symbol: symbol || currency,
      underlying: currency,
      settlement_currency: currency,
      quantity: quantity,
      quantity_unit: "underlying",
      source: source,
      pending: false,
      source_timestamp: source_timestamp,
      observed_at: provenance.observed_at,
      contract_multiplier: nil,
      market: nil
    }
  end

  defp market_lot(provenance, market, symbol, quantity, source, pending, source_timestamp, multiplier) do
    %{
      venue: provenance.venue,
      account: provenance.account,
      symbol: symbol || market.symbol,
      underlying: market.base,
      settlement_currency: market.settle || market.quote,
      quantity: quantity,
      quantity_unit: "underlying",
      source: source,
      pending: pending,
      source_timestamp: source_timestamp,
      observed_at: provenance.observed_at,
      contract_multiplier: multiplier,
      market: market
    }
  end

  defp contribution(lot, risks, source_timestamp \\ nil) do
    %{
      venue: lot.venue,
      account: lot.account,
      symbol: lot.symbol,
      underlying: lot.underlying,
      settlement_currency: lot.settlement_currency,
      quantity: lot.quantity,
      quantity_unit: lot.quantity_unit,
      contract_multiplier: lot.contract_multiplier,
      source: lot.source,
      pending: lot.pending,
      source_timestamp: source_timestamp || lot.source_timestamp,
      observed_at: lot.observed_at,
      greeks: risks
    }
  end

  defp blocker(lot, greek, convention, reason, source_timestamp) do
    risk = %{
      valuation_currency: valuation_currency(lot.market, convention),
      unit_convention: semantic_convention(convention)
    }

    %{
      bucket: bucket(lot, greek, risk),
      venue: lot.venue,
      account: lot.account,
      symbol: lot.symbol,
      source: lot.source,
      reason: reason,
      source_timestamp: source_timestamp || lot.source_timestamp,
      observed_at: lot.observed_at
    }
  end

  defp bucket(source, greek, risk) do
    %{
      greek: greek,
      underlying: source.underlying,
      valuation_currency: risk.valuation_currency,
      settlement_currency: source.settlement_currency,
      quantity_unit: source.quantity_unit,
      unit_convention: risk.unit_convention
    }
  end

  defp bucket_key(bucket) do
    convention = bucket.unit_convention

    {
      bucket.greek,
      bucket.underlying,
      bucket.valuation_currency,
      bucket.settlement_currency,
      bucket.quantity_unit,
      convention.denomination,
      convention.unit,
      convention.bump_size,
      convention.time_basis
    }
  end

  defp aggregate_bucket(key, values, blocked) do
    value_entry = Map.get(values, key)
    blockers = blocked |> Map.get(key, []) |> Enum.reverse()
    bucket = if value_entry, do: value_entry.bucket, else: hd(blockers).bucket

    if blockers == [] do
      %{
        bucket: bucket,
        status: :complete,
        value: value_entry.value,
        partial_value: nil,
        contribution_count: value_entry.contribution_count,
        blocked_count: 0
      }
    else
      %{
        bucket: bucket,
        status: :blocked,
        value: nil,
        partial_value: value_entry && value_entry.value,
        contribution_count: (value_entry && value_entry.contribution_count) || 0,
        blocked_count: length(blockers)
      }
    end
  end

  defp convention(conventions, greek) when is_map(conventions) do
    Map.get(conventions, Atom.to_string(greek), %{"supported" => false})
  end

  defp semantic_convention(convention) do
    %{
      denomination: convention["denomination"],
      unit: convention["unit"],
      bump_size: convention["bump_size"],
      time_basis: convention["time_basis"]
    }
  end

  defp valuation_currency(%Market{} = market, %{"denomination" => denomination})
       when denomination in ["underlying", "delta"] do
    market.base
  end

  defp valuation_currency(%Market{} = market, _convention), do: market.settle || market.quote

  defp zero?(amount), do: is_number(amount) and amount == 0
end
