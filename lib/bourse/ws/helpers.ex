defmodule Bourse.WS.Helpers do
  @moduledoc """
  Pure helpers for WS URL resolution.

  Subscribe-frame construction lives in the pattern modules under
  `Bourse.WS.Subscription.*` (T94); this module now only holds the hostname
  interpolation helper used by `Bourse.WS.URLRouting`.
  """

  @doc """
  Replaces the `{hostname}` placeholder in a URL template. Nil hostname returns
  the template unchanged (mirrors the private helper of the same name in `Bourse.Exchange`).
  """
  @spec interpolate_hostname(String.t() | nil, String.t() | nil) :: String.t() | nil
  def interpolate_hostname(nil, _hostname), do: nil
  def interpolate_hostname(url, nil), do: url
  def interpolate_hostname(url, hostname) when is_binary(hostname), do: String.replace(url, "{hostname}", hostname)
end
