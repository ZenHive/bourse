defmodule Bourse.RateLimiter.Headers do
  @moduledoc """
  Parses rate limit status headers from exchange API responses.

  Exchanges return rate limit information with every response, not just 429s.
  This module detects the header pattern and extracts normalized rate limit data.

  ## Supported Patterns

  Patterns are tried in order; the first match wins:

  1. **Binance** -- `x-mbx-used-weight-1m`, `x-sapi-used-ip-weight-1m`,
     or `x-mbx-order-count-1m`
  2. **Bybit** -- `x-bapi-limit`, `x-bapi-limit-status`, `x-bapi-limit-reset-timestamp`
  3. **Standard** -- `x-ratelimit-limit`, `x-ratelimit-remaining`, `x-ratelimit-reset`

  Exchanges without custom rate limit headers (OKX, Kraken) return `:none`.
  """

  alias Bourse.RateLimiter.Info

  @default_axis "request"

  @doc """
  Parses rate limit headers from a response.

  Headers are in Req format: `%{String.t() => [String.t()]}` with lowercase keys.

  `spec_rate_limit` is the exchange's `rate_limit_ms` value (milliseconds between
  requests). Converted to max requests per minute (`60_000 / rate_limit_ms`) to
  derive `limit` when the exchange only reports `used` (e.g., Binance).

  Returns `{:ok, %Info{}}` if rate limit headers are found, `:none` otherwise.
  """
  @spec parse(String.t(), %{String.t() => [String.t()]}, number() | nil) ::
          {:ok, Info.t()} | :none
  def parse(exchange_id, headers, spec_rate_limit \\ nil) when is_binary(exchange_id) and is_map(headers) do
    with :none <- parse_binance(exchange_id, headers, spec_rate_limit),
         :none <- parse_bybit(exchange_id, headers) do
      parse_standard(exchange_id, headers)
    end
  end

  # =============================================================================
  # Binance Pattern
  #
  # Binance reports weight used in the current 1-minute window:
  # - x-mbx-used-weight-1m: Main API (api.binance.com)
  # - x-sapi-used-ip-weight-1m: SAPI endpoints (sapi.binance.com)
  #
  # Only `used` is reported; `limit` comes from spec rate_limit_ms.
  # =============================================================================

  # Binance weight headers report usage in a 1-minute window
  @binance_weight_period_ms 60_000
  @binance_ip_axis "ip"
  @binance_order_axis "order_weight"
  @binance_weight_headers ["x-mbx-used-weight-1m", "x-sapi-used-ip-weight-1m"]
  @binance_order_headers ["x-mbx-order-count-1m"]
  @binance_headers @binance_weight_headers ++ @binance_order_headers

  defp parse_binance(exchange_id, headers, spec_rate_limit) do
    case find_header(headers, @binance_headers) do
      {header_name, used_str} ->
        axis = binance_axis(header_name)
        used = parse_int(used_str)

        # Convert rate_limit_ms → max requests per minute (same as RateLimiter.Shaping)
        limit =
          if is_number(spec_rate_limit) and spec_rate_limit > 0,
            do: trunc(@binance_weight_period_ms / spec_rate_limit)

        remaining =
          if is_integer(used) and is_integer(limit) do
            max(limit - used, 0)
          end

        raw = collect_raw_headers(headers, @binance_headers)

        {:ok,
         %Info{
           exchange: exchange_id,
           axis: axis,
           limit: limit,
           used: used,
           remaining: remaining,
           reset_at: nil,
           source: binance_source(axis),
           raw_headers: Map.put(raw, "matched", header_name)
         }}

      nil ->
        :none
    end
  end

  defp binance_axis(header_name) when header_name in @binance_order_headers, do: @binance_order_axis
  defp binance_axis(_header_name), do: @binance_ip_axis

  defp binance_source(@binance_order_axis), do: :binance_order_count
  defp binance_source(_axis), do: :binance_weight

  # =============================================================================
  # Bybit Pattern
  #
  # Bybit provides all three pieces:
  # - x-bapi-limit: Maximum requests allowed
  # - x-bapi-limit-status: Remaining requests
  # - x-bapi-limit-reset-timestamp: Unix ms when window resets
  # =============================================================================

  @bybit_limit_header "x-bapi-limit"
  @bybit_remaining_header "x-bapi-limit-status"
  @bybit_reset_header "x-bapi-limit-reset-timestamp"
  @bybit_headers [@bybit_limit_header, @bybit_remaining_header, @bybit_reset_header]

  defp parse_bybit(exchange_id, headers) do
    case get_header(headers, @bybit_limit_header) do
      nil ->
        :none

      limit_str ->
        limit = parse_int(limit_str)
        remaining = parse_int(get_header(headers, @bybit_remaining_header))
        reset_at = parse_int(get_header(headers, @bybit_reset_header))

        used =
          if is_integer(limit) and is_integer(remaining) do
            max(limit - remaining, 0)
          end

        {:ok,
         %Info{
           exchange: exchange_id,
           axis: @default_axis,
           limit: limit,
           used: used,
           remaining: remaining,
           reset_at: reset_at,
           source: :bybit_bapi,
           raw_headers: collect_raw_headers(headers, @bybit_headers)
         }}
    end
  end

  # =============================================================================
  # Standard Pattern (RFC-style)
  #
  # Common headers used by KuCoin and others:
  # - x-ratelimit-limit: Maximum requests in window
  # - x-ratelimit-remaining: Remaining requests
  # - x-ratelimit-reset: Unix timestamp (seconds) when window resets
  # =============================================================================

  @standard_limit_header "x-ratelimit-limit"
  @standard_remaining_header "x-ratelimit-remaining"
  @standard_reset_header "x-ratelimit-reset"
  @standard_headers [@standard_limit_header, @standard_remaining_header, @standard_reset_header]

  defp parse_standard(exchange_id, headers) do
    case get_header(headers, @standard_limit_header) do
      nil ->
        :none

      limit_str ->
        limit = parse_int(limit_str)
        remaining = parse_int(get_header(headers, @standard_remaining_header))
        reset_seconds = parse_int(get_header(headers, @standard_reset_header))

        # Convert seconds to ms for consistency
        reset_at = if is_integer(reset_seconds), do: reset_seconds * 1000

        used =
          if is_integer(limit) and is_integer(remaining) do
            max(limit - remaining, 0)
          end

        {:ok,
         %Info{
           exchange: exchange_id,
           axis: @default_axis,
           limit: limit,
           used: used,
           remaining: remaining,
           reset_at: reset_at,
           source: :standard,
           raw_headers: collect_raw_headers(headers, @standard_headers)
         }}
    end
  end

  # =============================================================================
  # Helpers
  # =============================================================================

  # Gets first matching header value from a list of header names
  defp find_header(headers, names) do
    Enum.find_value(names, fn name ->
      case get_header(headers, name) do
        nil -> nil
        value -> {name, value}
      end
    end)
  end

  # Gets a single header value (Req headers are %{String.t() => [String.t()]})
  defp get_header(headers, name) do
    case Map.get(headers, name) do
      [value | _] -> value
      _ -> nil
    end
  end

  # Parses a string to integer, returns nil on failure
  defp parse_int(nil), do: nil

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  # Collects raw header values for the given header names
  defp collect_raw_headers(headers, names) do
    Enum.reduce(names, %{}, fn name, acc ->
      case get_header(headers, name) do
        nil -> acc
        value -> Map.put(acc, name, value)
      end
    end)
  end
end
