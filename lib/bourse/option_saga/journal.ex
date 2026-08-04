defmodule Bourse.OptionSaga.Journal do
  @moduledoc """
  Caller-held execution journal for one approved option plan.

  The journal is ordinary immutable data. The library does not copy it into a
  process, ETS table, cache, or persistence layer.
  """

  @type leg_state ::
          :planned
          | :submitted
          | :accepted
          | :partial
          | :filled
          | :open
          | :cancelled
          | :failed
          | :unknown

  @type transition :: %{
          required(:state) => leg_state(),
          required(:at) => integer(),
          optional(:detail) => term()
        }

  @type leg :: %{
          required(:id) => term(),
          required(:execution_id) => String.t(),
          required(:client_order_id) => String.t(),
          required(:role) => :option | :hedge,
          required(:venue) => String.t(),
          required(:account) => term(),
          required(:symbol) => String.t(),
          required(:type) => String.t(),
          required(:side) => String.t(),
          required(:amount) => number(),
          required(:state) => leg_state(),
          required(:transitions) => [transition()],
          required(:acknowledged?) => boolean(),
          required(:cancel_attempted?) => boolean(),
          required(:cancel_retry_allowed?) => boolean(),
          optional(:price) => number() | nil,
          optional(:order_id) => String.t() | nil,
          optional(:filled) => number() | nil,
          optional(:remaining) => number() | nil
        }

  @type status ::
          :ready
          | :running
          | :monitoring
          | :compensating
          | :completed
          | :halted

  @type t :: %__MODULE__{
          plan_id: String.t(),
          approval_id: String.t(),
          approval_observed_at: integer(),
          max_approval_age_ms: non_neg_integer(),
          status: status(),
          legs: [leg()],
          compensations: [map()],
          residual_risk: [map()],
          failure: map() | nil,
          recorded_commands: [String.t()]
        }

  @enforce_keys [
    :plan_id,
    :approval_id,
    :approval_observed_at,
    :max_approval_age_ms,
    :status,
    :legs
  ]
  defstruct [
    :plan_id,
    :approval_id,
    :approval_observed_at,
    :max_approval_age_ms,
    :status,
    :legs,
    :failure,
    compensations: [],
    residual_risk: [],
    recorded_commands: []
  ]
end
