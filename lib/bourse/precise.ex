defmodule Bourse.Precise do
  @moduledoc """
  Money-exact decimal string arithmetic for response normalization.

  The contract is **string in, string out**: operands and results are decimal
  strings, never floats. A computed field such as trade
  `cost = amount × price` therefore remains `"10.4727"` for
  `"0.0001" × "104727.0"` instead of acquiring binary-float drift.

  Only the operations the response-normalization layer needs (`add`, `mul`,
  `div`) are ported.

  ## Semantics

  - A `nil` operand returns `nil`.
  - `string_div/3` truncates **toward zero** to `precision` decimal places
    using `Decimal` `:down` rounding. Default precision is 18; `precision` may
    be zero or negative.
  - Division by zero returns `nil`.
  - Results are reduced (trailing zeros trimmed) and never scientific notation.
  """

  # Wide enough that truncation to `precision` decimal places is exact for the
  # crypto price/amount domain — the div quotient is computed at far more
  # significant digits than any `precision` we then truncate to.
  @div_context %Decimal.Context{precision: 60, rounding: :down}

  @default_div_precision 18

  @doc """
  Multiplies two decimal strings, returning a reduced decimal string (or `nil`).

      iex> Bourse.Precise.string_mul("0.0001", "104727.0")
      "10.4727"
      iex> Bourse.Precise.string_mul("0.00000002", "69696900000")
      "1393.938"
      iex> Bourse.Precise.string_mul(nil, "5")
      nil
  """
  @spec string_mul(String.t() | nil, String.t() | nil) :: String.t() | nil
  def string_mul(string1, string2) when is_binary(string1) and is_binary(string2) do
    string1
    |> decimal()
    |> Decimal.mult(decimal(string2))
    |> to_plain_string()
  end

  def string_mul(_string1, _string2), do: nil

  @doc "Adds two decimal strings, returning a reduced decimal string (or `nil`)."
  @spec string_add(String.t() | nil, String.t() | nil) :: String.t() | nil
  def string_add(string1, string2) when is_binary(string1) and is_binary(string2) do
    string1
    |> decimal()
    |> Decimal.add(decimal(string2))
    |> to_plain_string()
  end

  def string_add(_string1, _string2), do: nil

  @doc """
  Divides two decimal strings, truncating toward zero to `precision` decimal
  places. Returns a reduced decimal string, or `nil` on a `nil` operand or a
  zero divisor.

      iex> Bourse.Precise.string_div("69696900000", "1e8")
      "696.969"
      iex> Bourse.Precise.string_div("0.00000002", "69696900000", 19)
      "0.0000000000000000002"
      iex> Bourse.Precise.string_div("5", "0")
      nil
  """
  @spec string_div(String.t() | nil, String.t() | nil, integer()) :: String.t() | nil
  def string_div(string1, string2, precision \\ @default_div_precision)

  def string_div(string1, string2, precision) when is_binary(string1) and is_binary(string2) and is_integer(precision) do
    divisor = decimal(string2)

    if Decimal.equal?(divisor, 0) do
      nil
    else
      string1
      |> decimal()
      |> div_with_context(divisor)
      |> Decimal.round(precision, :down)
      |> to_plain_string()
    end
  end

  def string_div(_string1, _string2, _precision), do: nil

  defp decimal(value), do: Decimal.new(value, max_digits: :infinity)

  defp div_with_context(numerator, divisor) do
    Decimal.Context.with(@div_context, fn -> Decimal.div(numerator, divisor) end)
  end

  defp to_plain_string(%Decimal{} = decimal) do
    decimal
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
    |> strip_negative_zero()
  end

  defp strip_negative_zero("-0"), do: "0"
  defp strip_negative_zero(string), do: string
end
