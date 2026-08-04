defmodule Bourse.OptionProposal.Result do
  @moduledoc """
  Non-mutating option-proposal preflight outcome.

  `status` is `:approved` only when every mechanical check passes. Rejections
  keep every projected quantity, selected hedge, residual, and violation so the
  caller can adjust strategy without the library inventing one.
  """

  @type check :: %{
          required(:name) => atom(),
          required(:status) => :ok | :violation | :unknown | :unsupported,
          required(:detail) => term()
        }

  @type violation :: %{
          required(:code) => atom(),
          required(:message) => String.t(),
          optional(:check) => atom(),
          optional(:leg_id) => term(),
          optional(:detail) => term()
        }

  @type t :: %__MODULE__{
          status: :approved | :rejected,
          observed_at: integer(),
          projected: map(),
          hedge: map() | nil,
          margin_domains: [map()],
          cross_venue: map() | nil,
          checks: [check()],
          violations: [violation()],
          failures: [map()],
          plan: map(),
          strategy: map()
        }

  @enforce_keys [:status, :observed_at, :projected, :checks, :violations, :failures, :plan, :strategy]
  defstruct [
    :status,
    :observed_at,
    :projected,
    :hedge,
    :margin_domains,
    :cross_venue,
    :checks,
    :violations,
    :failures,
    :plan,
    :strategy
  ]
end
