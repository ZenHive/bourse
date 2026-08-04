defmodule Bourse.Balance do
  @moduledoc """
  Unified account balance across currencies.

  Balances are stored as maps of `currency => amount` for each category
  (free, used, total).

  ## Fields

    * `free` - Available balance per currency
    * `used` - Balance locked in orders per currency
    * `total` - Total balance per currency (free + used)
    * `debt` - Borrowed balance per currency (margin accounts)
    * `timestamp` - Exchange timestamp in milliseconds
    * `datetime` - ISO 8601 datetime string
    * `info` - Raw exchange response

  ## Examples

      balance = %Bourse.Balance{
        free: %{"BTC" => 1.5, "USDT" => 10000.0},
        used: %{"BTC" => 0.5},
        total: %{"BTC" => 2.0, "USDT" => 10000.0}
      }

      Bourse.Balance.get(balance, "BTC")
      #=> %{free: 1.5, used: 0.5, total: 2.0}

  """

  import JSONSpec, only: [schema: 2]

  @type t :: %__MODULE__{
          free: %{String.t() => number()},
          used: %{String.t() => number()},
          total: %{String.t() => number()},
          debt: %{String.t() => number()},
          timestamp: integer() | nil,
          datetime: String.t() | nil,
          info: map() | nil
        }

  defstruct free: %{}, used: %{}, total: %{}, debt: %{}, timestamp: nil, datetime: nil, info: nil

  @json_schema schema(
                 %{
                   free: map(),
                   used: map(),
                   total: map(),
                   debt: map(),
                   timestamp: integer() | nil,
                   datetime: String.t() | nil,
                   info: map() | nil
                 },
                 doc: [
                   free: "Available balance per currency",
                   used: "Balance locked in orders per currency",
                   total: "Total balance per currency (free + used)",
                   debt: "Borrowed balance per currency (margin accounts)",
                   timestamp: "Exchange timestamp in milliseconds",
                   datetime: "ISO 8601 datetime string",
                   info: "Raw exchange response"
                 ]
               )

  @doc "JSON Schema for the Balance unified type."
  @spec schema() :: map()
  def schema, do: @json_schema

  @doc """
  Returns the balance for a specific currency.

  Returns a map with `:free`, `:used`, and `:total` keys, defaulting
  missing values to `0.0`. Returns `nil` if the currency has no entries.

  ## Examples

      Bourse.Balance.get(balance, "BTC")
      #=> %{free: 1.5, used: 0.5, total: 2.0}

      Bourse.Balance.get(balance, "UNKNOWN")
      #=> nil

  """
  @spec get(t(), String.t()) :: %{free: number(), used: number(), total: number()} | nil
  def get(%__MODULE__{} = balance, currency) when is_binary(currency) do
    free = Map.get(balance.free, currency)
    used = Map.get(balance.used, currency)
    total = Map.get(balance.total, currency)

    if is_nil(free) and is_nil(used) and is_nil(total) do
      nil
    else
      %{free: free || 0.0, used: used || 0.0, total: total || 0.0}
    end
  end

  @doc """
  Returns a sorted list of all currencies in the balance.

  ## Examples

      Bourse.Balance.currencies(balance)
      #=> ["BTC", "ETH", "USDT"]

  """
  @spec currencies(t()) :: [String.t()]
  def currencies(%__MODULE__{} = balance) do
    [balance.free, balance.used, balance.total, balance.debt]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
