defmodule Bourse.WS.ConnectionOwner.Supervisor do
  @moduledoc """
  Temporary DynamicSupervisor for `Bourse.WS.ConnectionOwner` processes.
  """

  use DynamicSupervisor

  alias Bourse.WS.ConnectionOwner
  alias ZenWebsocket.Client, as: ZenClient

  @doc "Starts the connection-owner supervisor."
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Starts a temporary owner holding `zen_client` at `url`."
  @spec start_owner(String.t(), ZenClient.t()) :: {:ok, pid()} | {:error, term()}
  def start_owner(url, zen_client) do
    DynamicSupervisor.start_child(__MODULE__, {ConnectionOwner, {url, zen_client}})
  end
end
