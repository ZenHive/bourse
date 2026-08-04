defmodule Bourse.OHLCV do
  @moduledoc """
  Candlestick (OHLCV) bar data.

  Represents a single candlestick with open, high, low, close prices
  and volume for a time period.

  ## Fields

    * `timestamp` - Period start time in milliseconds
    * `open` - Opening price
    * `high` - Highest price
    * `low` - Lowest price
    * `close` - Closing price
    * `volume` - Trading volume in base currency

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          timestamp: integer(),
          open: number() | nil,
          high: number() | nil,
          low: number() | nil,
          close: number() | nil,
          volume: number() | nil
        }

  @enforce_keys [:timestamp]
  defstruct [:timestamp, :open, :high, :low, :close, :volume]

  @doc """
  Creates an OHLCV struct from a list.

  Bourse exchanges return candles as `[timestamp, open, high, low, close, volume]`.

  ## Examples

      Bourse.OHLCV.from_list([1_680_000_000_000, 28000.0, 28500.0, 27800.0, 28200.0, 150.5])

  """
  @spec from_list([number() | nil]) :: t()
  def from_list([timestamp, open, high, low, close, volume]) when is_integer(timestamp) do
    %__MODULE__{
      timestamp: timestamp,
      open: open,
      high: high,
      low: low,
      close: close,
      volume: volume
    }
  end

  @json_schema schema(
                 %{
                   timestamp: integer(),
                   open: number() | nil,
                   high: number() | nil,
                   low: number() | nil,
                   close: number() | nil,
                   volume: number() | nil
                 },
                 doc: [
                   timestamp: "Period start time in milliseconds",
                   open: "Opening price",
                   high: "Highest price",
                   low: "Lowest price",
                   close: "Closing price",
                   volume: "Trading volume in base currency"
                 ]
               )

  @doc "JSON Schema for the OHLCV unified type."
  @spec schema() :: map()
  def schema, do: @json_schema
end
