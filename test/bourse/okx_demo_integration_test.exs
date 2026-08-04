defmodule Bourse.OKXDemoIntegrationTest do
  use ExUnit.Case, async: false

  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.Exchange

  @moduletag :network

  @minimum_probe_price 1

  test "international demo transport returns a balance and the live environment rejects its key" do
    credentials = credentials!()

    live = Exchange.new!("okx", credentials: credentials, hostname: "www.okx.com")

    demo = Exchange.new!("okx", credentials: credentials, sandbox: true)

    assert {:error, %Error{type: :authentication_error, message: live_message, raw: %{"code" => "50101"}}} =
             Bourse.fetch_balance(live)

    assert live_message =~ "APIKey does not match current environment"
    assert {:ok, %Bourse.Balance{} = balance} = Bourse.fetch_balance(demo)
    assert map_size(balance.total) > 0
    assert Map.keys(balance.total) == Map.keys(balance.free)
  end

  # Task 255: books-lite previously crashed Access.get/3 on scalar "error" and was
  # mislabeled network_error by the http.ex rescue. Live demo must return a typed
  # exchange error class, never network_error.
  test "public_get_market_books_lite returns typed exchange error, not network_error" do
    demo =
      Exchange.new!("okx", credentials: credentials!(), sandbox: true)

    # Missing instId triggers the gateway/app error path that surfaces the scalar
    # or body-level envelope (same family as the venue_compare repro).
    result = Bourse.Okx.public_get_market_books_lite(demo, %{})

    assert {:error, %Error{} = err} = result

    refute err.type == :network_error,
           "expected typed exchange error, got network_error: #{inspect(err)}"

    assert err.message not in [nil, ""], "error message should not be blank"
    assert err.raw != nil, "raw body should be retained"
  end

  test "loaded precision prevents an invalid lot or tick response on a demo order" do
    demo =
      Exchange.new!("okx", credentials: credentials!(), sandbox: true)

    assert {:ok, demo} = Bourse.load_markets(demo)

    # Deliberately non-conforming against the live instrument: BTC-USDT carries
    # lotSz 1e-8 and tickSz 0.1, so both values need rounding before the wire.
    # OKX reports per-order outcomes in data[].sCode; the envelope `code` is "1"
    # ("All operations failed"), so assert on the nested code.
    case Bourse.create_order(demo, "BTC/USDT", "limit", "buy", 0.000109_123_456_789, price: 1.03) do
      {:ok, %Bourse.Order{id: order_id}} when is_binary(order_id) and order_id != "" ->
        assert {:ok, _order} = Bourse.cancel_order(demo, order_id, symbol: "BTC/USDT")

      {:error, %Error{raw: %{"data" => [%{"sCode" => s_code, "sMsg" => s_msg}]}}} ->
        # 51121 = lot-size multiple, 51006 = price outside limit/tick. Reaching
        # either would mean precision never made it onto the request.
        refute s_code in ["51121", "51006"], "precision rejection leaked to the venue: #{s_code} #{s_msg}"

      other ->
        flunk("unexpected precision probe result: #{inspect(other)}")
    end
  end

  test "loaded markets reject a below-minimum amount locally before the international demo order request" do
    demo =
      Exchange.new!("okx", credentials: credentials!(), sandbox: true)

    assert {:ok, demo} = Bourse.load_markets(demo)
    market = Enum.find(demo.markets, &(&1.symbol == "BTC/USDT"))

    assert %Bourse.Market{
             limits: %{
               "amount" => %{"min" => amount_min},
               "cost" => cost_limits,
               "price" => price_limits
             },
             precision: %{"amount" => amount_step, "price" => price_step}
           } = market

    amount = amount_min - amount_step
    assert amount > 0, "BTC/USDT amount minimum must exceed its increment for this probe"

    cost_min = Map.get(cost_limits, "min") || 0
    price_min = Map.get(price_limits, "min") || @minimum_probe_price
    price = increment_ceiling(max(cost_min / amount, price_min), price_step)

    assert is_nil(price_limits["max"]) or price <= price_limits["max"],
           "BTC/USDT price limit must allow an amount-minimum-only probe"

    # Before this preflight path, Task 394's sub-lot capture reached OKX and
    # received sCode 51121 ("The number of orders is less than the minimum").
    # This call must not send that invalid order at all.
    assert {:error, %Error{type: :invalid_order} = error} =
             Bourse.create_order(demo, "BTC/USDT", "limit", "buy", amount, price: price, sanity: true)

    assert error.message =~ "below minimum"
    assert %{"sanity_check" => %{"check_amount" => _}} = error.raw

    # The same order with sanity disabled still reaches OKX, proving the amount
    # is rejected locally rather than being unroutable for some other reason.
    assert {:error, %Error{}} =
             Bourse.create_order(demo, "BTC/USDT", "limit", "buy", amount, price: price)
  end

  # Task 389. The deposit-address family cannot be confirmed at tier 1 with a demo key:
  # OKX does not implement the endpoint in demo trading at all. This pins the exact
  # blocker so a future session recognises it instead of re-diagnosing it as a signing
  # or routing bug — the signed request IS accepted (a *business* error comes back, not
  # 50111/50119), the feature simply does not exist here. The populated-row confrontation
  # is filed in docs/prod-verification-ledger.md.
  test "deposit-address reads are routed and signed but unavailable in demo trading" do
    demo =
      Exchange.new!("okx", credentials: credentials!(), sandbox: true)

    for call <- [
          fn -> Bourse.fetch_deposit_address(demo, "USDT", network: "TRC20") end,
          fn -> Bourse.fetch_deposit_addresses_by_network(demo, "USDT") end
        ] do
      assert {:error, %Error{} = error} = call.()

      # A signature/environment failure would surface as 50111/50101/50119. 50038 proves
      # auth and the x-simulated-trading header were accepted and the venue itself
      # declined the feature.
      assert error.code == "50038",
             "expected the demo feature-unavailable error, got #{inspect(error)}"

      assert error.message =~ "unavailable in demo trading"
      assert error.type == :exchange_error
    end
  end

  defp credentials! do
    with api_key when is_binary(api_key) <- System.get_env("OKX_INTL_API_KEY"),
         secret when is_binary(secret) <- System.get_env("OKX_INTL_API_SECRET"),
         password when is_binary(password) <- System.get_env("OKX_INTL_PASSPHRASE"),
         {:ok, credentials} <- Credentials.new(api_key: api_key, secret: secret, password: password) do
      credentials
    else
      _ ->
        flunk("""
        Missing OKX demo credentials!

        Set these environment variables:
          export OKX_INTL_API_KEY="your_key"
          export OKX_INTL_API_SECRET="your_secret"
          export OKX_INTL_PASSPHRASE="your_passphrase"

        Create an international demo-trading key at www.okx.com.
        """)
    end
  end

  defp increment_ceiling(value, increment) when is_number(value) and is_number(increment) and increment > 0 do
    Float.ceil(value / increment) * increment
  end
end
