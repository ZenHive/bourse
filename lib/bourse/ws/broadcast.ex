defmodule Bourse.WS.Broadcast do
  @moduledoc """
  Registry-backed fan-out for routed WS adapter messages.
  """

  @registry Bourse.WS.Broadcast.Registry

  @type topic :: {String.t(), atom(), String.t() | nil}

  @doc "Child spec for the duplicate-key Registry."
  @spec child_spec() :: Supervisor.child_spec()
  def child_spec do
    %{
      id: @registry,
      start: {Registry, :start_link, [[name: @registry, keys: :duplicate]]}
    }
  end

  @doc "Registers the calling process for a topic."
  @spec subscribe(topic()) :: :ok
  def subscribe(topic) do
    Registry.register(@registry, topic, [])
    :ok
  end

  @doc "Unregisters the calling process from a topic."
  @spec unsubscribe(topic()) :: :ok
  def unsubscribe(topic) do
    Registry.unregister_match(@registry, topic, self())
    :ok
  end

  @doc "Dispatches a message to all subscribers of a topic."
  @spec broadcast(topic(), term()) :: :ok
  def broadcast(topic, message) do
    Registry.dispatch(@registry, topic, fn entries ->
      for {pid, _} <- entries, do: send(pid, message)
    end)

    :ok
  end

  @doc "Builds a broadcast topic from exchange id, family, and optional channel."
  @spec topic(String.t(), atom(), String.t() | nil) :: topic()
  def topic(exchange_id, family, channel \\ nil), do: {exchange_id, family, channel}
end
