defmodule Bourse.LogRedaction do
  @moduledoc """
  Redacts URLs in transport termination reports.

  A WebSocket URL can carry a credential in its path or query, and OTP's
  termination reports (`gen_server` terminate, `proc_lib` crash, supervisor
  child reports) print the stopped process's state, last message and reason
  verbatim. `Bourse.Application` installs `filter/2` as a primary `:logger`
  filter, so every handler — the default one included — receives those reports
  with each `ws://` / `wss://` URL cut down to its scheme and host.

  Only reports carrying one of those OTP labels are rewritten; every other log
  event passes through untouched.
  """

  @filter_id :bourse_redact_transport_urls
  @labels [:gen_server, :gen_statem, :proc_lib, :supervisor]
  @url ~r{(wss?://[^/?#\s"'<>]+)[^\s"'<>]*}
  @marker "/[REDACTED]"

  @doc "The primary filter id `install/0` registers."
  @spec filter_id() :: atom()
  def filter_id, do: @filter_id

  @doc "Installs the primary filter; idempotent."
  @spec install() :: :ok
  def install do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
    end
  end

  @doc "Removes the primary filter."
  @spec uninstall() :: :ok
  def uninstall do
    _ = :logger.remove_primary_filter(@filter_id)
    :ok
  end

  @doc "`:logger` filter callback: rewrites URLs in termination reports, passes everything else."
  @spec filter(:logger.log_event(), term()) :: :logger.log_event()
  def filter(%{msg: {:report, %{label: {kind, _}} = report}} = event, _config) when kind in @labels do
    %{event | msg: {:report, redact(report)}}
  end

  def filter(event, _config), do: event

  @doc "Replaces the path and query of every WebSocket URL inside `term`."
  @spec redact(term()) :: term()
  def redact(term) when is_binary(term) do
    if String.contains?(term, "ws://") or String.contains?(term, "wss://") do
      Regex.replace(@url, term, "\\1" <> @marker)
    else
      term
    end
  end

  def redact(term) when is_list(term), do: redact_list(term)
  def redact(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.map(&redact/1) |> List.to_tuple()
  def redact(term) when is_map(term), do: :maps.map(fn _key, value -> redact(value) end, term)
  def redact(term), do: term

  # Charlists and improper lists both occur in reports.
  defp redact_list([]), do: []
  defp redact_list([head | tail]) when is_list(tail), do: [redact(head) | redact_list(tail)]
  defp redact_list([head | tail]), do: [redact(head) | redact(tail)]
end
