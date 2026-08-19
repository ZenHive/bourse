defmodule Bourse.LiveLane.FirstFrame do
  @moduledoc """
  Classified public WebSocket first-frame probes for the scheduled live lane.

  Subscribe acknowledgements are not coverage. A connection that stays silent
  after a bounded wait fails and names the venue and channel. An acknowledgement
  that also carries the first snapshot is reported as such, not as connectivity.
  """

  alias Bourse.Credentials
  alias Bourse.Exchange
  alias Bourse.Spec
  alias Bourse.WS
  alias Bourse.WS.Config
  alias Bourse.WS.SubscribeAck

  @timeout_ms 15_000

  @type probe :: %{
          required(:sandbox) => boolean(),
          required(:section) => :public,
          required(:venue) => String.t(),
          optional(:channels) => [String.t() | map()],
          optional(:credentials) => boolean(),
          optional(:symbol) => String.t(),
          optional(:watch) => atom()
        }

  @type exclusion :: %{
          required(:reason) => String.t(),
          required(:surface) => String.t(),
          required(:tracking) => String.t(),
          required(:venue) => String.t()
        }

  @probes [
    %{venue: "alpaca", section: :public, watch: :watch_trades, symbol: "FAKEPACA", sandbox: true, credentials: true},
    %{venue: "binance", section: :public, watch: :watch_ticker, symbol: "BTC/USDT", sandbox: true, credentials: false},
    %{
      venue: "binancecoinm",
      section: :public,
      watch: :watch_ticker,
      symbol: "BTC/USD:BTC",
      sandbox: true,
      credentials: false
    },
    %{
      venue: "binanceusdm",
      section: :public,
      watch: :watch_ticker,
      symbol: "BTC/USDT",
      sandbox: true,
      credentials: false
    },
    %{venue: "bybit", section: :public, watch: :watch_ticker, symbol: "BTC/USDT", sandbox: true, credentials: false},
    %{
      venue: "deribit",
      section: :public,
      watch: :watch_ticker,
      symbol: "BTC/USD:BTC",
      sandbox: true,
      credentials: false
    },
    %{
      venue: "derive",
      section: :public,
      watch: :watch_ticker,
      symbol: "ETH/USD:USDC",
      sandbox: true,
      credentials: false
    },
    %{venue: "hyperliquid", section: :public, channels: ["allMids"], sandbox: true, credentials: false},
    %{venue: "lighter", section: :public, channels: ["market_stats/0"], sandbox: true, credentials: false},
    %{
      venue: "okx",
      section: :public,
      channels: [%{"channel" => "tickers", "instId" => "BTC-USDT"}],
      sandbox: true,
      credentials: false
    }
  ]

  @exclusions [
    %{
      venue: "coinbaseexchange",
      surface: "ws_public",
      reason: "runtime venue without a WebSocket config; connect/3 answers :websocket_not_configured",
      tracking: "Bourse.WS.Config.registered_divergences — task 544"
    },
    %{
      venue: "coinbaseexchange",
      surface: "ws_private",
      reason: "runtime venue without a WebSocket config; connect/3 answers :websocket_not_configured",
      tracking: "Bourse.WS.Config.registered_divergences — task 544"
    },
    %{
      venue: "alpaca",
      surface: "ws_private",
      reason: "authored private WS URL is nil; market-data handshake lives on the public section",
      tracking: "lib/bourse/ws/spec_config.ex alpaca hand base — task 544"
    },
    %{
      venue: "hyperliquid",
      surface: "ws_private",
      reason: "authored private WS URL is nil; private subscriptions are scoped by address, not a login",
      tracking: "lib/bourse/ws/spec_config.ex hyperliquid hand base — task 544"
    },
    %{
      venue: "lighter",
      surface: "ws_private",
      reason: "authored private WS URL is nil; the public stream is the configured transport",
      tracking: "lib/bourse/ws/spec_config.ex lighter hand base — task 544"
    },
    %{
      venue: "binance",
      surface: "ws_private",
      reason:
        "user-data stream emits only on account events; handshake and bad-secret rejection " <>
          "are covered by auth_live_smoke",
      tracking: "test/bourse/ws/auth_live_smoke_test.exs — task 650"
    },
    %{
      venue: "binanceusdm",
      surface: "ws_private",
      reason:
        "listen-key private route is silent until an account event; a wrong key still reports " <>
          "connected. Covered by the auth_live_smoke ORDER_TRADE_UPDATE probe",
      tracking: "test/bourse/ws/auth_live_smoke_test.exs — task 643"
    },
    %{
      venue: "binancecoinm",
      surface: "ws_private",
      reason:
        "listen-key private route is silent until an account event; a wrong key still reports " <>
          "connected. Covered by the auth_live_smoke ORDER_TRADE_UPDATE probe",
      tracking: "test/bourse/ws/auth_live_smoke_test.exs — task 643"
    },
    %{
      venue: "bybit",
      surface: "ws_private",
      reason:
        "private order channel is idle without account events; differential handshake is covered by auth_live_smoke",
      tracking: "test/bourse/ws/auth_live_smoke_test.exs — task 650"
    },
    %{
      venue: "deribit",
      surface: "ws_private",
      reason:
        "private user channels are idle without account events; differential handshake is covered by auth_live_smoke",
      tracking: "test/bourse/ws/auth_live_smoke_test.exs — task 650"
    },
    %{
      venue: "derive",
      surface: "ws_private",
      reason: "no authored auth_pattern; private section has no handshake and no scheduled first-frame channel",
      tracking: "CLAUDE.md WebSocket derive auth_pattern gap — task 650"
    },
    %{
      venue: "okx",
      surface: "ws_private",
      reason:
        "private orders channel is idle without account events; differential handshake is covered by auth_live_smoke",
      tracking: "test/bourse/ws/auth_live_smoke_test.exs — task 650"
    }
  ]

  @type option ::
          {:close, (term() -> term())}
          | {:connect, (probe() -> {:ok, term()} | {:error, term()})}
          | {:get_env, (String.t() -> String.t() | nil)}
          | {:probe, (probe() -> {:ok, map()} | {:error, map()})}
          | {:subscribe, (term(), probe() -> {:ok, String.t()} | {:error, term()})}
          | {:timeout_ms, pos_integer()}
          | {:unreachable_ok, [String.t()]}
          | {:ws_client, module()}

  @doc "Public first-frame probes, one per WebSocket-configured venue."
  @spec probes() :: [probe()]
  def probes, do: @probes

  @doc "Registered reasons for venues or WS sections this matrix does not probe."
  @spec exclusions() :: [exclusion()]
  def exclusions, do: @exclusions

  @doc "Runs every public first-frame probe and returns a scrubbed report."
  @spec run([option()]) :: {:ok, map()} | {:error, map()}
  def run(opts \\ []) do
    probe = Keyword.get(opts, :probe, &live_probe(&1, opts))
    unreachable_ok = Keyword.get_lazy(opts, :unreachable_ok, &unreachable_ok_from_env/0)

    {venues, failures} = Enum.reduce(@probes, {[], []}, &record_probe(&1, &2, probe, unreachable_ok))

    report = %{
      exclusions: @exclusions,
      failures: Enum.reverse(failures),
      status: if(failures == [], do: "passed", else: "failed"),
      timeout_ms: Keyword.get(opts, :timeout_ms, @timeout_ms),
      venues: Enum.reverse(venues, exclusion_rows())
    }

    if report.failures == [], do: {:ok, report}, else: {:error, report}
  end

  @doc "Asserts every runtime venue has a public first-frame probe or a registered exclusion."
  @spec completeness_error() :: :ok | {:error, map()}
  def completeness_error do
    runtime = MapSet.new(Spec.exchanges())
    supported = MapSet.new(Config.supported_exchanges())
    probed = MapSet.new(Enum.map(@probes, & &1.venue))
    public_excluded = excluded_venues("ws_public")
    private_excluded = excluded_venues("ws_private")

    cond do
      probed != supported ->
        {:error, %{kind: :probe_set, actual: MapSet.to_list(probed), expected: MapSet.to_list(supported)}}

      MapSet.union(probed, public_excluded) != runtime ->
        {:error,
         %{
           kind: :public_coverage,
           actual: MapSet.to_list(MapSet.union(probed, public_excluded)),
           expected: MapSet.to_list(runtime)
         }}

      private_excluded != runtime ->
        {:error,
         %{
           kind: :private_coverage,
           actual: MapSet.to_list(private_excluded),
           expected: MapSet.to_list(runtime)
         }}

      true ->
        :ok
    end
  end

  @doc "Turns a subscribe-ack classification plus the raw frame into the lane vocabulary."
  @spec frame_kind(SubscribeAck.classification(), map() | [map()]) :: String.t()
  def frame_kind({:success, :data}, _frame), do: "acknowledgement_with_payload"
  def frame_kind(:not_ack, _frame), do: "data"
  def frame_kind({:rejected, _rejected}, _frame), do: "rejected"
  def frame_kind(:success, _frame), do: "acknowledgement"

  defp record_probe(spec, {venues, failures}, probe, unreachable_ok) do
    result =
      fn -> probe.(spec) end
      |> Task.async()
      |> Task.await(:infinity)

    case result do
      {:ok, row} ->
        {[row | venues], failures}

      {:error, row} ->
        record_error(spec.venue, row, venues, failures, unreachable_ok)
    end
  end

  defp record_error(venue, row, venues, failures, unreachable_ok) do
    if venue in unreachable_ok and unreachable_row?(row) do
      {[%{row | status: "unreachable"} | venues], failures}
    else
      {[row | venues], [row | failures]}
    end
  end

  defp exclusion_rows do
    Enum.map(@exclusions, fn exclusion ->
      %{
        channel: nil,
        data_frame: nil,
        first_frame: nil,
        reason: exclusion.reason,
        section: section_from_surface(exclusion.surface),
        status: "excluded",
        tracking: exclusion.tracking,
        venue: exclusion.venue
      }
    end)
  end

  defp excluded_venues(surface) do
    @exclusions
    |> Enum.filter(&(&1.surface == surface))
    |> MapSet.new(& &1.venue)
  end

  defp section_from_surface("ws_private"), do: "private"
  defp section_from_surface(_surface), do: "public"

  defp live_probe(spec, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @timeout_ms)
    get_env = Keyword.get(opts, :get_env, &System.get_env/1)
    ws_client = Keyword.get(opts, :ws_client, WS)
    connect = Keyword.get(opts, :connect, &default_connect(&1, get_env, ws_client))
    subscribe = Keyword.get(opts, :subscribe, &default_subscribe(&1, &2, ws_client))
    close = Keyword.get(opts, :close, &default_close(&1, ws_client))

    case connect.(spec) do
      {:ok, ws} -> probe_open_socket(ws, spec, timeout_ms, subscribe, close)
      {:error, reason} -> {:error, failure_row(spec, channel_label(spec), inspect(reason))}
    end
  end

  defp probe_open_socket(ws, spec, timeout_ms, subscribe, close) do
    case subscribe.(ws, spec) do
      {:ok, channel} -> await_classified_frames(spec.venue, channel, timeout_ms)
      {:error, reason} -> {:error, failure_row(spec, channel_label(spec), inspect(reason))}
    end
  after
    close.(ws)
  end

  defp default_connect(spec, get_env, ws_client) do
    with {:ok, exchange} <- build_exchange(spec, get_env) do
      ws_client.connect(exchange, :public)
    end
  end

  defp default_close(ws, ws_client), do: ws_client.close(ws)

  defp build_exchange(%{credentials: true} = spec, get_env) do
    case alpaca_credentials(get_env) do
      {:ok, credentials} -> {:ok, Exchange.new!(spec.venue, credentials: credentials, sandbox: spec.sandbox)}
      {:error, _} = error -> error
    end
  end

  defp build_exchange(spec, _get_env) do
    {:ok, Exchange.new!(spec.venue, sandbox: spec.sandbox)}
  end

  defp alpaca_credentials(get_env) do
    api_key = get_env.("ALPACA_API_KEY")
    secret = get_env.("ALPACA_API_SECRET")

    if present?(api_key) and present?(secret) do
      Credentials.new(api_key: api_key, secret: secret, sandbox: true)
    else
      {:error, :missing_credentials}
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp default_subscribe(ws, %{watch: :watch_ticker, symbol: symbol}, ws_client) do
    watch_result(ws_client.watch_ticker(ws, symbol, ack_timeout_ms: 0))
  end

  defp default_subscribe(ws, %{watch: :watch_trades, symbol: symbol}, ws_client) do
    watch_result(ws_client.watch_trades(ws, symbol, ack_timeout_ms: 0))
  end

  defp default_subscribe(ws, %{channels: channels}, ws_client) do
    case ws_client.subscribe(ws, channels, ack_timeout_ms: 0) do
      :ok -> {:ok, channel_label(%{channels: channels})}
      {:error, _} = error -> error
    end
  end

  defp watch_result({:ok, handle}), do: {:ok, channel_label_from_handle(handle)}
  defp watch_result({:error, _} = error), do: error

  defp await_classified_frames(venue, channel, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case await_frame(venue, deadline, :none) do
      :timeout ->
        {:error, silence_row(venue, channel, nil, "connected but received no frame within #{timeout_ms}ms")}

      {:ack_timeout, first_kind} ->
        {:error, silence_row(venue, channel, first_kind, "connected but received no data frame within #{timeout_ms}ms")}

      {:rejected, frame} ->
        {:error, rejected_row(venue, channel, frame)}

      {:data, frame, class, first_kind} ->
        {:ok, success_row(venue, channel, class, frame, first_kind)}
    end
  end

  defp await_frame(venue, deadline, first_kind) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      timeout_result(first_kind)
    else
      receive do
        {:websocket_message, frame} -> handle_frame(venue, deadline, first_kind, frame)
        {:websocket_unmatched_response, frame} -> handle_frame(venue, deadline, first_kind, frame)
        {:ws_frame, frame} -> handle_frame(venue, deadline, first_kind, frame)
        _other -> await_frame(venue, deadline, first_kind)
      after
        max(left, 0) -> timeout_result(first_kind)
      end
    end
  end

  defp timeout_result(:none), do: :timeout
  defp timeout_result(first_kind), do: {:ack_timeout, first_kind}

  defp handle_frame(venue, deadline, first_kind, frame) do
    if heartbeat?(frame) do
      await_frame(venue, deadline, first_kind)
    else
      classify_received(venue, deadline, first_kind, frame)
    end
  end

  defp classify_received(venue, deadline, first_kind, frame) do
    case SubscribeAck.classify(venue, frame) do
      {:rejected, rejected} -> {:rejected, rejected}
      :success -> continue_after_ack(venue, deadline, first_kind, frame)
      class -> {:data, frame, class, first_kind_or(first_kind, frame_kind(class, frame))}
    end
  end

  defp continue_after_ack(venue, deadline, first_kind, frame) do
    kind = frame_kind(:success, frame)

    if kind == "acknowledgement_with_payload" do
      {:data, frame, :success, first_kind_or(first_kind, kind)}
    else
      await_frame(venue, deadline, first_kind_or(first_kind, kind))
    end
  end

  defp first_kind_or(:none, kind), do: kind
  defp first_kind_or(existing, _kind), do: existing

  defp heartbeat?(frame) when is_binary(frame), do: String.downcase(frame) in ["ping", "pong"]
  defp heartbeat?(%{"op" => op}) when op in ["ping", "pong"], do: true
  defp heartbeat?(%{"event" => event}) when event in ["ping", "pong"], do: true
  defp heartbeat?(%{"type" => type}) when type in ["ping", "pong"], do: true
  defp heartbeat?(_frame), do: false

  defp success_row(venue, channel, class, frame, first_kind) do
    data_kind = frame_kind(class, frame)

    %{
      channel: channel,
      data_frame: data_kind,
      first_frame: first_kind,
      reason: nil,
      section: "public",
      status: "passed",
      tracking: nil,
      venue: venue
    }
  end

  defp silence_row(venue, channel, first_kind, detail) do
    %{
      channel: channel,
      data_frame: nil,
      first_frame: first_kind,
      reason: "#{venue} #{channel}: #{detail}",
      section: "public",
      status: "failed",
      tracking: nil,
      venue: venue
    }
  end

  defp rejected_row(venue, channel, frame) do
    %{
      channel: channel,
      data_frame: nil,
      first_frame: "rejected",
      reason: "#{venue} #{channel}: #{inspect(frame)}",
      section: "public",
      status: "failed",
      tracking: nil,
      venue: venue
    }
  end

  defp failure_row(spec, channel, reason) do
    %{
      channel: channel,
      data_frame: nil,
      first_frame: nil,
      reason: "#{spec.venue} #{channel}: #{reason}",
      section: to_string(spec.section),
      status: "failed",
      tracking: nil,
      venue: spec.venue
    }
  end

  defp unreachable_row?(%{reason: reason}) when is_binary(reason) do
    reason =~ "network_error" or reason =~ "exchange_not_available" or reason =~ "nxdomain"
  end

  defp unreachable_row?(_row), do: false

  defp unreachable_ok_from_env do
    "LIVE_DRIFT_UNREACHABLE_OK"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp channel_label_from_handle(%{channels: channels}), do: channel_label(%{channels: channels})

  defp channel_label(%{channels: [channel | _]}) when is_binary(channel), do: channel
  defp channel_label(%{channels: [channel | _]}) when is_map(channel), do: inspect(channel)
  defp channel_label(%{watch: watch, symbol: symbol}), do: "#{watch}:#{symbol}"
  defp channel_label(%{venue: venue}), do: venue
  defp channel_label(_spec), do: "unknown"
end
