defmodule Bourse.RateLimiter.Info do
  @moduledoc """
  Rate limit status information parsed from exchange response headers.

  Exchanges report rate limit status with every API response (not just 429s).
  This struct captures that information in a normalized format.

  ## Sources

  Different exchanges use different header patterns:

  | Source | Exchange | Headers |
  |--------|----------|---------|
  | `:binance_weight` | Binance | `x-mbx-used-weight-1m`, `x-sapi-used-ip-weight-1m` |
  | `:bybit_bapi` | Bybit | `x-bapi-limit`, `x-bapi-limit-status`, `x-bapi-limit-reset-timestamp` |
  | `:standard` | KuCoin, others | `x-ratelimit-limit`, `x-ratelimit-remaining`, `x-ratelimit-reset` |
  """

  @type t :: %__MODULE__{
          exchange: String.t() | nil,
          axis: String.t() | nil,
          limit: non_neg_integer() | nil,
          used: non_neg_integer() | nil,
          remaining: non_neg_integer() | nil,
          reset_at: integer() | nil,
          source: atom(),
          raw_headers: %{String.t() => String.t()}
        }

  defstruct [
    :exchange,
    :axis,
    :limit,
    :used,
    :remaining,
    :reset_at,
    :source,
    raw_headers: %{}
  ]

  @default_threshold 0.1

  @doc """
  Returns true if remaining capacity is below the threshold percentage.

  Threshold is a float between 0.0 and 1.0 representing the fraction of
  total capacity. Default is 0.1 (10%).

  Returns `false` if limit or remaining data is not available.
  """
  @spec should_wait?(t(), float()) :: boolean()
  def should_wait?(%__MODULE__{} = info, threshold \\ @default_threshold) do
    case {info.limit, info.remaining} do
      {limit, remaining} when is_integer(limit) and limit > 0 and is_integer(remaining) ->
        remaining / limit < threshold

      _ ->
        false
    end
  end

  @doc """
  Returns milliseconds to wait until the rate limit window resets.

  Returns 0 if no reset time is available or the reset time has already passed.
  """
  @spec wait_time(t()) :: non_neg_integer()
  def wait_time(%__MODULE__{reset_at: nil}), do: 0

  def wait_time(%__MODULE__{reset_at: reset_at}) when is_integer(reset_at) do
    now_ms = System.system_time(:millisecond)
    max(reset_at - now_ms, 0)
  end

  @doc """
  Returns the percentage of rate limit capacity used (0.0 to 100.0).

  Returns `nil` if insufficient data to calculate usage.
  """
  @spec usage_percent(t()) :: float() | nil
  def usage_percent(%__MODULE__{used: used, limit: limit}) when is_integer(used) and is_integer(limit) and limit > 0 do
    used / limit * 100.0
  end

  def usage_percent(%__MODULE__{remaining: remaining, limit: limit})
      when is_integer(remaining) and is_integer(limit) and limit > 0 do
    (limit - remaining) / limit * 100.0
  end

  def usage_percent(%__MODULE__{}), do: nil
end
