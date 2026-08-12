defmodule Bourse.Ticker do
  @moduledoc """
  Unified market ticker data.

  Contains the latest price, volume, and spread information for a trading pair.

  ## Fields

    * `symbol` - Unified symbol (e.g., "BTC/USDT")
    * `timestamp` - Exchange timestamp in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `high`, `low` - 24h high/low prices
    * `bid`, `bid_volume` - Best bid price and volume
    * `ask`, `ask_volume` - Best ask price and volume
    * `vwap` - Volume-weighted average **price** (or `nil` when the venue does not
      supply volume units that form a price — see caveats below)
    * `open`, `close`, `last` - 24h open, close, and last trade prices
    * `previous_close` - Previous 24h close
    * `change`, `percentage` - 24h absolute change and percentage in percent points (10 = 10%)
    * `average` - Average of open and close
    * `base_volume`, `quote_volume` - 24h volume in base/quote currency
    * `index_price`, `mark_price` - Derivatives index/mark prices
    * `info` - Raw exchange response

  ## `vwap` caveat (carve C36)

  `vwap` is a **price**. It is only populated when the venue's volume operands
  are quote-notional over base-quantity (or the venue publishes a weighted
  average price directly). Blind `quoteVolume / baseVolume` is **not** always a
  price: on OKX SWAP/FUTURES, `vol24h` is contracts and `volCcy24h` is base
  currency, so that ratio collapses to contract size (`ctVal`, e.g. `0.01` on
  BTC-USDT-SWAP) rather than a ~mark price. We diverge from Bourse's
  always-divide carve there and leave `vwap` nil; consumers needing contract
  volume should read `base_volume` / `quote_volume` / raw `info`. See
  `docs/authored-specs.md` carve **C36**.

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          symbol: String.t() | nil,
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          high: number() | nil,
          low: number() | nil,
          bid: number() | nil,
          bid_volume: number() | nil,
          ask: number() | nil,
          ask_volume: number() | nil,
          vwap: number() | nil,
          open: number() | nil,
          close: number() | nil,
          last: number() | nil,
          previous_close: number() | nil,
          change: number() | nil,
          percentage: number() | nil,
          average: number() | nil,
          base_volume: number() | nil,
          quote_volume: number() | nil,
          index_price: number() | nil,
          mark_price: number() | nil,
          info: map() | nil
        }

  defstruct [
    :symbol,
    :timestamp,
    :datetime,
    :high,
    :low,
    :bid,
    :bid_volume,
    :ask,
    :ask_volume,
    :vwap,
    :open,
    :close,
    :last,
    :previous_close,
    :change,
    :percentage,
    :average,
    :base_volume,
    :quote_volume,
    :index_price,
    :mark_price,
    :info
  ]

  @json_schema schema(
                 %{
                   symbol: String.t() | nil,
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   high: number() | nil,
                   low: number() | nil,
                   bid: number() | nil,
                   bid_volume: number() | nil,
                   ask: number() | nil,
                   ask_volume: number() | nil,
                   vwap: number() | nil,
                   open: number() | nil,
                   close: number() | nil,
                   last: number() | nil,
                   previous_close: number() | nil,
                   change: number() | nil,
                   percentage: number() | nil,
                   average: number() | nil,
                   base_volume: number() | nil,
                   quote_volume: number() | nil,
                   index_price: number() | nil,
                   mark_price: number() | nil,
                   info: map() | nil
                 },
                 doc: [
                   symbol: "Unified symbol (e.g., BTC/USDT)",
                   timestamp: "Exchange timestamp in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   high: "24h high price",
                   low: "24h low price",
                   bid: "Best bid price",
                   bid_volume: "Best bid volume",
                   ask: "Best ask price",
                   ask_volume: "Best ask volume",
                   vwap:
                     "Volume-weighted average price when volume units form a price; nil on contract markets where quote/base collapses to contract size (C36)",
                   open: "24h opening price",
                   close: "24h closing price",
                   last: "Last trade price",
                   previous_close: "Previous 24h close",
                   change: "24h absolute price change",
                   percentage: "24h percentage change in percent points (10 = 10%)",
                   average: "Average of open and close",
                   base_volume: "24h volume in base currency",
                   quote_volume: "24h volume in quote currency",
                   index_price: "Derivatives index price",
                   mark_price: "Derivatives mark price",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the Ticker unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
