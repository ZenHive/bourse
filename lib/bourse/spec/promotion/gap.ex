defmodule Bourse.Spec.Promotion.Gap do
  @moduledoc "Promotion failure with a stable code and actionable context."

  @enforce_keys [:code, :message]
  defstruct [:code, :message, :item_id]

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          item_id: String.t() | nil
        }

  @doc "Builds a promotion gap, optionally tied to an evidence item."
  @spec new(atom(), String.t(), String.t() | nil) :: t()
  def new(code, message, item_id \\ nil) when is_atom(code) and is_binary(message) do
    %__MODULE__{code: code, message: message, item_id: item_id}
  end
end
