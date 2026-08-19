defmodule Bourse.WS.SubscribeAck do
  @moduledoc """
  Classifies WebSocket subscribe acknowledgements and rejections.

  Venues deliver subscribe outcomes in two ways:

  1. **Correlated** (deribit JSON-RPC) — `ZenWebsocket.Client.send_message/2`
     returns `{:ok, envelope}` because the outbound frame carries an `id`.
  2. **Asynchronous** (alpaca, bybit, okx, hyperliquid, derive, binance,
     lighter) — send
     returns `:ok` and the venue reply arrives as
     `{:websocket_message, frame}` or `{:websocket_unmatched_response, frame}`
     (derive replies with a JSON-RPC envelope even when the request had no id).

  `Bourse.WS.subscribe/3` uses this module so both paths resolve to the same
  caller contract: `:ok` on accept, `{:error, {:subscription_rejected, frame}}`
  on reject.
  """

  @type classification :: :success | {:success, :data} | :not_ack | {:rejected, map()}

  @doc """
  Classifies a subscribe outcome frame for `exchange_id`.

  Returns:
  - `:success` — venue accepted the subscription
  - `{:success, :data}` — venue accepted, and the frame is also the first snapshot
    (re-queue after treating it as the acknowledgement)
  - `{:rejected, frame}` — venue rejected it (frame is the raw envelope)
  - `:not_ack` — not a subscribe outcome (data/heartbeat/other); leave in mailbox
  """
  @spec classify(String.t(), map() | [map()]) :: classification()
  def classify("alpaca", frames) when is_list(frames), do: classify_alpaca(frames)
  def classify("bybit", frame) when is_map(frame), do: classify_bybit(frame)
  def classify("okx", frame) when is_map(frame), do: classify_okx(frame)
  def classify("hyperliquid", frame) when is_map(frame), do: classify_hyperliquid(frame)
  def classify("derive", frame) when is_map(frame), do: classify_jsonrpc(frame)
  def classify("deribit", frame) when is_map(frame), do: classify_jsonrpc(frame)
  def classify("binance", frame) when is_map(frame), do: classify_binance(frame)
  def classify("binanceusdm", frame) when is_map(frame), do: classify_binance(frame)
  def classify("lighter", frame) when is_map(frame), do: classify_lighter(frame)
  def classify(exchange_id, frame) when is_binary(exchange_id) and is_map(frame), do: classify_generic(frame)

  @doc """
  Turns a classification into the public `subscribe/3` return value.

  A non-ack correlated reply is an unexpected protocol response, not evidence
  that the venue accepted the subscription.
  """
  @spec to_result(classification()) ::
          :ok | {:error, :unexpected_subscription_response | {:subscription_rejected, map()}}
  def to_result(:success), do: :ok
  def to_result({:success, :data}), do: :ok
  def to_result(:not_ack), do: {:error, :unexpected_subscription_response}
  def to_result({:rejected, frame}), do: {:error, {:subscription_rejected, frame}}

  # ---------------------------------------------------------------------------
  # Per-venue
  # ---------------------------------------------------------------------------

  # Alpaca batches every market-data event in a JSON array.
  defp classify_alpaca(frames) do
    case Enum.find(frames, &(&1["T"] in ["subscription", "error"])) do
      %{"T" => "subscription"} -> :success
      %{"T" => "error"} = frame -> {:rejected, frame}
      nil -> :not_ack
    end
  end

  # Bybit: %{"op" => "subscribe", "success" => true|false, "ret_msg" => ...}
  defp classify_bybit(%{"op" => "subscribe", "success" => false} = frame), do: {:rejected, frame}
  defp classify_bybit(%{"op" => "subscribe", "success" => true}), do: :success
  defp classify_bybit(%{"op" => "subscribe", "success" => "true"}), do: :success
  defp classify_bybit(%{"op" => "subscribe", "success" => "false"} = frame), do: {:rejected, frame}
  defp classify_bybit(_), do: :not_ack

  # OKX: %{"event" => "subscribe" | "error", ...}
  defp classify_okx(%{"event" => "error"} = frame), do: {:rejected, frame}
  defp classify_okx(%{"event" => "subscribe"}), do: :success
  defp classify_okx(_), do: :not_ack

  # Hyperliquid: channel "subscriptionResponse" | "error"
  defp classify_hyperliquid(%{"channel" => "error"} = frame), do: {:rejected, frame}
  defp classify_hyperliquid(%{"channel" => "subscriptionResponse"}), do: :success
  defp classify_hyperliquid(_), do: :not_ack

  # Derive / Deribit JSON-RPC envelopes
  defp classify_jsonrpc(%{"error" => error} = frame) when not is_nil(error), do: {:rejected, frame}

  # Deribit echoes the channels it actually subscribed to. A refusal is not an
  # error object — it is that list coming back empty, in an envelope otherwise
  # identical to success. Observed on test.deribit.com 2026-08-06: the same
  # `user.portfolio.btc` subscribe returns `"result" => []` unauthenticated and
  # `"result" => ["user.portfolio.btc"]` authenticated. Reading the first as
  # success is what turns a dead private stream into a green call.
  defp classify_jsonrpc(%{"result" => []} = frame), do: {:rejected, frame}
  defp classify_jsonrpc(%{"result" => _}), do: :success
  defp classify_jsonrpc(%{"jsonrpc" => _}), do: :not_ack
  defp classify_jsonrpc(_), do: :not_ack

  # Binance family: %{"id" => _, "result" => nil} on accept; error object on reject
  defp classify_binance(%{"error" => error} = frame) when not is_nil(error), do: {:rejected, frame}
  defp classify_binance(%{"result" => _}), do: :success
  defp classify_binance(_), do: :not_ack

  # Lighter's initial subscribed/* frame is both the acknowledgement and the
  # first public snapshot. Subsequent update/* frames are data, not acks.
  defp classify_lighter(%{"type" => "subscribed/" <> _}), do: {:success, :data}
  defp classify_lighter(%{"type" => "update/" <> _}), do: :not_ack
  defp classify_lighter(frame), do: classify_generic(frame)

  defp classify_generic(%{"success" => false} = frame), do: {:rejected, frame}
  defp classify_generic(%{"success" => true}), do: :success
  defp classify_generic(%{"error" => error} = frame) when is_map(error), do: {:rejected, frame}
  defp classify_generic(%{"event" => "error"} = frame), do: {:rejected, frame}
  defp classify_generic(%{"channel" => "error"} = frame), do: {:rejected, frame}
  defp classify_generic(_), do: :not_ack
end
