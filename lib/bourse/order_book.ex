defmodule Bourse.OrderBook do
  @moduledoc """
  Unified order book (market depth) data.

  Contains sorted bid and ask price levels, each as an exact `[price, amount]` pair.
  Venue-specific level metadata remains available in `info`.
  Bids are sorted highest-first, asks lowest-first.

  ## Fields

    * `symbol` - Unified symbol (e.g., "BTC/USDT")
    * `timestamp` - Exchange timestamp in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `nonce` - Incremental update sequence number
    * `bids` - List of exact `[price, amount]` bid pairs, highest first
    * `asks` - List of exact `[price, amount]` ask pairs, lowest first
    * `info` - Raw exchange response

  """

  import JSONSpec, only: [schema: 2]

  @typedoc "An exact two-number `[price, amount]` pair."
  @type level :: [number()]

  @type t :: %__MODULE__{
          symbol: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          nonce: integer() | nil,
          bids: [level()],
          asks: [level()],
          info: map() | nil
        }

  defstruct [
    :symbol,
    :timestamp,
    :datetime,
    :nonce,
    :info,
    bids: [],
    asks: []
  ]

  @doc "Returns the best (highest) bid price, or nil if empty/malformed."
  @spec best_bid(t()) :: number() | nil
  def best_bid(%__MODULE__{bids: [[price, amount] | _]}) when is_number(price) and is_number(amount), do: price
  def best_bid(%__MODULE__{}), do: nil

  @doc "Returns the best (lowest) ask price, or nil if empty/malformed."
  @spec best_ask(t()) :: number() | nil
  def best_ask(%__MODULE__{asks: [[price, amount] | _]}) when is_number(price) and is_number(amount), do: price
  def best_ask(%__MODULE__{}), do: nil

  @doc "Returns the spread (best ask price - best bid price), or nil if either side is empty/malformed."
  @spec spread(t()) :: number() | nil
  def spread(%__MODULE__{} = ob) do
    with bid when is_number(bid) <- best_bid(ob),
         ask when is_number(ask) <- best_ask(ob) do
      ask - bid
    else
      _ -> nil
    end
  end

  @level_schema %{"type" => "array", "items" => %{"type" => "number"}, "minItems" => 2, "maxItems" => 2}

  @json_schema %{
                 symbol: String.t() | nil,
                 timestamp: integer() | nil,
                 datetime: String.t() | nil,
                 nonce: integer() | nil,
                 bids: [[number()]],
                 asks: [[number()]],
                 info: map() | nil
               }
               |> schema(
                 doc: [
                   symbol: "Unified symbol (e.g., BTC/USDT)",
                   timestamp: "Exchange timestamp in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   nonce: "Incremental update sequence number",
                   bids: "List of exact [price, amount] bid pairs, highest first",
                   asks: "List of exact [price, amount] ask pairs, lowest first",
                   info: "Raw exchange response"
                 ]
               )
               |> put_in(["properties", "bids", "items"], @level_schema)
               |> put_in(["properties", "asks", "items"], @level_schema)

  @doc "JSON Schema for the OrderBook unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
