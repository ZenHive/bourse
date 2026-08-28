defmodule Bourse.WS.SpecConfigTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.WS
  alias Bourse.WS.Config
  alias Bourse.WS.Subscription
  alias ZenWebsocket.Client

  @ws_venues ~w(alpaca binance binancecoinm binanceusdm bybit deribit derive hyperliquid lighter okx)

  defmodule Transport do
    @moduledoc false
    use GenServer

    @spec start() :: GenServer.on_start()
    def start, do: GenServer.start(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, :ok}

    @impl true
    def handle_call(:get_state, _from, state), do: {:reply, :connected, state}

    @impl true
    def handle_call({:send_message, _message}, _from, state), do: {:reply, :ok, state}
  end

  describe "build/1" do
    test "configured venues and registered divergences partition runtime support" do
      assert Config.supported_exchanges() == @ws_venues

      assert Enum.sort(@ws_venues ++ Map.keys(Config.registered_divergences())) ==
               Bourse.Spec.exchanges()

      for id <- @ws_venues do
        assert %{} = config = Config.for_exchange(id)
        assert is_atom(config.subscription_pattern)
        assert is_map(config.heartbeat)
      end
    end

    test "alpaca selects public auth while lighter needs none" do
      alpaca = Config.for_exchange("alpaca")
      lighter = Config.for_exchange("lighter")

      assert alpaca.auth_pattern == :action_key_secret
      assert alpaca.auth_sections == [:public]
      assert lighter.auth_pattern == nil
    end

    test "bybit heartbeat interval comes from spec (18000ms)" do
      exchange = Exchange.new!("bybit")
      config = Config.for_exchange(exchange)
      assert config.heartbeat.interval == 18_000
    end

    test "deribit heartbeat keeps deribit type from hand base" do
      exchange = Exchange.new!("deribit")
      config = Config.for_exchange(exchange)
      assert config.heartbeat.type == :deribit
      assert config.heartbeat.interval == 30_000
    end

    test "hyperliquid is supported with public URL" do
      exchange = Exchange.new!("hyperliquid")
      config = Config.for_exchange(exchange)
      assert config.public_url == "wss://api.hyperliquid.xyz/ws"
      assert config.auth_pattern == nil
    end

    test "binanceusdm uses futures stream URLs from hand base" do
      config = Config.for_exchange("binanceusdm")
      assert config.public_url == "wss://fstream.binance.com/public/ws"
      assert config.market_url == "wss://fstream.binance.com/market/ws"
      assert config.private_url == "wss://fstream.binance.com/private/ws"
      assert config.private_url_sandbox == "wss://demo-fstream.binance.com/private/ws"
      assert config.auth_pattern == :listen_key

      assert config.auth_config.listen_key_url == %{
               placement: :query,
               events: ["ORDER_TRADE_UPDATE", "ACCOUNT_UPDATE"]
             }
    end

    test "binancecoinm resolves the delivery stream and its own listen key endpoints" do
      config = Config.for_exchange("binancecoinm")

      # COIN-M is a separate host and a separate wallet from USD-M; resolving
      # fstream or a fapi endpoint here would authenticate the wrong stream.
      assert config.public_url == "wss://dstream.binance.com/ws"
      assert config.public_url_sandbox == "wss://demo-dstream.binance.com/ws"
      assert config.auth_pattern == :listen_key

      assert %{
               pre_auth: %{
                 default_market_type: :inverse,
                 endpoints: %{inverse: :dapiPrivate_post_listenkey},
                 keepalive_endpoints: %{inverse: :dapiPrivate_put_listenkey}
               }
             } = config.auth_config
    end

    test "derive authors :eip191_jsonrpc_login so public/login runs as the handshake" do
      config = Config.for_exchange("derive")
      assert config.auth_pattern == :eip191_jsonrpc_login
      # Registered atom (MethodParams); bare :method_params has no module clause.
      assert config.subscription_pattern == :method_params_subscribe
    end

    test "every venue's private connect either has an auth_pattern or errors at URL resolution" do
      for id <- @ws_venues do
        config = Config.for_exchange(id)

        if config.private_url || config.private_url_sandbox do
          assert config.auth_pattern,
                 "#{id} authors a private WS URL without an auth_pattern — connect/3 would have no handshake to run"
        else
          assert {:error, :no_url_configured} = WS.connect(Exchange.new!(id), :private)
        end
      end
    end

    test "every venue's private connect either carries a non-nil ws.auth or returns an error" do
      connect_fun = fn _url, _opts ->
        {:ok, pid} = Transport.start()
        {:ok, %Client{server_pid: pid, state: :connected}}
      end

      # Offline inventory. `Exchange.new!/1` carries no credentials, so the
      # outcome each venue owes is fixed by its own authored config, and an
      # unauthenticated `{:ok, ws}` is forbidden for every one of them — the
      # `:no_auth_pattern`-to-`:ok` mapping this pins against surfaced here as
      # `{:ok, ws}` with a nil `auth`. The reason is asserted per venue rather
      # than against an allowlist: a regression that collapsed every venue to
      # `:websocket_not_configured` would satisfy an allowlist while proving
      # nothing about the handshake.
      for id <- Enum.sort(@ws_venues ++ Map.keys(Config.registered_divergences())) do
        expected =
          case Config.for_exchange(id) do
            # A registered divergence carries no WS config to resolve from.
            nil -> :websocket_not_configured
            # No private URL, so the section never reaches a handshake.
            %{private_url: nil, private_url_sandbox: nil} -> :no_url_configured
            # A private URL and an authored handshake: connect/3 gets as far as
            # the handshake and stops there for want of a credential.
            _ -> :no_credentials
          end

        case WS.connect(Exchange.new!(id), :private, connect_fun: connect_fun, auth_timeout_ms: 50) do
          {:ok, ws} ->
            try do
              assert ws.auth,
                     "#{id} private connect returned an open unauthenticated socket"
            after
              WS.close(ws)
            end

          {:error, reason} ->
            assert reason == expected,
                   "#{id} private connect stopped at #{inspect(reason)}, " <>
                     "expected #{inspect(expected)} for its authored config"
        end
      end
    end

    test "connect/3 does not map :no_auth_pattern to an open socket" do
      source = File.read!("lib/bourse/ws.ex")
      refute source =~ ~r/\{:error, :no_auth_pattern\}\s*->\s*\{:ok, ws\}/
    end

    test "hyperliquid's nil auth_pattern is correct — private data is address-scoped on the public socket" do
      config = Config.for_exchange("hyperliquid")
      assert config.auth_pattern == nil
      assert is_nil(config.private_url)
      assert is_nil(config.private_url_sandbox)
      assert {:error, :no_url_configured} = WS.connect(Exchange.new!("hyperliquid"), :private)
    end

    test "derive uses registered :method_params_subscribe and build_subscribe returns frames" do
      # Bourse pro derive.ts: {"method":"subscribe","params":{"channels":[...]}}
      config = Config.for_exchange("derive")
      assert config.subscription_pattern == :method_params_subscribe
      assert Subscription.module_for_pattern(config.subscription_pattern)

      assert {:ok, %{"method" => "subscribe", "params" => %{"channels" => ["ticker.ETH.100"]}}} =
               Subscription.build_subscribe(
                 config.subscription_pattern,
                 ["ticker.ETH.100"],
                 config.subscription_config
               )
    end

    test "reference venue ids stay unsupported" do
      assert Config.for_exchange("kraken") == nil
      refute Config.supported?("kraken")
      assert Config.for_exchange(%Exchange{id: "kraken", name: "Unsupported", spec: %{}}) == nil
    end
  end
end
