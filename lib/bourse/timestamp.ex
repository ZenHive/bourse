defmodule Bourse.Timestamp do
  @moduledoc """
  Timestamp formatting helpers shared across request signing and response parsing.
  """

  @doc "Formats a millisecond Unix timestamp as an ISO 8601 string, or nil when the timestamp is absent."
  @spec iso8601_from_ms(integer() | nil) :: String.t() | nil
  def iso8601_from_ms(nil), do: nil

  def iso8601_from_ms(timestamp_ms) when is_integer(timestamp_ms) do
    timestamp_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  @doc """
  Formats a millisecond Unix timestamp as a UTC ISO 8601 string truncated to
  whole seconds, with no zone designator — the `iso8601_seconds` authored format
  (`2017-05-11T15:19:30`), which htx/huobi/bittrade's signing scheme requires.
  """
  @spec iso8601_seconds_from_ms(integer() | nil) :: String.t() | nil
  def iso8601_seconds_from_ms(nil), do: nil

  def iso8601_seconds_from_ms(timestamp_ms) when is_integer(timestamp_ms) do
    timestamp_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%S")
  end
end
