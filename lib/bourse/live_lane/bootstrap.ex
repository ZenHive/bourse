defmodule Bourse.LiveLane.Bootstrap do
  @moduledoc """
  Starts the processes the live lane needs beyond REST drift.

  Adds WebSocket transport (`zen_websocket`) plus the Broadcast registry and
  connection-owner supervisor so first-frame probes can follow authored host
  routing.
  """

  alias Bourse.LiveDrift.Bootstrap, as: DriftBootstrap
  alias Bourse.WS.Broadcast
  alias Bourse.WS.ConnectionOwner.Supervisor, as: OwnerSupervisor

  @ws_applications [:ssl, :crypto, :jason, :zen_websocket]
  @ws_children [Broadcast.child_spec(), OwnerSupervisor]

  @type option ::
          {:ensure_started, (atom() -> {:ok, [atom()]} | {:error, term()})}
          | {:start_supervisor, ([term()] -> Supervisor.on_start())}

  @doc "Starts REST drift processes, then the WebSocket lane processes."
  @spec start!([option()]) :: pid()
  def start!(opts \\ []) do
    DriftBootstrap.start!(Keyword.take(opts, [:ensure_started, :start_supervisor]))
    ensure_started = Keyword.get(opts, :ensure_started, &Application.ensure_all_started/1)
    start_supervisor = Keyword.get(opts, :start_supervisor, &start_supervisor/1)

    Enum.each(@ws_applications, fn application ->
      case ensure_started.(application) do
        {:ok, _applications} -> :ok
        {:error, reason} -> raise "failed to start #{application}: #{inspect(reason)}"
      end
    end)

    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        pid

      nil ->
        case start_supervisor.(@ws_children) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
          {:error, reason} -> raise "failed to start live lane WebSocket processes: #{inspect(reason)}"
        end
    end
  end

  defp start_supervisor(children) do
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
