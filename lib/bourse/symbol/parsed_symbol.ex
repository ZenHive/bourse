defmodule Bourse.Symbol.ParsedSymbol do
  @moduledoc """
  Typed components of a unified extended symbol from `Bourse.Symbol.parse_extended/1`.

  Fields mirror the Bourse unified derivative grammar:

      BASE/QUOTE[:SETTLE[-EXPIRY[-STRIKE-OPTION_TYPE]]]

  Spot pairs leave settle/expiry/strike/option_type as `nil`. Swap fills
  settle; futures add expiry; options add strike and option_type (`"C"`/`"P"`).
  """

  @enforce_keys [:base, :quote]
  defstruct [:base, :quote, :settle, :expiry, :strike, :option_type]

  @type t :: %__MODULE__{
          base: String.t(),
          quote: String.t(),
          settle: String.t() | nil,
          expiry: String.t() | nil,
          strike: String.t() | nil,
          option_type: String.t() | nil
        }
end
