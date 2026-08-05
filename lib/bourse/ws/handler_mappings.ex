defmodule Bourse.WS.HandlerMappings do
  @moduledoc """
  Maps the `handle*` method names carried by the authored WebSocket slices to
  unified `watch_*` family atoms.

  Non-family handlers (auth, pong, subscription management) map to `:system`.
  """

  @handler_to_family %{
    "handleTicker" => :watch_ticker,
    "handleTickers" => :watch_ticker,
    "handleBidAsk" => :watch_ticker,
    "handleBidsAsks" => :watch_ticker,
    "handleMarkPrices" => :watch_ticker,
    "handleWsTickers" => :watch_ticker,
    "handleMarketData" => :watch_ticker,
    "handlePricePointUpdates" => :watch_ticker,
    "handleTrades" => :watch_trades,
    "handleTrade" => :watch_trades,
    "handleTradesSnapshot" => :watch_trades,
    "handleMyTrade" => :watch_trades,
    "handleMyTrades" => :watch_trades,
    "handleOrderBook" => :watch_order_book,
    "handleOrderBookUpdate" => :watch_order_book,
    "handleOrderBookSnapshot" => :watch_order_book,
    "handleOrderBookPartialSnapshot" => :watch_order_book,
    "handleL2Updates" => :watch_order_book,
    "handleChecksum" => :watch_order_book,
    "handleOHLCV" => :watch_ohlcv,
    "handleOHLCV1m" => :watch_ohlcv,
    "handleOHLCV24" => :watch_ohlcv,
    "handleInitOHLCV" => :watch_ohlcv,
    "handleFetchOHLCV" => :watch_ohlcv,
    "handleOrders" => :watch_orders,
    "handleOrder" => :watch_orders,
    "handleOrderUpdate" => :watch_orders,
    "handleMyOrder" => :watch_orders,
    "handleSingleOrder" => :watch_orders,
    "handleMultipleOrders" => :watch_orders,
    "handleOrderRequest" => :watch_orders,
    "handleBalance" => :watch_balance,
    "handleAcountUpdate" => :watch_balance,
    "handleBalanceAndPosition" => :watch_balance,
    "handleBalanceSnapshot" => :watch_balance,
    "handleAccount" => :watch_balance,
    "handleAccountUpdate" => :watch_balance,
    "handleFetchBalance" => :watch_balance,
    "handlePositions" => :watch_positions
  }

  @multi_family_handlers %{
    "handleAcountUpdate" => [:watch_balance, :watch_positions],
    "handleBalanceAndPosition" => [:watch_balance, :watch_positions]
  }

  @known_families [
    :watch_ticker,
    :watch_trades,
    :watch_order_book,
    :watch_ohlcv,
    :watch_orders,
    :watch_balance,
    :watch_positions
  ]

  @type resolve_result :: {:family, atom()} | :system | :not_found

  @doc "Resolves a handler method name to a watch family or `:system`."
  @spec resolve_handler(String.t() | nil) :: resolve_result()
  def resolve_handler(nil), do: :not_found

  def resolve_handler(handler_name) when is_binary(handler_name) do
    case Map.get(@handler_to_family, handler_name) do
      nil -> :system
      family -> {:family, family}
    end
  end

  @doc "Returns the primary family for a handler, or nil for non-family handlers."
  @spec handler_to_family(String.t()) :: atom() | nil
  def handler_to_family(handler_name), do: Map.get(@handler_to_family, handler_name)

  @doc "Returns all families a handler dispatches to (composite handlers may return multiple)."
  @spec handler_to_families(String.t()) :: [atom()]
  def handler_to_families(handler_name) do
    case Map.get(@multi_family_handlers, handler_name) do
      nil ->
        case handler_to_family(handler_name) do
          nil -> []
          family -> [family]
        end

      families ->
        families
    end
  end

  @doc "Returns the known watch family atoms."
  @spec known_families() :: [atom()]
  def known_families, do: @known_families
end
