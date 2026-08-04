defmodule Bourse.Signing.Lighter.Supervisor do
  @moduledoc """
  Supervises isolated, temporary Lighter signer owners.

  Each child owns exactly one API signing key and its external OS process.
  Children are temporary so terminating one is the key-removal boundary.
  """

  use Supervisor

  @doc false
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: Bourse.Signing.Lighter.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Bourse.Signing.Lighter.WorkerSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
