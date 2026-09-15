defmodule Bourse.WS.Heartbeat do
  @moduledoc """
  Heartbeat configuration the locked `zen_websocket` 0.9.0 can actually run.

  Only `:deribit` and `:ping_pong` send anything. Other types are silent no-ops
  in the dependency, so Bourse refuses them at connect rather than pretending a
  timer is liveness. JSON/string application pings stay `:disabled` until the
  dependency can send those payloads.
  """

  @supported_types [:deribit, :ping_pong]

  @type config :: :disabled | %{:type => :deribit | :ping_pong, optional(:interval) => pos_integer()}

  @doc "Heartbeat types `zen_websocket` 0.9.0 will send."
  @spec supported_types() :: [:deribit | :ping_pong]
  def supported_types, do: @supported_types

  @doc """
  Accepts a dependency-supported heartbeat or `:disabled`.

  Returns `{:error, {:unsupported_heartbeat, type}}` for `:ping`, `:custom`, and
  any other type the locked dependency would no-op.
  """
  @spec validate(term()) :: :ok | {:error, {:unsupported_heartbeat, term()}}
  def validate(:disabled), do: :ok
  def validate(%{type: type}) when type in @supported_types, do: :ok
  def validate(%{"type" => type}) when type in @supported_types, do: :ok

  def validate(%{type: type}), do: {:error, {:unsupported_heartbeat, type}}
  def validate(%{"type" => type}), do: {:error, {:unsupported_heartbeat, type}}
  def validate(other), do: {:error, {:unsupported_heartbeat, other}}
end
