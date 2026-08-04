defmodule Bourse.PortfolioRisk.Snapshot do
  @moduledoc """
  Point-in-time portfolio risk assembled across venue/account domains.

  `status` is `:complete` only when every requested read and every applicable
  risk bucket is complete. A `:partial` snapshot keeps component data,
  failures, and blocked buckets queryable without presenting their partial
  sums as coherent totals.
  """

  @type component :: %{
          required(:status) => :ok | :error,
          required(:observed_at) => integer(),
          optional(:data) => term(),
          optional(:error) => term(),
          optional(:source_timestamp) => integer() | nil
        }

  @type domain :: %{
          required(:venue) => String.t(),
          required(:account) => term(),
          required(:components) => %{atom() => component()},
          required(:margin) => {:ok, [map()]} | {:error, term()},
          required(:collateral) => {:ok, [map()]} | {:error, term()},
          required(:available_capacity) => {:ok, map()} | {:error, term()},
          required(:account_modes) => {:ok, [String.t()]} | {:error, term()},
          required(:liquidation_state) => {:ok, [map()]} | {:error, term()}
        }

  @type contribution :: map()
  @type aggregate :: map()
  @type blocked_bucket :: map()
  @type failure :: map()

  @type t :: %__MODULE__{
          status: :complete | :partial,
          observed_at: integer(),
          domains: [domain()],
          contributions: [contribution()],
          aggregates: [aggregate()],
          blocked_buckets: [blocked_bucket()],
          failures: [failure()]
        }

  @enforce_keys [:status, :observed_at]
  defstruct [
    :status,
    :observed_at,
    domains: [],
    contributions: [],
    aggregates: [],
    blocked_buckets: [],
    failures: []
  ]
end
