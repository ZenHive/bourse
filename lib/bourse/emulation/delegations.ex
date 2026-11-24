defmodule Bourse.Emulation.Delegations do
  @moduledoc """
  The declared delegation graph of `Bourse.Emulation`.

  Each key is a unified method with a runtime emulation handler; its value
  lists every unified method that handler may call. `Bourse.Emulation`
  refuses, by raising, any nested call that is not declared here, so the table
  is never smaller than the code it describes. A source scan cannot stand in
  for it: delegations hide inside shared helpers (`ensure_contract_market`,
  `collect_funding_rates_from_singular`) that a per-handler read misses.

  `Bourse.Spec.Schema` uses the graph to reject an authored document whose
  emulated methods delegate to each other in a cycle. Edges into a method the
  venue serves natively end the chain there, so only emulated-to-emulated
  edges can close a cycle.

  The graph is keyed and valued in unified method atoms; `js_graph/0` is the
  same graph in the camelCase vocabulary authored documents use.
  """

  @edges %{
    fetch_bids_asks: [:fetch_tickers],
    fetch_canceled_and_closed_orders: [:fetch_orders],
    fetch_canceled_orders: [:fetch_orders],
    fetch_closed_orders: [:fetch_orders],
    fetch_currencies: [:fetch_markets],
    fetch_deposit_address: [:fetch_deposit_addresses, :fetch_deposit_addresses_by_network],
    fetch_deposit_withdraw_fee: [:fetch_deposit_withdraw_fees],
    fetch_deposits_withdrawals: [:fetch_deposits, :fetch_withdrawals, :fetch_ledger],
    fetch_funding_interval: [:fetch_markets, :fetch_funding_intervals],
    fetch_funding_rate: [:fetch_markets, :fetch_funding_rates],
    fetch_funding_rates: [:fetch_funding_rate],
    fetch_isolated_borrow_rate: [:fetch_isolated_borrow_rates],
    fetch_leverage: [:fetch_leverages],
    fetch_margin_mode: [:fetch_margin_modes],
    fetch_market_leverage_tiers: [:fetch_markets, :fetch_leverage_tiers],
    fetch_my_trades: [:fetch_orders],
    fetch_open_interest: [:fetch_open_interests],
    fetch_open_orders: [:fetch_orders],
    fetch_order: [:fetch_orders, :fetch_open_orders, :fetch_closed_orders, :fetch_canceled_orders],
    fetch_order_trades: [:fetch_my_trades],
    fetch_position: [:fetch_positions],
    fetch_position_history: [:fetch_positions_history],
    fetch_ticker: [:fetch_tickers, :fetch_markets],
    fetch_trading_fee: [:fetch_trading_fees],
    fetch_trading_limits: [:fetch_markets],
    fetch_transaction_fee: [:fetch_transaction_fees],
    fetch_transactions: [:fetch_deposits, :fetch_withdrawals, :fetch_ledger]
  }

  @doc "Returns the declared graph: emulated method => methods its handler may call."
  @spec edges() :: %{atom() => [atom()]}
  def edges, do: @edges

  @doc "Returns true when `from`'s emulation handler is declared to call `to`."
  @spec declared?(atom(), atom()) :: boolean()
  def declared?(from, to) when is_atom(from) and is_atom(to) do
    to in Map.get(@edges, from, [])
  end

  @doc """
  Raises unless `from`'s emulation handler is declared to call `to`.

  `Bourse.Emulation` calls this before every nested call, ahead of any
  endpoint-availability check, so an undeclared edge fails on its first run
  even when the delegated method has no native route.
  """
  @spec assert_declared!(atom(), atom()) :: :ok
  def assert_declared!(from, to) do
    if declared?(from, to) do
      :ok
    else
      raise ArgumentError,
            "emulated #{from} delegated to #{to}, an edge #{inspect(__MODULE__)} does not declare; " <>
              "declare it so authored documents are checked for emulation cycles through it"
    end
  end

  @doc "Returns the graph in authored camelCase method names."
  @spec js_graph() :: %{String.t() => [String.t()]}
  def js_graph do
    Map.new(@edges, fn {from, targets} -> {js_name(from), Enum.map(targets, &js_name/1)} end)
  end

  @doc """
  Returns the first delegation cycle among `emulated` (camelCase names), or nil.

  The cycle is returned as a closed path, first name repeated last:
  `["fetchFundingRate", "fetchFundingRates", "fetchFundingRate"]`.
  """
  @spec find_cycle([String.t()]) :: [String.t()] | nil
  def find_cycle(emulated) when is_list(emulated) do
    nodes = MapSet.new(emulated)
    graph = js_graph()

    successors = fn name ->
      graph |> Map.get(name, []) |> Enum.filter(&MapSet.member?(nodes, &1))
    end

    nodes
    |> Enum.sort()
    |> Enum.find_value(fn start -> walk(start, [start], successors) end)
  end

  defp walk(current, path, successors) do
    Enum.find_value(successors.(current), fn next ->
      if next in path do
        cycle = path |> Enum.reverse() |> Enum.drop_while(&(&1 != next))
        cycle ++ [next]
      else
        walk(next, [next | path], successors)
      end
    end)
  end

  @doc false
  @spec js_name(atom()) :: String.t()
  def js_name(method) when is_atom(method) do
    [head | rest] = method |> Atom.to_string() |> String.split("_")
    Enum.join([head | Enum.map(rest, &String.capitalize/1)])
  end
end
