defmodule Bourse.Signing.Request do
  @moduledoc """
  The unsigned request handed to a signing pattern.

  This is the input half of the `Bourse.Signing.Behaviour` contract: every
  pattern receives one of these and returns a `Bourse.Signing.SignedRequest`.
  `:path` is the endpoint path without the base URL, and `:params` holds the
  query or body parameters the pattern is free to sign, reorder, or encode.
  """

  @type method :: :get | :post | :put | :delete | :patch

  @type t :: %__MODULE__{
          method: method(),
          path: String.t(),
          body: String.t() | nil,
          params: map()
        }

  @enforce_keys [:method, :path]
  defstruct [:method, :path, :body, params: %{}]
end
