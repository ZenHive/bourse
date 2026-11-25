defmodule Bourse.LogRedaction do
  @moduledoc """
  Redacts credential-bearing values in log output.

  A WebSocket URL can carry a credential in its path or query, and a session
  can hold the same credential on its own. OTP's termination reports
  (`gen_server` terminate, `proc_lib` crash, supervisor child reports) print a
  process's state, last message and reason verbatim, and Bourse's own warnings
  name connection failure reasons.

  Three boundaries are covered:

    * `filter/2`, installed by `Bourse.Application` as the primary `:logger`
      filter with id `Bourse.LogRedaction`, rewrites an OTP termination report
      (`gen_server`, `gen_statem`, `proc_lib`, `supervisor`) of a `Bourse.*` or
      `ZenWebsocket.*` process that contains such a value. A process is
      identified by its own identity first: a supervisor report's offender
      (`mfargs`), a crash report's `initial_call`, the reporting process's own
      initial call, or its registered name. The state struct decides only when
      none of these is available, so a host process that merely holds a
      `Bourse.WS` struct as its state is the host's, not Bourse's. Every other
      event, and every report it leaves unchanged, gets `:ignore`.

      OTP's `:logger` treats a filter that returns an event as passing it, so
      **a rewritten report passes a primary `filter_default: :stop`** that would
      otherwise have dropped it. The filter is on by default because these
      reports are the ones that print a connection's URL and session state
      whole, and a credential leaked to a log is not recoverable, while the cost
      of the default is that a host dropping all unfiltered events still sees
      Bourse's and ZenWebsocket's own termination reports (redacted). A host
      that wants its `:stop` default to hold for them sets
      `config :bourse, :redact_termination_reports, false`, which leaves the
      filter uninstalled; `format_status/1` and the warning lines below still
      redact. Application stop removes the filter only while it is still the
      filter this module installed.
    * `format_status/1` on Bourse's own long-lived processes passes their
      state, reason and last message through `redact/1`.
    * Bourse's warnings render terms with `inspect/1` from this module.

  `redact/1` cuts every `ws://`, `wss://`, `http://` and `https://` URL down to
  its scheme and host, without user information, in binaries, charlists, map
  keys and `URI` structs, and replaces the values of fields that hold a
  credential (`listen_key`, `secret`, …).
  """

  import Kernel, except: [inspect: 1]

  @filter_id __MODULE__
  @labels [:gen_server, :gen_statem, :proc_lib, :supervisor]
  @url ~r{\b((?:wss?|https?)://)(?:[^@/?#\s"'<>]*@)?([^/?#\s"'<>@]+)[^\s"'<>]*}i
  @schemes ["ws://", "wss://", "http://", "https://"]
  @marker "/[REDACTED]"
  @redacted "[REDACTED]"
  @credential_keys ~w(listen_key listenKey secret api_secret api_key apiKey private_key passphrase password)
  @credential_key_atoms Enum.map(@credential_keys, &String.to_atom/1)

  @doc "The primary filter id `install/0` registers."
  @spec filter_id() :: atom()
  def filter_id, do: @filter_id

  @doc """
  Installs the primary filter. When another filter already uses the id it is
  left in place and `{:error, {:filter_id_taken, id}}` is returned.
  """
  @spec install() :: :ok | {:error, {:filter_id_taken, atom()}}
  def install do
    case :logger.add_primary_filter(@filter_id, own_filter()) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> if installed?(), do: :ok, else: {:error, {:filter_id_taken, @filter_id}}
    end
  end

  @doc "Removes the primary filter when it is the one `install/0` registered."
  @spec uninstall() :: :ok
  def uninstall do
    if installed?(), do: :logger.remove_primary_filter(@filter_id)
    :ok
  end

  @doc "Whether the primary filter under `filter_id/0` is this module's."
  @spec installed?() :: boolean()
  def installed? do
    :logger.get_primary_config()
    |> Map.get(:filters, [])
    |> List.keyfind(@filter_id, 0)
    |> Kernel.==({@filter_id, own_filter()})
  end

  defp own_filter, do: {&__MODULE__.filter/2, []}

  @doc """
  `:logger` filter callback. Returns the event with its report rewritten when an
  OTP termination report of a Bourse or ZenWebsocket process contains a
  credential-bearing value, `:ignore` otherwise.
  """
  @spec filter(:logger.log_event(), term()) :: :logger.log_event() | :ignore
  def filter(%{msg: {:report, %{label: {kind, _}} = report}} = event, _config) when kind in @labels do
    with true <- owned?(report),
         redacted when redacted != report <- redact(report) do
      %{event | msg: {:report, redacted}}
    else
      _ -> :ignore
    end
  end

  def filter(_event, _config), do: :ignore

  # Who a report belongs to is the identity of the process it is about; the
  # data that process holds only decides when it has none. Primary filters run
  # in the process that logs, so a gen_server or gen_statem terminate report is
  # identified by that process's initial call.
  defp owned?(report) do
    case identity(report) do
      nil -> own_module?(state_module(report))
      module -> own_module?(module)
    end
  end

  defp identity(%{label: {:supervisor, _}, report: report}) when is_list(report) do
    case report[:offender] do
      offender when is_list(offender) -> mfa_module(offender[:mfargs] || offender[:start])
      _ -> nil
    end
  end

  defp identity(%{label: {:proc_lib, _}, report: [info | _]}) when is_list(info),
    do: initial_call_module(info[:initial_call]) || process_identity(nil)

  defp identity(report), do: process_identity(report[:name])

  defp process_identity(name) do
    initial_call_module(Process.get(:"$initial_call")) || registered_module(name)
  end

  defp registered_module(name) when is_atom(name) and not is_nil(name), do: name
  defp registered_module(_name), do: nil

  defp state_module(%{state: %module{}}), do: module
  defp state_module(%{data: %module{}}), do: module
  defp state_module(_report), do: nil

  defp initial_call_module({:supervisor, module, _arity}) when is_atom(module), do: module
  defp initial_call_module(mfa), do: mfa_module(mfa)

  defp mfa_module({module, _function, _args}) when is_atom(module), do: module
  defp mfa_module(_other), do: nil

  defp own_module?(module) when is_atom(module) and not is_nil(module) do
    case Atom.to_string(module) do
      "Elixir.Bourse" -> true
      "Elixir.Bourse." <> _ -> true
      "Elixir.ZenWebsocket." <> _ -> true
      _ -> false
    end
  end

  defp own_module?(_other), do: false

  @doc "`Kernel.inspect/1` with `redact/1` applied to the term and to its rendering."
  @spec inspect(term()) :: String.t()
  def inspect(term), do: term |> redact() |> Kernel.inspect() |> redact()

  @doc "Body of `format_status/1` for Bourse's own processes."
  @spec format_status(map()) :: map()
  def format_status(status), do: Map.new(status, fn {key, value} -> {key, redact(value)} end)

  @doc "Redacts URLs and credential fields anywhere inside `term`."
  @spec redact(term()) :: term()
  def redact(term) when is_binary(term) do
    if String.contains?(String.downcase(term), @schemes),
      do: Regex.replace(@url, term, "\\1\\2" <> @marker),
      else: term
  end

  def redact(%URI{host: host} = uri) when is_binary(host),
    do: %URI{scheme: uri.scheme, host: host, port: uri.port, path: if(uri.path, do: @marker)}

  def redact(term) when is_list(term) do
    if charlist?(term) do
      string = List.to_string(term)
      redacted = redact(string)
      if redacted == string, do: term, else: String.to_charlist(redacted)
    else
      redact_list(term)
    end
  end

  def redact(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.map(&redact/1) |> List.to_tuple()
  def redact(%{__struct__: _} = struct), do: :maps.map(&redact_field/2, struct)
  def redact(term) when is_map(term), do: Map.new(term, fn {key, value} -> {redact(key), redact_field(key, value)} end)
  def redact(term), do: term

  defp redact_field(key, value) when key in @credential_keys or key in @credential_key_atoms do
    if is_binary(value) or is_list(value), do: @redacted, else: redact(value)
  end

  defp redact_field(_key, value), do: redact(value)

  defp charlist?([_ | _] = list), do: :io_lib.printable_unicode_list(list)
  defp charlist?(_), do: false

  defp redact_list([]), do: []
  defp redact_list([head | tail]) when is_list(tail), do: [redact(head) | redact_list(tail)]
  defp redact_list([head | tail]), do: [redact(head) | redact(tail)]
end
