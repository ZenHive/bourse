defmodule Bourse.WS.SubscribeAck do
  @moduledoc """
  Classifies WebSocket subscribe acknowledgements and rejections.

  Venues deliver subscribe outcomes in two ways:

  1. **Correlated** (deribit JSON-RPC) — `ZenWebsocket.Client.send_message/2`
     returns `{:ok, envelope}` because the outbound frame carries an `id`.
  2. **Asynchronous** (alpaca, bybit, okx, hyperliquid, derive, binance,
     lighter, coinbaseexchange) — send
     returns `:ok` and the venue reply arrives as
     `{:websocket_message, frame}` or `{:websocket_unmatched_response, frame}`
     (derive replies with a JSON-RPC envelope even when the request had no id).

  `Bourse.WS.subscribe/3` uses this module so both paths resolve to the same
  caller contract: `:ok` on accept, `{:error, {:subscription_rejected, frame}}`
  on reject.
  """

  alias Bourse.WS.Subscription.MethodSubscription

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
  def classify("coinbaseexchange", frame) when is_map(frame), do: classify_coinbase(frame)
  def classify(exchange_id, frame) when is_binary(exchange_id) and is_map(frame), do: classify_generic(frame)

  @doc """
  Classifies a frame as the outcome of subscribing `channels`.

  Hyperliquid answers each subscribe with the subscription it accepted
  (`data.subscription`, observed on api.hyperliquid-testnet.xyz 2026-11-25), so
  an acceptance of some other subscription — a late reply to an earlier call —
  is not this call's outcome. Every other venue is classified as by `classify/2`.
  """
  @spec classify(String.t(), map() | [map()], [String.t() | map()]) :: classification()
  def classify("hyperliquid", %{"channel" => "subscriptionResponse", "data" => data} = frame, channels) do
    case data do
      %{"method" => "subscribe", "subscription" => %{} = echoed} ->
        if same_hyperliquid_subscription?(echoed, wire_subscription(channels)), do: :success, else: :not_ack

      _ ->
        "hyperliquid" |> classify(frame) |> unconfirmed()
    end
  end

  def classify(exchange_id, frame, _channels), do: classify(exchange_id, frame)

  defp unconfirmed(:success), do: :not_ack
  defp unconfirmed(other), do: other

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

  @doc """
  The channels of a refused subscribe that the refusal reports as already
  subscribed on this connection; any channel not returned may not be active.
  Replies observed 2026-11-25: bybit `ret_msg: "error:already subscribed,topic:<topic>"`
  (api-testnet), which names only the first already-subscribed topic of the
  request and subscribes none of its other topics, and hyperliquid
  `"Already subscribed: <subscription JSON>"` (testnet), whose JSON echoes the
  request with its omitted optional fields at their defaults. No other venue's
  refusal is read this way.
  """
  @spec already_subscribed(String.t(), map(), [String.t() | map()]) :: [String.t() | map()]
  def already_subscribed("bybit", %{"ret_msg" => "error:already subscribed,topic:" <> topics}, channels) do
    named = String.split(topics, ",")
    Enum.filter(channels, &(&1 in named))
  end

  def already_subscribed("hyperliquid", %{"channel" => "error", "data" => "Already subscribed: " <> json}, channels) do
    with {:ok, %{} = echoed} <- Jason.decode(json),
         true <- same_hyperliquid_subscription?(echoed, wire_subscription(channels)) do
      channels
    else
      _ -> []
    end
  end

  def already_subscribed(_exchange_id, _frame, _channels), do: []

  # The echo fills every optional field the request left out with its default
  # (`"nSigFigs": null, "mantissa": null, "fast": false` on l2Book); a field set
  # to anything else names a different subscription.
  defp same_hyperliquid_subscription?(echoed, %{} = sent) do
    Enum.all?(echoed, fn {field, value} ->
      if Map.has_key?(sent, field), do: sent[field] == value, else: value in [nil, false]
    end) and Enum.all?(sent, fn {field, _} -> Map.has_key?(echoed, field) end)
  end

  defp same_hyperliquid_subscription?(_echoed, _sent), do: false

  # The subscription object exactly as the subscribe frame carries it on the
  # wire: built by the venue's frame builder, then JSON-encoded, so a string
  # channel and atom keys compare as the venue sees them.
  defp wire_subscription(channels) do
    case MethodSubscription.subscribe(channels, %{}) do
      %{"subscription" => subscription} -> subscription |> Jason.encode!() |> Jason.decode!()
      _ -> nil
    end
  end

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

  # Hyperliquid: channel "subscriptionResponse" | "error". An unsubscribe is
  # answered on the same channel with `data.method` "unsubscribe" (observed on
  # api.hyperliquid-testnet.xyz 2026-11-25); it is not this subscribe's outcome.
  defp classify_hyperliquid(%{"channel" => "error"} = frame), do: {:rejected, frame}
  defp classify_hyperliquid(%{"channel" => "subscriptionResponse", "data" => %{"method" => "unsubscribe"}}), do: :not_ack
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
  defp classify_jsonrpc(%{"result" => result}) when is_list(result), do: :success
  defp classify_jsonrpc(%{"result" => %{"status" => _}}), do: :success
  defp classify_jsonrpc(%{"jsonrpc" => _}), do: :not_ack
  defp classify_jsonrpc(_), do: :not_ack

  # Binance family: %{"id" => _, "result" => nil} on accept; error object on reject
  defp classify_binance(%{"error" => error} = frame) when not is_nil(error), do: {:rejected, frame}
  defp classify_binance(%{"result" => _}), do: :success
  defp classify_binance(_), do: :not_ack

  # Coinbase Exchange: `type: "subscriptions"` is the ack; `type: "error"`
  # with `reason: "<channel> is not a valid channel"` is the rejection.
  # last_match / match / heartbeat are data, not acks — last_match is the
  # historical snapshot and must not be treated as a subscribe success that
  # swallows the frame.
  defp classify_coinbase(%{"type" => "subscriptions"}), do: :success
  defp classify_coinbase(%{"type" => "error"} = frame), do: {:rejected, frame}
  defp classify_coinbase(_frame), do: :not_ack

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
