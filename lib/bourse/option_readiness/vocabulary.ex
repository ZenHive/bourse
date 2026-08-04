defmodule Bourse.OptionReadiness.Vocabulary do
  @moduledoc """
  Compile-time vocabulary shared across the option-readiness modules.

  Leaf module with no struct dependencies: `VenueRow` and `Baseline` read the
  venue and cell lists at compile time, while `Bourse.OptionReadiness` needs
  their structs — routing the shared lists through the parent deadlocks a cold
  parallel build.
  """

  @venues ~w(deribit okx bybit derive)
  @cells [
    :discovery,
    :greeks,
    :balances,
    :positions,
    :open_orders,
    :create_fetch_cancel,
    :preflight,
    :hedge
  ]

  @doc "Venues covered by the readiness matrix."
  @spec venues() :: [String.t()]
  def venues, do: @venues

  @doc "Evidence cells collected per venue."
  @spec cells() :: [atom()]
  def cells, do: @cells
end
