defmodule Bourse.Signing.Lighter.Worker do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Bourse.Signing.Lighter.Protocol
  alias Bourse.Signing.Lighter.WorkerSupervisor

  @default_timeout_ms 15_000
  @call_timeout_margin_ms 1_000

  @type identity :: binary()
  @type init_options :: %{
          required(:url) => String.t(),
          required(:private_key) => String.t(),
          required(:chain_id) => non_neg_integer(),
          required(:api_key_index) => non_neg_integer(),
          required(:account_index) => pos_integer(),
          required(:helper_path) => String.t(),
          optional(:helper_args) => [String.t()]
        }

  @doc """
  Runs one signing operation on the helper that owns `identity`, starting it on
  first use. Failures are reduced to sanitized atoms so helper internals and key
  material never reach the caller.
  """
  @spec request(identity(), init_options(), Protocol.operation(), map(), timeout()) ::
          {:ok, String.t() | Protocol.signed_transaction()}
          | {:error, Protocol.protocol_error() | :helper_unavailable | :helper_terminated}
  def request(identity, init_options, operation, params, timeout \\ @default_timeout_ms) do
    with {:ok, pid} <- ensure_started(identity),
         :ok <- GenServer.call(pid, {:initialize, init_options, timeout}, call_timeout(timeout)) do
      GenServer.call(pid, {:request, operation, params, timeout}, call_timeout(timeout))
    end
  catch
    :exit, _reason -> {:error, :helper_terminated}
  end

  @doc false
  @spec terminate(identity()) :: :ok
  def terminate(identity) do
    case Registry.lookup(Bourse.Signing.Lighter.Registry, identity) do
      [{pid, _value}] ->
        _ = DynamicSupervisor.terminate_child(WorkerSupervisor, pid)
        :ok

      [] ->
        :ok
    end
  end

  @doc """
  Reports the owning worker and its OS process id, for tests and operators that
  need to observe or terminate the helper. Returns `{:error, :not_running}` when
  no helper owns `identity`.
  """
  @spec helper_info(identity()) :: {:ok, %{pid: pid(), os_pid: non_neg_integer() | nil}} | {:error, :not_running}
  def helper_info(identity) do
    case Registry.lookup(Bourse.Signing.Lighter.Registry, identity) do
      [{pid, _value}] -> GenServer.call(pid, :helper_info)
      [] -> {:error, :not_running}
    end
  catch
    :exit, _reason -> {:error, :not_running}
  end

  @doc false
  @spec start_link(identity()) :: GenServer.on_start()
  def start_link(identity) do
    GenServer.start_link(__MODULE__, identity, name: via(identity))
  end

  @impl GenServer
  def init(identity) do
    Process.flag(:trap_exit, true)
    {:ok, %{identity: identity, port: nil, request_id: 0}}
  end

  @impl GenServer
  def handle_call({:initialize, _init_options, _timeout}, _from, %{port: port} = state) when is_port(port) do
    {:reply, :ok, state}
  end

  def handle_call({:initialize, init_options, timeout}, _from, state) do
    case open_helper(init_options) do
      {:ok, port} ->
        initialize_port(port, init_options, timeout, state)

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call({:request, operation, params, timeout}, _from, %{port: port} = state) when is_port(port) do
    request_id = next_request_id(state.request_id)

    case Protocol.encode_request(request_id, operation, params) do
      {:ok, frame} ->
        case transact(port, frame, operation, request_id, timeout) do
          {:ok, result} -> {:reply, {:ok, result}, %{state | request_id: request_id}}
          {:error, :helper_terminated} = error -> {:stop, :normal, error, state}
          {:error, reason} -> {:reply, {:error, reason}, %{state | request_id: request_id}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:request, _operation, _params, _timeout}, _from, state) do
    {:reply, {:error, :not_initialized}, state}
  end

  def handle_call(:helper_info, _from, state) do
    os_pid = if is_port(state.port), do: port_os_pid(state.port)
    {:reply, {:ok, %{pid: self(), os_pid: os_pid}}, state}
  end

  @impl GenServer
  def handle_info({port, {:exit_status, _status}}, %{port: port} = state), do: {:stop, :normal, state}

  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  catch
    :error, :badarg -> :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl GenServer
  def format_status(_status), do: %{state: :redacted}

  defp ensure_started(identity) do
    child_spec = %{
      id: {__MODULE__, identity},
      start: {__MODULE__, :start_link, [identity]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(WorkerSupervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} -> {:error, :helper_unavailable}
    end
  end

  defp encode_init(request_id, init_options) do
    Protocol.encode_init(
      request_id,
      init_options.url,
      init_options.private_key,
      init_options.chain_id,
      init_options.api_key_index,
      init_options.account_index
    )
  end

  defp initialize_port(port, init_options, timeout, state) do
    request_id = next_request_id(state.request_id)

    with {:ok, frame} <- encode_init(request_id, init_options),
         :ok <- transact(port, frame, :init, request_id, timeout) do
      {:reply, :ok, %{state | port: port, request_id: request_id}}
    else
      {:error, reason} ->
        close_port(port)
        {:stop, :normal, {:error, reason}, state}
    end
  end

  defp open_helper(init_options) do
    helper_path = init_options.helper_path
    helper_args = Map.get(init_options, :helper_args, [])

    if Path.type(helper_path) == :absolute and File.regular?(helper_path) do
      port_options = [
        :binary,
        {:packet, 2},
        :use_stdio,
        :exit_status,
        :hide,
        {:args, Enum.map(helper_args, &String.to_charlist/1)},
        {:env, scrubbed_environment()}
      ]

      {:ok, Port.open({:spawn_executable, String.to_charlist(helper_path)}, port_options)}
    else
      {:error, :helper_unavailable}
    end
  rescue
    ArgumentError -> {:error, :helper_unavailable}
  end

  defp transact(port, frame, operation, request_id, timeout) do
    if Port.command(port, frame) do
      receive do
        {^port, {:data, response}} -> Protocol.decode_response(response, operation, request_id)
        {^port, {:exit_status, _status}} -> {:error, :helper_terminated}
        {:EXIT, ^port, _reason} -> {:error, :helper_terminated}
      after
        timeout -> {:error, :helper_terminated}
      end
    else
      {:error, :helper_terminated}
    end
  catch
    :error, :badarg -> {:error, :helper_terminated}
  end

  defp scrubbed_environment do
    safe_path = safe_executable_path()

    removed =
      System.get_env()
      |> Map.keys()
      |> Enum.reject(&(String.upcase(&1) == "PATH"))
      |> Enum.map(&{String.to_charlist(&1), false})

    [{~c"PATH", safe_path} | removed]
  end

  defp safe_executable_path do
    erl_directory = "erl" |> System.find_executable() |> Path.dirname()

    case :os.type() do
      {:win32, _name} -> String.to_charlist(erl_directory)
      {:unix, _name} -> String.to_charlist(Enum.join([erl_directory, "/usr/bin", "/bin"], ":"))
    end
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  defp next_request_id(request_id), do: rem(request_id + 1, 0x100000000)

  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(timeout), do: timeout + @call_timeout_margin_ms

  defp via(identity), do: {:via, Registry, {Bourse.Signing.Lighter.Registry, identity}}
end
