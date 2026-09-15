defmodule Bourse.WS.ControlFrame do
  @moduledoc """
  Classifies inbound WebSocket frames as market data or transport control.

  Heartbeat replies, JSON-RPC result/error envelopes without a notification
  method, and ping/pong keepalives are transport control. They must not be
  delivered as `{:websocket_message, _}` market-data events. Errors stay
  observable as `{:websocket_unmatched_response, _}`.
  """

  @type class :: :market | :control

  @doc "Returns `:control` for transport replies or `:market` for application data."
  @spec classify(term()) :: class()
  def classify(%{"method" => "subscription"}), do: :market
  def classify(%{"method" => method}) when method in ["heartbeat", "ping", "pong"], do: :control
  def classify(%{"error" => error}) when not is_nil(error), do: :control
  def classify(%{"result" => _}), do: :control
  def classify(%{"op" => op}) when op in ["ping", "pong"], do: :control
  def classify(%{"event" => event}) when event in ["ping", "pong"], do: :control
  def classify(%{"type" => type}) when type in ["ping", "pong"], do: :control

  def classify(frame) when is_binary(frame) do
    if String.downcase(String.trim(frame)) in ["ping", "pong"], do: :control, else: :market
  end

  def classify(_frame), do: :market
end
