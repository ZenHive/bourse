defmodule Bourse.WS.SpecConfigTest do
  use ExUnit.Case, async: true

  alias Bourse.Exchange
  alias Bourse.WS.Config
  alias Bourse.WS.Subscription

  @ws_venues ~w(binance binancecoinm binanceusdm bybit deribit derive hyperliquid okx)

  describe "build/1" do
    test "configured venues are a closed subset of runtime support" do
      assert Config.supported_exchanges() == @ws_venues
      assert MapSet.subset?(MapSet.new(@ws_venues), MapSet.new(Bourse.Spec.exchanges()))

      for id <- @ws_venues do
        assert %{} = config = Config.for_exchange(id)
        assert is_atom(config.subscription_pattern)
        assert is_map(config.heartbeat)
      end
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
      assert config.auth_pattern == :listen_key
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

    test "derive auth stays nil — no WS auth pattern for privateKey login" do
      config = Config.for_exchange("derive")
      assert config.auth_pattern == nil
      # Registered atom (MethodParams); bare :method_params has no module clause.
      assert config.subscription_pattern == :method_params_subscribe
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
