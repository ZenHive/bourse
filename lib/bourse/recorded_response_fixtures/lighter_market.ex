defmodule Bourse.RecordedResponseFixtures.LighterMarket do
  @moduledoc """
  Shared Lighter market-id resolution for the recording and acceptance fixtures.

  Lighter's private read and order params carry the integer `market_id` (and an
  integer `account_index`), which both the live-recording capture and the
  exchange-acceptance rebuild resolve from a loaded `%Bourse.Market{}` set. The
  lookup lives here so the two fixture paths share one definition (task 521).
  """

  alias Bourse.Market

  @doc "Resolves the integer Lighter market id for `symbol` from a loaded market set."
  @spec market_id([Market.t()], String.t()) ::
          {:ok, integer()} | {:error, {:unknown_lighter_market, String.t()}}
  def market_id(markets, symbol) when is_list(markets) do
    case Enum.find(markets, &match?(%Market{symbol: ^symbol}, &1)) do
      %Market{id: id} -> {:ok, credential_integer!(id)}
      nil -> {:error, {:unknown_lighter_market, symbol}}
    end
  end

  @doc "Coerces a Lighter credential/market identifier to the integer the API expects."
  @spec credential_integer!(integer() | String.t()) :: integer()
  def credential_integer!(value) when is_integer(value), do: value
  def credential_integer!(value) when is_binary(value), do: String.to_integer(value)
end
