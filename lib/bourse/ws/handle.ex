defmodule Bourse.WS.Handle do
  @moduledoc """
  Subscription handle returned by unified `watch_*` functions.

  Carries enough state to send a matching unsubscribe frame via
  `Bourse.WS.unsubscribe/1` and release a dedicated routed connection.
  """

  alias Bourse.Exchange
  alias Bourse.WS

  @enforce_keys [:ws, :exchange, :method, :channels]
  defstruct [:ws, :exchange, :method, :channels, opts: [], owns_connection?: false]

  @type method :: :watch_ticker | :watch_order_book | :watch_trades | :watch_orders

  @type t :: %__MODULE__{
          ws: WS.t(),
          exchange: Exchange.t(),
          method: method(),
          channels: [WS.Subscription.channel()],
          opts: keyword() | map(),
          owns_connection?: boolean()
        }

  @doc false
  @spec new(WS.t(), method(), WS.Subscription.channel() | [WS.Subscription.channel()], keyword() | map()) ::
          t()
  def new(ws, method, channels, opts \\ []) do
    %__MODULE__{
      ws: ws,
      exchange: ws.exchange,
      method: method,
      channels: List.wrap(channels),
      opts: opts
    }
  end
end
