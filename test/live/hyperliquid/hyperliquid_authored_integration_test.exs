defmodule Bourse.HyperliquidAuthoredIntegrationTest do
  @moduledoc false
  # Live tier-1 pins for Hyperliquid public /info request shaping (task 333).
  # Semantic authority: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint

  use ExUnit.Case, async: false

  import Bourse.IntegrationHelper, only: [build_exchange: 2, require_credentials!: 1]
  import Bourse.StructValidators, only: [assert_order_book_struct: 2]

  alias Bourse.Test.LiveGateIsolation
  alias Bourse.Testnet
  alias Bourse.Unified.RequestShape

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_hyperliquid

  @perp_symbol "BTC/USDC:USDC"
  @ohlcv_timeframe "1h"
  @ohlcv_limit 3

  # Task 225 order size — 0.0003 BTC ~= $19 at testnet BTC price, clearing the
  # $10 min notional with margin without moving meaningful (fake) size.
  @order_size 0.0003
  @resting_order_size 0.001

  setup do
    LiveGateIsolation.isolate!("hyperliquid")
    :ok
  end

  test "live fetch_ohlcv candleSnapshot uses universe coin and nested-only body" do
    exchange = build_exchange(:hyperliquid, sandbox: true)

    # Pin the wire body the unified path builds (denorm + RequestShape), then
    # prove the same call path returns a non-empty 200 parse against testnet.
    params =
      %{
        "symbol" => @perp_symbol,
        "timeframe" => @ohlcv_timeframe,
        "limit" => @ohlcv_limit
      }
      |> Bourse.Unified.maybe_denormalize_symbol(exchange)
      |> Bourse.Unified.maybe_translate_timeframe(exchange)

    assert params["symbol"] == "BTCUSDC"

    shaped = RequestShape.apply(params, exchange, "fetchOHLCV")

    assert shaped["type"] == "candleSnapshot"
    assert shaped |> Map.keys() |> Enum.sort() == ["req", "type"]

    req = shaped["req"]
    assert req["coin"] == "BTC"
    assert req["interval"] == @ohlcv_timeframe
    assert is_integer(req["startTime"])
    assert is_integer(req["endTime"])
    assert req["startTime"] < req["endTime"]
    # limit-derived window: endTime - startTime == limit * 1h
    assert req["endTime"] - req["startTime"] == @ohlcv_limit * 60 * 60 * 1000

    assert {:ok, rows} =
             Bourse.fetch_ohlcv(exchange, @perp_symbol, @ohlcv_timeframe, limit: @ohlcv_limit)

    assert is_list(rows)
    assert rows != []
    assert length(rows) <= @ohlcv_limit
    assert match?([_ts, _o, _h, _l, _c, _v | _], hd(rows))
  end

  test "live fetch_ohlcv with explicit since still returns candles" do
    exchange = build_exchange(:hyperliquid, sandbox: true)
    # ~3h window ending near "now" — far enough back for testnet to have data.
    since = System.system_time(:millisecond) - 3 * 60 * 60 * 1000

    params =
      Bourse.Unified.maybe_denormalize_symbol(
        %{"symbol" => @perp_symbol, "timeframe" => @ohlcv_timeframe, "since" => since, "limit" => @ohlcv_limit},
        exchange
      )

    shaped = RequestShape.apply(params, exchange, "fetchOHLCV")
    assert shaped["req"]["coin"] == "BTC"
    assert shaped["req"]["startTime"] == since
    refute Map.has_key?(shaped, "symbol")
    refute Map.has_key?(shaped, "since")
    refute Map.has_key?(shaped, "limit")

    assert {:ok, rows} =
             Bourse.fetch_ohlcv(exchange, @perp_symbol, @ohlcv_timeframe,
               since: since,
               limit: @ohlcv_limit
             )

    assert is_list(rows)
    assert rows != []
  end

  test "live public /info reads: order book levels and type-only paths" do
    exchange = build_exchange(:hyperliquid, sandbox: true)

    # fetchOrderBook — l2Book encodes bid and ask levels as object lists under
    # levels, which must normalize to the unified book sides (task 348).
    book_params = Bourse.Unified.maybe_denormalize_symbol(%{"symbol" => @perp_symbol}, exchange)

    assert book_params["symbol"] == "BTCUSDC"

    assert RequestShape.apply(book_params, exchange, "fetchOrderBook") == %{
             "type" => "l2Book",
             "coin" => "BTC"
           }

    assert {:ok, %Bourse.OrderBook{bids: bids, asks: asks, info: info} = book} =
             Bourse.fetch_order_book(exchange, @perp_symbol)

    assert info["coin"] == "BTC"
    assert match?([[_ | _] | _], info["levels"])
    assert bids != []
    assert asks != []
    assert :ok = assert_order_book_struct(book, @perp_symbol)

    # fetchMarkets / fetchTicker / fetchFundingRates — type-only bodies; no nested
    # req / coin symbol dependency. Live markets proves the meta path is green;
    # ticker symbol filter after metaAndAssetCtxs is a separate concern (not the
    # missing-req defect class).
    assert RequestShape.apply(%{}, exchange, "fetchMarkets") == %{"type" => "metaAndAssetCtxs"}
    assert RequestShape.apply(%{}, exchange, "fetchTicker") == %{"type" => "metaAndAssetCtxs"}
    assert RequestShape.apply(%{}, exchange, "fetchFundingRates") == %{"type" => "metaAndAssetCtxs"}

    assert {:ok, markets} = Bourse.fetch_markets(exchange)
    assert Enum.any?(markets, &(&1.symbol == @perp_symbol and &1.base == "BTC"))
  end

  # Task 339 — live meta ordering populates Market.asset_index (public; no creds).
  # Index values follow the live universe order (testnet BTC is not always 0).
  test "live load_markets stamps asset_index from meta universe order" do
    exchange = build_exchange(:hyperliquid, sandbox: true)

    assert {:ok, %Bourse.Exchange{markets: markets}} = Bourse.load_markets(exchange)
    assert is_list(markets) and markets != []

    # Every loaded market (main-dex meta universe today) must carry an integer index.
    assert Enum.all?(markets, &(is_integer(&1.asset_index) and &1.asset_index >= 0))

    # Per-market-type ranges: perps live at their meta.universe position
    # (< 10000), spot assets at 10000 + spot-universe position. Delisted
    # perps and sparse spot listings leave gaps, so contiguity is NOT an
    # invariant — uniqueness is.
    indices = Enum.map(markets, & &1.asset_index)
    assert length(Enum.uniq(indices)) == length(indices)

    {spot, perp} = Enum.split_with(markets, &(&1.type == "spot"))
    assert Enum.all?(perp, &(&1.asset_index < 10_000))
    assert Enum.all?(spot, &(&1.asset_index >= 10_000))

    btc = Enum.find(markets, &(&1.symbol == @perp_symbol))
    assert btc, "BTC/USDC:USDC missing from live markets"
    assert is_integer(btc.asset_index)
    # Task 370 authored identity: perp id/base_id carry the universe index
    # as a string (C-T370, field_map id <- baseId).
    assert btc.id == Integer.to_string(btc.asset_index)
    assert btc.base_id == Integer.to_string(btc.asset_index)

    # Cross-check: asset_index equals the coin's position in the live meta body
    # stored on info (name is the universe coin).
    by_index = Map.new(markets, fn m -> {m.asset_index, m} end)
    assert Map.fetch!(by_index, btc.asset_index).base == "BTC"
    assert btc.info["name"] == "BTC"
  end

  # Task 355 — a nonexistent L1 cancel reaches the venue and returns its
  # business-level rejection instead of an all-nil order wrapper.
  test "live cancel with missing oid reaches Hyperliquid after load_markets" do
    if not Testnet.registered?(:hyperliquid, :default) do
      flunk("""
      Missing testnet credentials for hyperliquid (sandbox: :default).

           Set these environment variables and re-run:
             export HYPERLIQUID_TESTNET_API_KEY=\"your_key\"
             export HYPERLIQUID_TESTNET_API_SECRET=\"your_secret\"
      """)
    end

    creds = %{require_credentials!(:hyperliquid) | sandbox: false}
    exchange = build_exchange(:hyperliquid, sandbox: true, credentials: creds)
    assert {:ok, loaded} = Bourse.load_markets(exchange)

    result =
      try do
        Bourse.cancel_order(loaded, "1", symbol: @perp_symbol)
      rescue
        e in ArgumentError ->
          flunk("cancel raised before signing: #{Exception.message(e)}")
      end

    case result do
      {:ok, _} ->
        :ok

      {:error, %Bourse.Error{exchange: "hyperliquid", message: message}} ->
        assert message =~ "Order was never placed, already canceled, or filled. asset="

      other ->
        flunk("unexpected cancel_order result: #{inspect(other)}")
    end
  end

  test "live fetch_funding_rate_history uses universe coin and native time fields" do
    exchange = build_exchange(:hyperliquid, sandbox: true)
    since = System.system_time(:millisecond) - 3 * 60 * 60 * 1000

    assert {:ok, [%Bourse.FundingRateHistory{symbol: @perp_symbol} | _] = rows} =
             Bourse.fetch_funding_rate_history(exchange, @perp_symbol,
               since: since,
               limit: 3
             )

    assert Enum.all?(rows, &(&1.timestamp >= since))
    assert Enum.all?(rows, &is_number(&1.funding_rate))
  end

  @tag :dangerous
  test "schedule-cancel reaches Hyperliquid with a signed timer action" do
    gate_credentials!()
    exchange = build_exchange(:hyperliquid, sandbox: true, credentials: require_credentials!(:hyperliquid))
    assert {:ok, exchange} = Bourse.load_markets(exchange)

    on_exit(fn ->
      Bourse.cancel_all_orders_after(exchange, 0)
    end)

    case Bourse.cancel_all_orders_after(exchange, 60_000) do
      {:ok, response} ->
        assert is_map(response)

      {:error, %Bourse.Error{exchange: "hyperliquid", raw: raw}} ->
        assert is_map(raw) or is_binary(raw)

      other ->
        flunk("unexpected cancel_all_orders_after result: #{inspect(other)}")
    end
  end

  @tag :dangerous
  test "invalid write inputs reach Hyperliquid's signed action validation" do
    gate_credentials!()
    exchange = build_exchange(:hyperliquid, sandbox: true, credentials: require_credentials!(:hyperliquid))
    assert {:ok, exchange} = Bourse.load_markets(exchange)

    # Each expected fragment is Hyperliquid's OWN validator message, observed
    # live 2026-07-18. Pinning it (rather than "any error") is what makes this
    # tier-1 evidence: a mis-ordered msgpack action or a bad signature recovers
    # to the wrong wallet and rejects with "does not exist", and a client-side
    # parse failure surfaces our own text — neither can satisfy these asserts.
    assert_venue_rejection(
      fn -> Bourse.add_margin(exchange, @perp_symbol, 0) end,
      "add_margin",
      "isolated margin cannot be zero"
    )

    assert_venue_rejection(
      fn -> Bourse.reduce_margin(exchange, @perp_symbol, 0) end,
      "reduce_margin",
      "isolated margin cannot be zero"
    )

    # "0 min(s)" also pins the ms -> minutes carve: duration 0 ms became m = 0.
    assert_venue_rejection(
      fn -> Bourse.create_twap_order(exchange, @perp_symbol, "buy", 0, 0) end,
      "create_twap_order",
      "Invalid TWAP duration: 0 min(s)"
    )

    assert_venue_rejection(
      fn -> Bourse.withdraw(exchange, "USDC", 0, "0x0000000000000000000000000000000000000001") end,
      "withdraw",
      "Withdrawal amount cannot be zero"
    )

    # Task 384 — vaultTransfer branch. Zero-amount vault withdraw must leave the
    # client as a signed vaultTransfer (not withdraw3) and reach the venue. The
    # observed message depends on whether the address is a vault the wallet leads;
    # either a vault-action rejection or a zero-amount rejection proves the L1
    # action was accepted by the signing/transport path.
    vault_shaped =
      RequestShape.apply(
        %{
          "code" => "USDC",
          "amount" => 0,
          "address" => "0x0000000000000000000000000000000000000001",
          "vaultAddress" => "0x0000000000000000000000000000000000000001"
        },
        exchange,
        "withdraw"
      )

    assert vault_shaped["action"]["type"] == "vaultTransfer"
    assert vault_shaped["action"]["isDeposit"] == false
    assert vault_shaped["action"]["usd"] == 0

    # Observed live 2026-07-19 on testnet with a zero-address vault: the signed
    # vaultTransfer reaches Hyperliquid and returns the venue's own vault error
    # (not the bridge-withdraw "Withdrawal amount cannot be zero").
    assert_venue_rejection(
      fn ->
        Bourse.withdraw(exchange, "USDC", 0, "0x0000000000000000000000000000000000000001",
          vaultAddress: "0x0000000000000000000000000000000000000001"
        )
      end,
      "withdraw(vaultTransfer)",
      ~r/Vault not registered|Vault may not perform this action|cannot be zero/i
    )
  end

  # Task 225 — tier-1 live signed-success + fill parse. Upgrades the tier-2
  # userFills fixture pin (HyperliquidAuthoredSpecTest) with real testnet
  # evidence: a signed /exchange order that FILLS, and fetch_my_trades reading
  # the resulting non-empty userFills into %Bourse.Trade{}. Mutation-safe: a tiny
  # IOC long immediately flattened reduce-only, so the account nets flat.
  @tag :dangerous
  test "live signed order fills, is pinned, and fetch_my_trades parses the fill" do
    gate_credentials!()
    creds = require_credentials!(:hyperliquid)
    exchange = build_exchange(:hyperliquid, sandbox: true, credentials: creds)
    assert {:ok, exchange} = Bourse.load_markets(exchange)

    # Safety net: flatten any residual BTC position even if an assertion aborts
    # the test between the buy and the reduce-only sell — the account must never
    # accrete size across runs.
    on_exit(fn -> flatten_btc!(exchange) end)

    mid = live_mid(exchange, "BTC")

    # Crossing IOC buy → immediate fill, no resting remainder.
    buy_px = mid |> Kernel.*(1.01) |> Float.round(0) |> trunc()

    # AC1: a signed /exchange call returns a real success (NOT the
    # "User or API Wallet 0x… does not exist" signer-mismatch error) and fills,
    # parsed (task 352) into a populated %Bourse.Order{} — not the raw envelope.
    assert {:ok, %Bourse.Order{} = buy_order} =
             Bourse.create_orders(exchange, [order_row("buy", buy_px, false)])

    assert buy_order.status == "closed"
    assert is_binary(buy_order.id) and buy_order.id != ""
    assert is_number(buy_order.average) and buy_order.average > 0
    assert_in_delta buy_order.filled, @order_size, 1.0e-9

    # Flatten the tiny long reduce-only so the account returns to zero.
    sell_px = mid |> Kernel.*(0.99) |> Float.round(0) |> trunc()

    assert {:ok, %Bourse.Order{status: "closed"}} =
             Bourse.create_orders(exchange, [order_row("sell", sell_px, true)])

    # AC2: fetch_my_trades reads the non-empty live userFills into trades with
    # price / amount / timestamp populated (numeric, not raw wire strings).
    assert {:ok, trades} = Bourse.fetch_my_trades(exchange, symbol: @perp_symbol)
    assert is_list(trades) and trades != []
    assert Enum.all?(trades, &match?(%Bourse.Trade{}, &1))

    placed_trade = Enum.find(trades, &(&1.order_id == buy_order.id))

    assert %Bourse.Trade{} = placed_trade
    assert placed_trade.symbol == @perp_symbol
    assert is_number(placed_trade.price) and placed_trade.price > 0
    assert is_number(placed_trade.amount) and placed_trade.amount > 0
    assert is_integer(placed_trade.timestamp) and placed_trade.timestamp > 0
    assert placed_trade.datetime =~ ~r/^\d{4}-\d{2}-\d{2}T/
  end

  @tag :dangerous
  test "live singular create_order places and cancels a resting L1 order" do
    gate_credentials!()
    creds = require_credentials!(:hyperliquid)
    exchange = build_exchange(:hyperliquid, sandbox: true, credentials: creds)
    assert {:ok, exchange} = Bourse.load_markets(exchange)

    mid = live_mid(exchange, "BTC")
    price = mid |> Kernel.*(0.5) |> Float.round(0) |> trunc()

    shaped =
      RequestShape.apply(
        %{
          "symbol" => @perp_symbol,
          "type" => "limit",
          "side" => "buy",
          "amount" => @resting_order_size,
          "price" => price
        },
        exchange,
        "createOrder"
      )

    assert %{"type" => "order", "orders" => [_], "grouping" => "na"} = shaped["action"]

    assert {:ok, %Bourse.Order{id: order_id, info: info}} =
             Bourse.create_order(exchange, @perp_symbol, "limit", "buy", @resting_order_size, price: price)

    on_exit(fn ->
      Bourse.cancel_order(exchange, order_id, symbol: @perp_symbol)
    end)

    assert is_binary(order_id) and order_id != ""
    assert %{"resting" => %{"oid" => oid}} = info
    assert to_string(oid) == order_id

    assert {:ok, %Bourse.Order{status: "canceled"}} =
             Bourse.cancel_order(exchange, order_id, symbol: @perp_symbol)
  end

  # Task 225 AC3 — the signing address derived from the private key must equal
  # the registered testnet wallet (api_key). A mismatch is the root cause of the
  # historical "User or API Wallet 0x… does not exist" rejection.
  test "derived signing address equals the registered testnet wallet" do
    gate_credentials!()
    creds = require_credentials!(:hyperliquid)

    assert String.downcase(creds.api_key) == derive_eth_address(creds.secret)
  end

  # --- task 225 helpers -----------------------------------------------------

  defp order_row(side, price, reduce_only?) do
    %{
      "symbol" => @perp_symbol,
      "side" => side,
      "type" => "limit",
      "amount" => @order_size,
      "price" => price,
      "timeInForce" => "IOC",
      "reduceOnly" => reduce_only?
    }
  end

  # Since task 352 create_orders parses the fill into a populated %Bourse.Order{};
  # the flatten helper only needs the success/flunk split, not the envelope.
  defp order_info!({:ok, %Bourse.Order{info: info}}), do: info
  defp order_info!(other), do: flunk("unexpected create_orders result: #{inspect(other)}")

  # Reduce-only IOC close of any residual BTC position. Idempotent: no-op when
  # already flat. Reads szi from clearinghouseState so it flattens whatever size
  # a partial/aborted run left behind.
  defp flatten_btc!(exchange) do
    positions =
      post_info(exchange, %{"type" => "clearinghouseState", "user" => exchange.credentials.api_key})["assetPositions"] ||
        []

    case Enum.find(positions, &(&1["position"]["coin"] == "BTC")) do
      %{"position" => %{"szi" => szi_str}} -> close_btc!(exchange, String.to_float(szi_str))
      _ -> :ok
    end
  end

  defp close_btc!(_exchange, szi) when szi == 0.0, do: :ok

  defp close_btc!(exchange, szi) do
    side = if szi > 0, do: "sell", else: "buy"
    cross = if szi > 0, do: 0.99, else: 1.01
    px = exchange |> live_mid("BTC") |> Kernel.*(cross) |> Float.round(0) |> trunc()

    exchange
    |> Bourse.create_orders([side |> order_row(px, true) |> Map.put("amount", abs(szi))])
    |> order_info!()
  end

  defp live_mid(exchange, coin) do
    {mid, _} = exchange |> post_info(%{"type" => "allMids"}) |> Map.fetch!(coin) |> Float.parse()
    mid
  end

  defp post_info(exchange, payload) do
    url = exchange.base_urls["public"] <> "/info"
    body = Jason.encode!(payload)
    Req.post!(url, headers: [{"content-type", "application/json"}], body: body).body
  end

  # secp256k1 pubkey → keccak256(pub[1..])[-20..] → lowercased 0x-address.
  defp derive_eth_address(secret) do
    priv =
      secret
      |> String.replace_prefix("0x", "")
      |> String.slice(-64, 64)
      |> Base.decode16!(case: :mixed)

    {:ok, <<0x04, xy::binary-64>>} = ExSecp256k1.create_public_key(priv)
    <<_::binary-12, addr::binary-20>> = ExKeccak.hash_256(xy)
    "0x" <> Base.encode16(addr, case: :lower)
  end

  defp gate_credentials! do
    if !Testnet.registered?(:hyperliquid, :default) do
      flunk("""
      Missing testnet credentials for hyperliquid (sandbox: :default).

      Set these environment variables and re-run:
        export HYPERLIQUID_TESTNET_API_KEY="your_wallet_address"
        export HYPERLIQUID_TESTNET_API_SECRET="your_private_key"

      The testnet wallet must be provisioned (a >=5 native-USDC mainnet Bridge2
      deposit unlocks claimDrip) so a signed order can fill.
      """)
    end
  end

  defp assert_venue_rejection(call, method, expected_fragment) do
    result =
      try do
        call.()
      rescue
        e in ArgumentError -> flunk("#{method} raised before reaching Hyperliquid: #{Exception.message(e)}")
      end

    case result do
      {:error, %Bourse.Error{exchange: "hyperliquid", message: message}} when is_binary(message) ->
        assert message =~ expected_fragment,
               "#{method} did not surface Hyperliquid's own validator message.\n" <>
                 "expected to contain: #{inspect(expected_fragment)}\n" <>
                 "got: #{inspect(message)}"

      {:ok, value} ->
        flunk("#{method} unexpectedly succeeded: #{inspect(value)}")

      other ->
        flunk("#{method} returned an unexpected result: #{inspect(other)}")
    end
  end
end
