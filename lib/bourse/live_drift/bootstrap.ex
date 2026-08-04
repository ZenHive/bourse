defmodule Bourse.LiveDrift.Bootstrap do
  @moduledoc """
  Starts the dependency applications and supervised processes used by live drift reads.

  It deliberately excludes `Bourse.Application`, the testnet registry, and
  WebSocket processes.
  """

  @required_applications [:req, :fuse]
  @children [
    Bourse.RateLimiter,
    Bourse.RateLimiter.State,
    Bourse.Signing.Lighter.Supervisor
  ]

  @type child_spec_input :: module() | {module(), term()} | Supervisor.child_spec()
  @type option ::
          {:ensure_started, (atom() -> {:ok, [atom()]} | {:error, term()})}
          | {:start_supervisor, ([child_spec_input()] -> Supervisor.on_start())}

  @doc "Starts the minimal live-read runtime and returns its supervisor."
  @spec start!([option()]) :: pid()
  def start!(opts \\ []) do
    ensure_started = Keyword.get(opts, :ensure_started, &Application.ensure_all_started/1)
    start_supervisor = Keyword.get(opts, :start_supervisor, &start_supervisor/1)

    Enum.each(@required_applications, fn application ->
      case ensure_started.(application) do
        {:ok, _applications} -> :ok
        {:error, reason} -> raise "failed to start #{application}: #{inspect(reason)}"
      end
    end)

    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        pid

      nil ->
        case start_supervisor.(@children) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
          {:error, reason} -> raise "failed to start live drift processes: #{inspect(reason)}"
        end
    end
  end

  defp start_supervisor(children) do
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
