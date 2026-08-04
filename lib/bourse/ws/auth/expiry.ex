defmodule Bourse.WS.Auth.Expiry do
  @moduledoc """
  Pure helpers for computing auth session expiry timing.

  Used by the adapter layer (T94/T95) to decide when to schedule an
  `:auth_expired` re-auth timer. TTL sources in priority order:

  1. **Response-level** — auth response returns `{:ok, %{ttl_ms: N}}` from
     `handle_auth_response/2` (e.g. deribit emits `expires_in` in seconds)
  2. **Config-level** — `auth_config[:auth_ttl_ms]` as a static override
  3. **None** — no TTL source, no timer scheduled (caller should not re-auth
     on a clock; rely on server-driven auth-failed errors instead)

  Not a `Bourse.WS.Auth.Behaviour` implementer — this is a pure utility
  shared across patterns that return TTL metadata.

  ## Example

      auth_meta = %{ttl_ms: 900_000}
      auth_config = %{pattern: :jsonrpc_linebreak}

      ttl_ms = Expiry.compute_ttl_ms(auth_meta, auth_config)
      # => 900_000

      Expiry.schedule_delay_ms(ttl_ms)
      # => 720_000  (80% safety margin)
  """

  # Schedule re-auth at 80% of TTL to avoid racing server expiry.
  @default_safety_margin 0.80

  # Cap any single auth session at 24h — no refresh interval should exceed a day.
  @max_auth_ttl_ms 86_400_000

  @doc """
  Resolves the effective TTL (milliseconds) from response metadata and config.

  Response-level TTL (`auth_meta.ttl_ms`) wins over config-level
  (`auth_config[:auth_ttl_ms]`). Returns `nil` when neither is available.
  """
  @spec compute_ttl_ms(map() | nil, map() | nil) :: pos_integer() | nil
  def compute_ttl_ms(auth_meta, auth_config) do
    response_ttl =
      case auth_meta do
        %{ttl_ms: ttl} when is_integer(ttl) and ttl > 0 -> ttl
        _ -> nil
      end

    config_ttl =
      case auth_config do
        %{auth_ttl_ms: ttl} when is_integer(ttl) and ttl > 0 -> ttl
        _ -> nil
      end

    response_ttl || config_ttl
  end

  @doc """
  Computes the delay before scheduling `:auth_expired`, applying the
  80% safety margin and the 24h hard cap.

  Returns `nil` for `nil` or non-positive inputs.
  """
  @spec schedule_delay_ms(pos_integer() | nil) :: pos_integer() | nil
  def schedule_delay_ms(nil), do: nil
  def schedule_delay_ms(ttl_ms) when is_integer(ttl_ms) and ttl_ms <= 0, do: nil

  def schedule_delay_ms(ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    delay = trunc(ttl_ms * @default_safety_margin)
    min(delay, @max_auth_ttl_ms)
  end
end
