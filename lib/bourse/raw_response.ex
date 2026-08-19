defmodule Bourse.RawResponse do
  @moduledoc """
  Labelled provider payload returned when a unified mapping is incomplete.

  The struct keeps raw transport data distinguishable from normalized Bourse
  structs while preserving the provider operation for agent consumers.
  """

  @enforce_keys [:payload, :venue, :method, :verification]
  defstruct [:payload, :venue, :method, :verification]

  @typedoc "Whether the incomplete implementation has provider-registered verification evidence."
  @type verification :: :verified | :unverified

  @type t :: %__MODULE__{
          payload: term(),
          venue: String.t(),
          method: String.t(),
          verification: verification()
        }

  @doc "Builds a labelled raw provider response."
  @spec new(term(), String.t(), String.t(), verification()) :: t()
  def new(payload, venue, method, verification)
      when is_binary(venue) and is_binary(method) and verification in [:verified, :unverified] do
    %__MODULE__{payload: payload, venue: venue, method: method, verification: verification}
  end
end
