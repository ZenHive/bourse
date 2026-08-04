defmodule Bourse.Symbol.Error do
  @moduledoc """
  Error raised when symbol conversion fails.

  Provides detailed context about what went wrong, including the symbol,
  reason, exchange ID, and market type when available.
  """

  defexception [:message, :symbol, :reason, :exchange_id, :market_type]

  @type t :: %__MODULE__{
          message: String.t(),
          symbol: String.t() | nil,
          reason: reason(),
          exchange_id: String.t() | nil,
          market_type: atom() | nil
        }

  @type reason ::
          :invalid_format
          | :pattern_not_found
          | :unknown_quote_currency
          | :parse_failed
          | :unrepresentable_id
          | {:unsupported_prefix, String.t()}

  @doc "Creates a symbol error with optional symbol, reason, exchange, and market context."
  @spec new(String.t(), keyword()) :: t()
  def new(message, opts \\ []) do
    %__MODULE__{
      message: message,
      symbol: Keyword.get(opts, :symbol),
      reason: Keyword.get(opts, :reason, :unknown),
      exchange_id: Keyword.get(opts, :exchange_id),
      market_type: Keyword.get(opts, :market_type)
    }
  end

  @doc "Creates an error for invalid symbol format."
  @spec invalid_format(String.t()) :: t()
  def invalid_format(symbol) do
    new("Invalid symbol format: #{inspect(symbol)}", symbol: symbol, reason: :invalid_format)
  end

  @doc "Creates an error for missing pattern configuration."
  @spec pattern_not_found(String.t(), atom(), String.t() | nil) :: t()
  def pattern_not_found(symbol, market_type, exchange_id \\ nil) do
    exchange_desc = if exchange_id, do: " in #{exchange_id}", else: ""

    new(
      "No symbol pattern found for market type :#{market_type}#{exchange_desc}",
      symbol: symbol,
      reason: :pattern_not_found,
      exchange_id: exchange_id,
      market_type: market_type
    )
  end

  @doc "Creates an error for unknown quote currency."
  @spec unknown_quote_currency(String.t(), String.t() | nil) :: t()
  def unknown_quote_currency(symbol, attempted_split \\ nil) do
    extra = if attempted_split, do: " (tried to split: #{attempted_split})", else: ""

    new(
      "Could not determine quote currency in #{inspect(symbol)}#{extra}",
      symbol: symbol,
      reason: :unknown_quote_currency
    )
  end

  @doc "Creates an error for parse failures."
  @spec parse_failed(String.t(), term()) :: t()
  def parse_failed(symbol, reason) do
    new(
      "Failed to parse symbol #{inspect(symbol)}: #{inspect(reason)}",
      symbol: symbol,
      reason: :parse_failed
    )
  end

  @doc "Creates an error for unsupported prefix patterns."
  @spec unsupported_prefix(String.t(), String.t()) :: t()
  def unsupported_prefix(symbol, prefix) do
    new(
      "Unsupported prefix #{inspect(prefix)} in symbol #{inspect(symbol)}",
      symbol: symbol,
      reason: {:unsupported_prefix, prefix}
    )
  end

  @doc """
  Creates an error when a reverse conversion rewrote an id without unifying it.

  Used when a pattern path partially transforms an exchange id (e.g. upcase)
  but does not produce a unified symbol — returning that intermediate would be
  a plausible-but-wrong string that resolves to nothing.
  """
  @spec unrepresentable_id(String.t(), String.t(), String.t() | nil, atom() | nil) :: t()
  def unrepresentable_id(exchange_id, converted, exchange \\ nil, market_type \\ nil) do
    type_desc = if market_type, do: " under :#{market_type}", else: ""
    exchange_desc = if exchange, do: " on #{exchange}", else: ""

    new(
      "Exchange id #{inspect(exchange_id)} was rewritten without a unified form#{type_desc}#{exchange_desc} " <>
        "(got #{inspect(converted)}); the selected pattern cannot faithfully represent this id",
      symbol: exchange_id,
      reason: :unrepresentable_id,
      exchange_id: exchange,
      market_type: market_type
    )
  end

  @impl Exception
  def message(%__MODULE__{message: msg}), do: msg
end
