defmodule Bourse.WS.ConnectionOwner do
  @moduledoc """
  Holds the routed-host WebSocket clients for one `Bourse.WS` connection.

  This process links each client it records. Stopping or crashing it closes
  every socket it still holds, so a dead owner cannot leave an unreachable
  routed host.
  """

  use GenServer

  alias ZenWebsocket.Client, as: ZenClient

  @doc "Starts an unlinked owner holding `zen_client` at `url`."
  @spec start(String.t(), ZenClient.t()) :: {:ok, pid()} | {:error, term()}
  def start(url, zen_client) do
    GenServer.start(__MODULE__, {url, zen_client})
  end

  @doc "Returns the client for `url`, connecting through `connect_fun` when it is new."
  @spec checkout(
          pid(),
          (String.t(), keyword() -> {:ok, ZenClient.t()} | {:error, term()}),
          String.t(),
          keyword(),
          timeout()
        ) :: {:ok, ZenClient.t()} | {:error, term()}
  def checkout(owner, connect_fun, url, opts, timeout) do
    GenServer.call(owner, {:checkout, connect_fun, url, opts}, timeout)
  end

  @doc "Removes and returns every held client so the caller can close them."
  @spec take(pid(), timeout()) :: {:ok, [ZenClient.t()]} | {:error, term()}
  def take(owner, timeout) do
    GenServer.call(owner, :take, timeout)
  end

  @doc "Stops the owner. Remaining clients are closed from `terminate/2`."
  @spec stop(pid(), timeout()) :: :ok
  def stop(owner, timeout) do
    GenServer.stop(owner, :normal, timeout)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init({url, zen_client}) do
    Process.flag(:trap_exit, true)
    link_client(zen_client)
    {:ok, %{closed?: false, connections: %{url => zen_client}}}
  end

  @impl true
  def handle_call({:checkout, _connect_fun, _url, _opts}, _from, %{closed?: true} = state) do
    {:reply, {:error, :connection_closed}, state}
  end

  def handle_call({:checkout, connect_fun, url, opts}, _from, state) do
    case Map.fetch(state.connections, url) do
      {:ok, zen_client} -> {:reply, {:ok, zen_client}, state}
      :error -> connect_and_store(state, connect_fun, url, opts)
    end
  end

  def handle_call(:take, _from, state) do
    clients = state.connections |> Map.values() |> Enum.uniq()
    {:reply, {:ok, clients}, %{state | closed?: true, connections: %{}}}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, state) do
    {:noreply, %{state | connections: drop_client(state.connections, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state.connections
    |> Map.values()
    |> Enum.uniq()
    |> Enum.each(&close_client/1)
  end

  defp connect_and_store(state, connect_fun, url, opts) do
    case connect_fun.(url, opts) do
      {:ok, zen_client} ->
        link_client(zen_client)
        {:reply, {:ok, zen_client}, %{state | connections: Map.put(state.connections, url, zen_client)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp drop_client(connections, pid) do
    connections
    |> Enum.reject(fn {_url, client} -> client_pid(client) == pid end)
    |> Map.new()
  end

  defp link_client(client) do
    case client_pid(client) do
      pid when is_pid(pid) -> Process.link(pid)
      _ -> :ok
    end
  end

  defp client_pid(%{server_pid: pid}), do: pid
  defp client_pid(_client), do: nil

  defp close_client(client) do
    ZenClient.close(client)
  catch
    :exit, _reason -> :ok
  end
end
