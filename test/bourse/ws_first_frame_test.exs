defmodule Bourse.WSFirstFrameTest do
  use ExUnit.Case, async: false

  alias Bourse.LiveLane.Bootstrap
  alias Bourse.LiveLane.FirstFrame
  alias Bourse.Spec
  alias Bourse.WS.Config

  defmodule StubWS do
    @moduledoc false

    def connect(exchange, :public), do: {:ok, exchange}

    def watch_ticker(exchange, _symbol, _opts) do
      send(self(), {:websocket_message, %{"topic" => "ticker", "data" => %{"last" => "1"}}})
      {:ok, %{channels: ["ticker:#{exchange.id}"]}}
    end

    def watch_trades(%{id: "coinbaseexchange"}, _symbol, _opts) do
      send(self(), {:websocket_message, coinbase_last_match()})
      {:ok, %{channels: ["ETH-USD"]}}
    end

    # The handle names the market the subscription actually resolved to — that is
    # what the lane attributes a frame against, so the stub cannot label the
    # channel after the venue while the payload names the market.
    def watch_trades(_exchange, _symbol, _opts) do
      send(self(), {:websocket_message, [%{"T" => "t", "S" => "FAKEPACA"}]})
      {:ok, %{channels: ["trades:FAKEPACA"]}}
    end

    def subscribe(%{id: "lighter"}, _channels, _opts) do
      send(self(), {:websocket_message, lighter_snapshot()})
      :ok
    end

    def subscribe(_exchange, channels, _opts) do
      send(self(), {:websocket_message, %{"channel" => List.first(channels), "data" => %{"value" => "1"}}})
      :ok
    end

    def close(_exchange), do: :ok

    defp lighter_snapshot do
      %{
        "type" => "subscribed/market_stats",
        "channel" => "market_stats:all",
        "market_stats" => %{"4095" => %{"market_id" => 4095}}
      }
    end

    defp coinbase_last_match do
      %{
        "type" => "last_match",
        "trade_id" => 842_900_890,
        "product_id" => "ETH-USD",
        "side" => "sell",
        "price" => "2497.85",
        "size" => "0.09718141",
        "time" => "2026-09-15T06:09:35.256006Z"
      }
    end
  end

  test "completeness covers every runtime venue on public and private WS surfaces" do
    assert :ok = FirstFrame.completeness_error()

    probed = MapSet.new(Enum.map(FirstFrame.probes(), & &1.venue))
    assert probed == MapSet.new(Config.supported_exchanges())

    public_excluded =
      FirstFrame.exclusions()
      |> Enum.filter(&(&1.surface == "ws_public"))
      |> MapSet.new(& &1.venue)

    private_excluded =
      FirstFrame.exclusions()
      |> Enum.filter(&(&1.surface == "ws_private"))
      |> MapSet.new(& &1.venue)

    runtime = MapSet.new(Spec.exchanges())
    assert MapSet.union(probed, public_excluded) == runtime
    assert private_excluded == runtime
  end

  test "every exclusion names why it cannot be probed and where it is tracked" do
    for %{venue: venue, surface: surface, reason: reason, tracking: tracking} <- FirstFrame.exclusions() do
      assert surface in ["ws_public", "ws_private"], "#{venue} exclusion surface is #{surface}"
      assert String.trim(reason) != "", "#{venue} #{surface} exclusion has no reason"
      assert tracking =~ ~r/task(?:s)? \d+/i, "#{venue} #{surface} exclusion has no task tracking reference"
    end
  end

  test "silence after connect fails and names the venue and channel" do
    assert {:error, report} =
             FirstFrame.run(
               timeout_ms: 20,
               connect: fn _spec -> {:ok, :stub} end,
               subscribe: fn _ws, spec -> {:ok, channel_name(spec)} end,
               close: fn _ws -> :ok end
             )

    bybit = Enum.find(report.venues, &(&1.venue == "bybit" and &1.status == "failed"))
    assert bybit.channel == "watch_ticker:BTC/USDT"
    assert bybit.reason =~ "bybit watch_ticker:BTC/USDT:"
    assert bybit.reason =~ "connected but received no frame"
    assert bybit.first_frame == nil
  end

  test "a subscribe acknowledgement without a data frame is silence, not coverage" do
    subscribe = fn _ws, spec ->
      if spec.venue == "bybit" do
        send(self(), {:websocket_message, %{"op" => "subscribe", "success" => true}})
      end

      {:ok, channel_name(spec)}
    end

    assert {:error, report} =
             FirstFrame.run(
               timeout_ms: 30,
               connect: fn _spec -> {:ok, :stub} end,
               subscribe: subscribe,
               close: fn _ws -> :ok end
             )

    bybit = Enum.find(report.venues, &(&1.venue == "bybit"))
    assert bybit.status == "failed"
    assert bybit.first_frame == "acknowledgement"
    assert bybit.data_frame == nil
    assert bybit.reason =~ "bybit watch_ticker:BTC/USDT:"
    assert bybit.reason =~ "connected but received no data frame"
  end

  test "a first frame that is an acknowledgement carrying payload is classified as such" do
    subscribe = fn _ws, spec ->
      if spec.venue == "lighter" do
        send(self(), {:websocket_message, lighter_snapshot()})
      else
        send_passed_frames(spec)
      end

      {:ok, channel_name(spec)}
    end

    assert {:ok, report} = run_classified(subscribe)
    lighter = Enum.find(report.venues, &(&1.venue == "lighter" and &1.status == "passed"))
    assert lighter.first_frame == "acknowledgement_with_payload"
    assert lighter.data_frame == "acknowledgement_with_payload"
    assert lighter.channel == "market_stats/all"
  end

  test "lighter's connection greeting does not count as market data" do
    for outcome <- [:snapshot, :rejected, :silent] do
      subscribe = fn _ws, spec ->
        if spec.venue == "lighter" do
          send(self(), {:websocket_message, %{"type" => "connected", "session_id" => "session"}})

          case outcome do
            :snapshot ->
              send(self(), {:websocket_message, lighter_snapshot()})

            :rejected ->
              send(self(), {:websocket_message, %{"error" => %{"code" => 30_005, "message" => "Invalid Channel"}}})

            :silent ->
              :ok
          end
        else
          send_passed_frames(spec)
        end

        {:ok, channel_name(spec)}
      end

      {status, report} = run_classified(subscribe)
      lighter = Enum.find(report.venues, &(&1.venue == "lighter"))

      case outcome do
        :snapshot ->
          assert status == :ok
          assert lighter.data_frame == "acknowledgement_with_payload"

        :rejected ->
          assert status == :error
          assert lighter.first_frame == "rejected"
          assert lighter.data_frame == nil

        :silent ->
          assert status == :error
          assert lighter.data_frame == nil
          assert lighter.reason =~ "received no frame"
      end
    end
  end

  test "a later data frame after a pure ack is classified separately from the acknowledgement" do
    subscribe = fn _ws, spec ->
      if spec.venue == "bybit" do
        send(self(), {:websocket_message, %{"op" => "subscribe", "success" => true}})
        send(self(), {:websocket_message, %{"topic" => "tickers.BTCUSDT", "data" => %{"lastPrice" => "1"}}})
      else
        send_passed_frames(spec)
      end

      {:ok, channel_name(spec)}
    end

    assert {:ok, report} = run_classified(subscribe)
    bybit = Enum.find(report.venues, &(&1.venue == "bybit" and &1.status == "passed"))
    assert bybit.first_frame == "acknowledgement"
    assert bybit.data_frame == "data"
  end

  test "subscription metadata is not a data frame" do
    subscribe = fn _ws, spec ->
      if spec.venue == "hyperliquid" do
        send(self(), {
          :websocket_message,
          %{
            "channel" => "subscriptionResponse",
            "data" => %{"method" => "subscribe", "subscription" => %{"type" => "allMids"}}
          }
        })
      else
        send_passed_frames(spec)
      end

      {:ok, channel_name(spec)}
    end

    assert {:error, report} = run_classified(subscribe)
    hyperliquid = Enum.find(report.venues, &(&1.venue == "hyperliquid" and &1.status == "failed"))
    assert hyperliquid.first_frame == "acknowledgement"
    assert hyperliquid.data_frame == nil
    assert hyperliquid.reason =~ "received no data frame"
  end

  test "a connection greeting that names no subscribed channel is not coverage" do
    # lighter greets every socket with this frame before any subscription is
    # resolved. It is neither a heartbeat nor a known ack shape, so the lane used
    # to classify it as data and report the venue green — while the venue was
    # rejecting the subscription behind it.
    subscribe = fn _ws, spec ->
      if spec.venue == "lighter" do
        send(self(), {:websocket_message, %{"type" => "connected"}})
      else
        send_passed_frames(spec)
      end

      {:ok, channel_name(spec)}
    end

    assert {:error, report} = run_classified(subscribe)
    lighter = Enum.find(report.venues, &(&1.venue == "lighter"))
    assert lighter.status == "failed"
    assert lighter.data_frame == nil
    assert lighter.reason =~ "none carried the subscribed channel"
  end

  test "a rejection arriving behind an unattributable frame is still the verdict" do
    subscribe = fn _ws, spec ->
      if spec.venue == "lighter" do
        send(self(), {:websocket_message, %{"type" => "connected"}})
        send(self(), {:websocket_message, %{"error" => %{"code" => 30_005, "message" => "Invalid Channel:  (marketId)"}}})
      else
        send_passed_frames(spec)
      end

      {:ok, channel_name(spec)}
    end

    assert {:error, report} = run_classified(subscribe)
    lighter = Enum.find(report.venues, &(&1.venue == "lighter"))
    assert lighter.status == "failed"
    assert lighter.first_frame == "rejected"
    assert lighter.reason =~ "30005" or lighter.reason =~ "30_005"
  end

  test "late frames from one venue cannot satisfy the next venue probe" do
    subscribe = fn _ws, spec ->
      cond do
        spec.venue == "alpaca" ->
          send_passed_frames(spec)
          send_passed_frames(spec)

        spec.venue == "binance" ->
          :ok

        true ->
          send_passed_frames(spec)
      end

      {:ok, channel_name(spec)}
    end

    assert {:error, report} = run_classified(subscribe)
    binance = Enum.find(report.venues, &(&1.venue == "binance" and &1.status == "failed"))
    assert binance.reason =~ "binance watch_ticker:BTC/USDT"
    assert binance.reason =~ "received no frame"
  end

  test "subscribe errors and skipped heartbeats still name the venue and channel" do
    subscribe = fn _ws, spec ->
      cond do
        spec.venue == "derive" ->
          {:error, :subscription_rejected}

        spec.venue == "okx" ->
          send(self(), {:websocket_message, "ping"})
          send(self(), {:ws_frame, %{"event" => "subscribe"}})

          send(
            self(),
            {:websocket_unmatched_response, %{"arg" => %{"channel" => "tickers"}, "data" => [%{"last" => "1"}]}}
          )

          {:ok, channel_name(spec)}

        true ->
          send_passed_frames(spec)
          {:ok, channel_name(spec)}
      end
    end

    assert {:error, report} =
             FirstFrame.run(
               timeout_ms: 50,
               connect: fn _spec -> {:ok, :stub} end,
               subscribe: subscribe,
               close: fn _ws -> :ok end
             )

    derive = Enum.find(report.venues, &(&1.venue == "derive"))
    assert derive.status == "failed"
    assert derive.reason =~ "derive"
    assert derive.reason =~ "subscription_rejected"

    okx = Enum.find(report.venues, &(&1.venue == "okx" and &1.status == "passed"))
    assert okx.first_frame == "acknowledgement"
    assert okx.data_frame == "data"
  end

  test "coinbaseexchange application heartbeats are skipped so last_match is the data frame" do
    subscribe = fn _ws, spec ->
      if spec.venue == "coinbaseexchange" do
        send(self(), {:websocket_message, %{"type" => "subscriptions", "channels" => []}})
        send(self(), {:websocket_message, %{"type" => "heartbeat", "last_trade_id" => 1, "sequence" => 1}})
        send(self(), {:websocket_message, coinbase_last_match()})
      else
        send_passed_frames(spec)
      end

      {:ok, channel_name(spec)}
    end

    assert {:ok, report} = run_classified(subscribe)
    coinbase = Enum.find(report.venues, &(&1.venue == "coinbaseexchange" and &1.status == "passed"))
    assert coinbase.first_frame == "acknowledgement"
    assert coinbase.data_frame == "data"
    assert coinbase.channel == "watch_trades:ETH/USD"
  end

  test "heartbeats are skipped and a rejected subscribe fails the named channel" do
    subscribe = fn _ws, spec ->
      if spec.venue == "okx" do
        send(self(), {:websocket_message, %{"event" => "ping"}})
        send(self(), {:websocket_message, %{"event" => "error", "code" => "60018", "msg" => "bad"}})
      else
        send_passed_frames(spec)
      end

      {:ok, channel_name(spec)}
    end

    assert {:error, report} =
             FirstFrame.run(
               timeout_ms: 50,
               connect: fn _spec -> {:ok, :stub} end,
               subscribe: subscribe,
               close: fn _ws -> :ok end
             )

    okx = Enum.find(report.venues, &(&1.venue == "okx"))
    assert okx.status == "failed"
    assert okx.first_frame == "rejected"
    assert okx.reason =~ "okx"
    assert okx.reason =~ "60018"
  end

  test "declared unreachable connect errors move out of failures" do
    assert {:ok, report} =
             FirstFrame.run(
               unreachable_ok: ["binance"],
               connect: fn
                 %{venue: "binance"} -> {:error, :network_error}
                 _spec -> {:ok, :stub}
               end,
               subscribe: fn _ws, spec ->
                 send_passed_frames(spec)
                 {:ok, channel_name(spec)}
               end,
               close: fn _ws -> :ok end,
               timeout_ms: 50
             )

    binance = Enum.find(report.venues, &(&1.venue == "binance" and &1.section == "public"))
    assert binance.status == "unreachable"
    assert report.failures == []
  end

  test "alpaca missing credentials fail the named public channel" do
    assert {:error, report} =
             FirstFrame.run(
               get_env: fn _variable -> nil end,
               timeout_ms: 20,
               ws_client: StubWS
             )

    alpaca = Enum.find(report.venues, &(&1.venue == "alpaca" and &1.status == "failed"))
    assert alpaca.reason =~ "alpaca"
    assert alpaca.reason =~ "missing_credentials"
  end

  test "default connection and subscription paths receive classified frames" do
    get_env = fn
      "ALPACA_API_KEY" -> "paper-key"
      "ALPACA_API_SECRET" -> "paper-secret"
    end

    assert {:ok, report} = FirstFrame.run(get_env: get_env, timeout_ms: 20, ws_client: StubWS)
    assert Enum.all?(report.venues, &(&1.status in ["passed", "excluded"]))
  end

  test "frame_kind distinguishes payload-bearing acks from connectivity" do
    assert FirstFrame.frame_kind({:success, :data}, lighter_snapshot()) == "acknowledgement_with_payload"
    assert FirstFrame.frame_kind(:not_ack, %{"topic" => "tickers.BTCUSDT"}) == "data"
    assert FirstFrame.frame_kind(:success, %{"op" => "subscribe", "success" => true}) == "acknowledgement"

    assert FirstFrame.frame_kind(:success, %{
             "channel" => "subscriptionResponse",
             "data" => %{"method" => "subscribe"}
           }) == "acknowledgement"
  end

  test "bootstrap starts the WebSocket lane processes" do
    test_process = self()

    ensure_started = fn application ->
      send(test_process, {:application, application})
      {:ok, [application]}
    end

    start_supervisor = fn children ->
      send(test_process, {:children, children})

      {:ok,
       spawn(fn ->
         receive do
           :stop -> :ok
         end
       end)}
    end

    pid =
      Bootstrap.start!(
        ensure_started: ensure_started,
        start_supervisor: start_supervisor
      )

    assert_receive {:application, :ssl}
    assert_receive {:application, :crypto}
    assert_receive {:application, :jason}
    assert_receive {:application, :zen_websocket}

    assert_receive {:children, children}

    assert Enum.map(children, &child_name/1) == [
             Bourse.WS.Broadcast.Registry,
             Bourse.WS.ConnectionOwner.Supervisor
           ]

    send(pid, :stop)
  end

  test "the first-frame mix target boots app.config and never starts the complete application" do
    source = File.read!("lib/mix/tasks/bourse.verify_ws_first_frame.ex")
    assert source =~ ~s|Mix.Task.run("app.config")|
    refute source =~ ~s|Mix.Task.run("app.start")|
    refute source =~ "Application.ensure_all_started(:bourse)"

    refute File.read!("mix.exs") =~ ~s("bourse.verify_ws_first_frame")
  end

  defp run_classified(subscribe) do
    FirstFrame.run(
      timeout_ms: 50,
      connect: fn _spec -> {:ok, :stub} end,
      subscribe: subscribe,
      close: fn _ws -> :ok end
    )
  end

  defp send_passed_frames(%{venue: "lighter"}) do
    send(self(), {:websocket_message, lighter_snapshot()})
  end

  defp send_passed_frames(%{venue: "coinbaseexchange"}) do
    send(self(), {:websocket_message, coinbase_last_match()})
  end

  # The lane only counts a frame that carries the channel the probe subscribed,
  # so the stub payload has to name that channel rather than one fixed topic —
  # a venue-agnostic frame is exactly what a connection greeting looks like.
  defp send_passed_frames(spec) do
    send(self(), {:websocket_message, %{"topic" => channel_name(spec), "data" => %{"lastPrice" => "1"}}})
  end

  defp coinbase_last_match do
    %{
      "type" => "last_match",
      "trade_id" => 842_900_890,
      "product_id" => "ETH-USD",
      "side" => "sell",
      "price" => "2497.85",
      "size" => "0.09718141",
      "time" => "2026-09-15T06:09:35.256006Z"
    }
  end

  defp lighter_snapshot do
    %{
      "type" => "subscribed/market_stats",
      "channel" => "market_stats:all",
      "market_stats" => %{"4095" => %{"market_id" => 4095}}
    }
  end

  defp channel_name(%{channels: [channel | _]}) when is_binary(channel), do: channel
  defp channel_name(%{channels: [channel | _]}) when is_map(channel), do: inspect(channel)
  defp channel_name(%{watch: watch, symbol: symbol}), do: "#{watch}:#{symbol}"

  defp child_name(%{id: id}), do: id
  defp child_name({id, _start, _restart, _shutdown, _type, _modules}), do: id
  defp child_name(module) when is_atom(module), do: module
  defp child_name(_other), do: nil

  # The REST-read report is an ExUnit report whose test names are the contract
  # case ids (`venue:method:index:provider_operation`), which is how the lane
  # attributes a case to a venue.
end
