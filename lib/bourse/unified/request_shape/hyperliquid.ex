defmodule Bourse.Unified.RequestShape.Hyperliquid do
  @moduledoc false

  # Builds Hyperliquid L1 / user-signed `action` (+ `nonce`) for unified methods.
  # Authority: Hyperliquid exchange endpoint docs
  # (https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/exchange-endpoint)
  # and the official Python SDK (`hyperliquid/exchange.py`).
  #
  # Callers may still pass an explicit `"action"` override for raw `/exchange`
  # drives — when present, only a missing nonce is filled.
  #
  # Params are string-keyed here, as in every sibling RequestShape builder: the
  # unified path stringifies before dispatch, and the map also carries RequestShape's
  # own atom-keyed control tags, so it must be passed through untouched apart from
  # the keys we own. (An atom-keyed `:action` from a raw caller is still honoured —
  # `Bourse.Signing.Hyperliquid` reads both spellings.)

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Symbol
  alias Bourse.Unified.RequestShape

  @default_builder "0x6530512a6c89c7cfcebc3ba7fcd9ada5f30827a6"

  @doc false
  @spec build(map(), String.t(), Exchange.t(), keyword()) :: map()
  def build(params, js_name, exchange, opts \\ [])

  def build(params, js_name, %Exchange{} = exchange, opts) when is_map(params) and is_binary(js_name) and is_list(opts) do
    if present?(params, "action") do
      ensure_nonce(params, opts)
    else
      do_build(params, js_name, exchange, opts)
    end
  end

  def build(params, _js_name, _exchange, _opts), do: params

  defp do_build(params, "cancelOrder", exchange, opts) do
    id = params["id"]
    symbol = params["symbol"]

    if is_nil(id) or is_nil(symbol) do
      params
    else
      build_cancel(params, [id], symbol, exchange, opts)
    end
  end

  defp do_build(params, "cancelOrders", exchange, opts) do
    ids = params["ids"]
    symbol = params["symbol"]

    if is_list(ids) and is_binary(symbol) do
      build_cancel(params, ids, symbol, exchange, opts)
    else
      params
    end
  end

  defp do_build(params, "createOrders", exchange, opts) do
    case params["orders"] do
      orders when is_list(orders) and orders != [] ->
        build_create_orders(params, orders, exchange, opts)

      _ ->
        params
    end
  end

  defp do_build(params, js_name, exchange, opts)
       when js_name in ["createOrder", "createOrderWithTakeProfitAndStopLoss"] do
    # createOrderWithTakeProfitAndStopLoss is the same L1 order action as createOrder
    # (TP/SL ride as attached triggers on the order). Without this clause the
    # private /exchange path reaches the signer with no `action`.
    params
    |> build_create_orders([params], exchange, opts)
    |> Map.drop([
      "symbol",
      "type",
      "side",
      "amount",
      "price",
      "reduceOnly",
      "reduce_only",
      "timeInForce",
      "time_in_force",
      "clientOrderId",
      "client_order_id",
      "takeProfitPrice",
      "stopLossPrice",
      "take_profit",
      "stop_loss"
    ])
  end

  defp do_build(params, js_name, exchange, opts) when js_name in ["addMargin", "reduceMargin"] do
    build_isolated_margin(params, js_name, exchange, opts)
  end

  defp do_build(params, "createTwapOrder", exchange, opts) do
    build_twap_order(params, exchange, opts)
  end

  # Dead man's switch. The provider action uses `time: nonce + timeout`; timeout
  # 0 clears the timer.
  # An unusable timeout raises rather than silently shaping an action-less body:
  # the signer-owned `action`/`nonce` slots no longer carry an identifier guard
  # to catch it downstream (task 417).
  defp do_build(params, "cancelAllOrdersAfter", _exchange, opts) do
    timeout = parse_int_param!(params["timeout"])

    if timeout < 0 do
      raise Error.invalid_parameters(
              message: "hyperliquid action build: expected non-negative timeout, got #{inspect(timeout)}",
              exchange: "hyperliquid",
              raw: %{"reason" => "non_negative_timeout", "value" => timeout}
            )
    end

    nonce = nonce(params, opts)
    action = %{"type" => "scheduleCancel", "time" => nonce + timeout}

    params
    |> put_action_nonce(action, nonce)
    |> maybe_put_vault(params)
    |> Map.drop(["timeout", "vaultAddress", "vault_address", "subAccountAddress", "sub_account_address"])
  end

  defp do_build(params, "transfer", exchange, opts) do
    amount = params["amount"]
    from_account = params["from_account"] || params["fromAccount"]
    to_account = params["to_account"] || params["toAccount"]

    if is_nil(amount) or is_nil(from_account) or is_nil(to_account) do
      params
    else
      build_transfer(params, params["code"], amount, to_string(from_account), to_string(to_account), exchange, opts)
    end
  end

  defp do_build(params, "withdraw", exchange, opts) do
    amount = params["amount"]
    address = params["address"]

    if is_nil(amount) or is_nil(address) do
      params
    else
      build_withdraw(params, amount, address, exchange, opts)
    end
  end

  defp do_build(params, _js_name, _exchange, _opts), do: params

  # --- cancel (L1) ----------------------------------------------------------

  defp build_cancel(params, ids, symbol, exchange, opts) do
    asset = asset_index(exchange, symbol)
    nonce = nonce(params, opts)

    cancels =
      Enum.map(ids, fn id ->
        %{"a" => asset, "o" => parse_int_param!(id)}
      end)

    action = %{"type" => "cancel", "cancels" => cancels}

    params
    |> put_action_nonce(action, nonce)
    |> maybe_put_vault(params)
    |> drop_cancel_unified_keys()
  end

  # --- createOrders (L1) ----------------------------------------------------

  defp build_create_orders(params, orders, exchange, opts) do
    nonce = nonce(params, opts)

    order_rows =
      Enum.map(orders, fn order when is_map(order) ->
        build_limit_order_row(order, exchange)
      end)

    action = maybe_put_builder(%{"type" => "order", "orders" => order_rows, "grouping" => grouping(params)}, exchange)

    params
    |> Map.drop(["orders", "symbol", "grouping"])
    |> put_action_nonce(action, nonce)
    |> maybe_put_vault(params)
  end

  defp build_limit_order_row(order, exchange) do
    symbol = Map.fetch!(order, "symbol")
    buy? = buy_side?(Map.fetch!(order, "side"))
    type = order |> Map.get("type", "limit") |> to_string() |> String.downcase()
    amount = Map.fetch!(order, "amount")
    price = Map.get(order, "price")
    reduce_only? = truthy?(Map.get(order, "reduceOnly") || Map.get(order, "reduce_only"))
    tif = order_tif(type, order)

    row = %{
      "a" => asset_index(exchange, symbol),
      "b" => buy?,
      "p" => number_string(price),
      "s" => number_string(amount),
      "r" => reduce_only?,
      "t" => %{"limit" => %{"tif" => tif}}
    }

    case Map.get(order, "clientOrderId") || Map.get(order, "client_order_id") do
      cloid when is_binary(cloid) and cloid != "" -> Map.put(row, "c", cloid)
      _ -> row
    end
  end

  # --- isolated margin / TWAP (L1) -----------------------------------------

  defp build_isolated_margin(params, js_name, exchange, opts) do
    symbol = params["symbol"]
    amount = params["amount"]

    if is_nil(symbol) or is_nil(amount) do
      params
    else
      ntli = amount_to_micro_usd(amount)
      ntli = if js_name == "reduceMargin", do: -ntli, else: ntli

      action = %{
        "type" => "updateIsolatedMargin",
        "asset" => asset_index(exchange, symbol),
        "isBuy" => true,
        "ntli" => ntli
      }

      params
      |> put_action_nonce(action, nonce(params, opts))
      |> maybe_put_vault(params)
      |> Map.drop(["symbol", "amount", "vaultAddress", "vault_address", "subAccountAddress", "sub_account_address"])
    end
  end

  defp build_twap_order(params, exchange, opts) do
    required = [params["symbol"], params["side"], params["amount"], params["duration"]]

    if Enum.any?(required, &is_nil/1) do
      params
    else
      buy? = buy_side?(params["side"])

      action = %{
        "type" => "twapOrder",
        "twap" => %{
          "a" => asset_index(exchange, params["symbol"]),
          "b" => buy?,
          "s" => number_string(params["amount"]),
          "r" => truthy?(params["reduceOnly"] || params["reduce_only"]),
          "m" => duration_minutes!(params["duration"]),
          "t" => truthy?(params["randomize"])
        }
      }

      params
      |> put_action_nonce(action, nonce(params, opts))
      |> maybe_put_vault(params)
      |> Map.drop([
        "symbol",
        "side",
        "amount",
        "duration",
        "reduceOnly",
        "reduce_only",
        "randomize",
        "vaultAddress",
        "vault_address"
      ])
    end
  end

  defp buy_side?(side) when is_binary(side) do
    case String.downcase(side) do
      allowed when allowed in ["buy", "b"] -> true
      allowed when allowed in ["sell", "s"] -> false
      _ -> RequestShape.refuse_uninterpretable_side!(side)
    end
  end

  defp buy_side?(side), do: RequestShape.refuse_uninterpretable_side!(side)

  defp duration_minutes!(duration) when is_integer(duration), do: div(duration, 60_000)
  defp duration_minutes!(duration) when is_float(duration), do: duration |> Kernel./(60_000) |> Float.floor() |> trunc()

  defp duration_minutes!(duration) when is_binary(duration) do
    case Float.parse(duration) do
      {value, ""} -> duration_minutes!(value)
      _ -> reject_invalid_duration!(duration)
    end
  end

  defp duration_minutes!(duration), do: reject_invalid_duration!(duration)

  defp reject_invalid_duration!(duration) do
    raise Error.invalid_parameters(
            message: "hyperliquid action build: expected duration in milliseconds, got #{inspect(duration)}",
            exchange: "hyperliquid",
            raw: %{"reason" => "invalid_duration", "value" => duration}
          )
  end

  # --- withdrawal ----------------------------------------------------------
  #
  # Two distinct venue operations share the unified `withdraw` method:
  #   * bare withdraw → user-signed `withdraw3` (bridge withdraw)
  #   * params.vaultAddress set → L1 `vaultTransfer` with isDeposit: false
  # Official docs: "Deposit or withdraw from a vault" action type vaultTransfer.
  # Python SDK: Exchange.vault_usd_transfer/3. Use the same provider branch.

  defp build_withdraw(params, amount, address, exchange, opts) do
    nonce = nonce(params, opts)

    case vault_address(params) do
      vault when is_binary(vault) ->
        build_vault_withdraw(params, amount, vault, nonce)

      nil ->
        build_bridge_withdraw(params, amount, address, exchange, nonce)
    end
  end

  defp build_vault_withdraw(params, amount, vault, nonce) do
    # Field order matches Hyperliquid docs + Python SDK vault_usd_transfer:
    # type, vaultAddress (0x-prefixed), isDeposit, usd.
    # `usd` is 1e6 micro-USD, same as subAccountTransfer. This deliberately
    # diverges from CCXT, which sends the bare amount. See carve register C-T384.
    action = %{
      "type" => "vaultTransfer",
      "vaultAddress" => "0x" <> vault,
      "isDeposit" => false,
      "usd" => amount_to_micro_usd(amount)
    }

    params
    |> put_action_nonce(action, nonce)
    |> Map.drop([
      "code",
      "amount",
      "address",
      "tag",
      "vaultAddress",
      "vault_address",
      "subAccountAddress",
      "sub_account_address"
    ])
  end

  defp build_bridge_withdraw(params, amount, address, exchange, nonce) do
    action = %{
      "type" => "withdraw3",
      "hyperliquidChain" => hyperliquid_chain(exchange),
      "signatureChainId" => "0x66eee",
      "destination" => address,
      "amount" => number_string(amount),
      "time" => nonce
    }

    params
    |> put_action_nonce(action, nonce)
    |> Map.drop(["code", "amount", "address", "tag"])
  end

  defp order_tif("market", _order), do: "Ioc"

  defp order_tif(_type, order) do
    case Map.get(order, "timeInForce") || Map.get(order, "time_in_force") || "GTC" do
      tif when is_binary(tif) ->
        case String.upcase(tif) do
          "IOC" -> "Ioc"
          "ALO" -> "Alo"
          "PO" -> "Alo"
          _ -> "Gtc"
        end

      _ ->
        "Gtc"
    end
  end

  defp grouping(params) do
    case Map.get(params, "grouping") do
      g when is_binary(g) and g != "" -> g
      _ -> "na"
    end
  end

  defp maybe_put_builder(action, %Exchange{options: options}) when is_map(options) do
    if truthy?(Map.get(options, "approvedBuilderFee") || Map.get(options, :approvedBuilderFee)) do
      builder =
        options
        |> Map.get("builder", Map.get(options, :builder, @default_builder))
        |> to_string()
        |> String.downcase()

      fee =
        if truthy?(Map.get(options, "builderFee", true)) == false do
          0
        else
          Map.get(options, "feeInt", Map.get(options, :feeInt, 10))
        end

      Map.put(action, "builder", %{"b" => builder, "f" => fee})
    else
      action
    end
  end

  defp maybe_put_builder(action, _exchange), do: action

  # --- transfer -------------------------------------------------------------

  defp build_transfer(params, code, amount, from_account, to_account, exchange, opts) do
    nonce = nonce(params, opts)

    cond do
      class_transfer?(from_account, to_account) ->
        build_usd_class_transfer(params, amount, to_account, exchange, nonce)

      main_sub_transfer?(from_account, to_account) ->
        build_sub_account_transfer(params, code, amount, from_account, to_account, nonce)

      true ->
        params
    end
  end

  defp class_transfer?(from, to) do
    from in ~w(spot swap perp) and to in ~w(spot swap perp)
  end

  defp main_sub_transfer?(from, to) do
    from == "main" or to == "main"
  end

  # Official docs: usdClassTransfer — spot ↔ perp USDC class transfer.
  # https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/exchange-endpoint
  # Python SDK: Exchange.usd_class_transfer/2
  defp build_usd_class_transfer(params, amount, to_account, exchange, nonce) do
    to_perp? = to_account in ~w(swap perp)
    chain = hyperliquid_chain(exchange)

    str_amount =
      case vault_address(params) do
        nil -> number_string(amount)
        vault -> number_string(amount) <> " subaccount:" <> vault
      end

    # Field order matches the provider wire shape.
    action = %{
      "hyperliquidChain" => chain,
      "signatureChainId" => "0x66eee",
      "type" => "usdClassTransfer",
      "amount" => str_amount,
      "toPerp" => to_perp?,
      "nonce" => nonce
    }

    params
    |> put_action_nonce(action, nonce)
    |> drop_transfer_unified_keys()
  end

  # Official docs / SDK: subAccountTransfer — main ↔ sub USDC (usd in 1e6 units).
  defp build_sub_account_transfer(params, code, amount, from_account, to_account, nonce) do
    if usdc_code?(code) do
      {sub_account, is_deposit?} =
        if from_account == "main" do
          {to_account, true}
        else
          {from_account, false}
        end

      usd = amount_to_micro_usd(amount)

      action = %{
        "type" => "subAccountTransfer",
        "subAccountUser" => sub_account,
        "isDeposit" => is_deposit?,
        "usd" => usd
      }

      params
      |> put_action_nonce(action, nonce)
      |> drop_transfer_unified_keys()
    else
      params
    end
  end

  defp usdc_code?(nil), do: true
  defp usdc_code?(code) when is_binary(code), do: String.upcase(code) == "USDC"
  defp usdc_code?(_), do: false

  defp amount_to_micro_usd(amount) when is_integer(amount), do: amount * 1_000_000

  defp amount_to_micro_usd(amount) when is_float(amount) do
    amount
    |> Decimal.from_float()
    |> Decimal.mult(Decimal.new(1_000_000))
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end

  defp amount_to_micro_usd(amount) when is_binary(amount) do
    amount
    |> Decimal.new()
    |> Decimal.mult(Decimal.new(1_000_000))
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end

  defp amount_to_micro_usd(amount) do
    raise Error.invalid_parameters(
            message: "hyperliquid action build: expected numeric amount, got #{inspect(amount)}",
            exchange: "hyperliquid",
            raw: %{"reason" => "invalid_amount", "value" => amount}
          )
  end

  defp hyperliquid_chain(%Exchange{sandbox: true}), do: "Testnet"
  defp hyperliquid_chain(%Exchange{}), do: "Mainnet"

  # --- shared ---------------------------------------------------------------

  defp put_action_nonce(params, action, nonce) do
    params
    |> Map.put("action", action)
    |> Map.put("nonce", nonce)
  end

  defp ensure_nonce(params, opts) do
    if present?(params, "nonce") do
      params
    else
      Map.put(params, "nonce", nonce(params, opts))
    end
  end

  defp nonce(params, opts) do
    cond do
      is_integer(params["nonce"]) -> params["nonce"]
      is_integer(Keyword.get(opts, :timestamp_ms_override)) -> Keyword.get(opts, :timestamp_ms_override)
      true -> System.os_time(:millisecond)
    end
  end

  defp maybe_put_vault(params, source) do
    case vault_address(source) do
      nil -> params
      vault -> Map.put(params, "vaultAddress", vault)
    end
  end

  defp vault_address(params) do
    case params["vaultAddress"] || params["vault_address"] || params["subAccountAddress"] ||
           params["sub_account_address"] do
      addr when is_binary(addr) and addr != "" -> format_vault(addr)
      _ -> nil
    end
  end

  defp format_vault("0x" <> rest), do: String.downcase(rest)
  defp format_vault("0X" <> rest), do: String.downcase(rest)
  defp format_vault(addr) when is_binary(addr), do: String.downcase(addr)

  defp drop_cancel_unified_keys(params) do
    Map.drop(params, ["id", "ids", "symbol", "clientOrderId", "client_order_id"])
  end

  defp drop_transfer_unified_keys(params) do
    Map.drop(params, [
      "code",
      "amount",
      "from_account",
      "to_account",
      "fromAccount",
      "toAccount",
      "vaultAddress",
      "vault_address",
      "subAccountAddress",
      "sub_account_address"
    ])
  end

  # L1 `"a"` is Market.asset_index only (carve C-T339). Do not fall
  # back to id/base_id — those keep market-identity semantics and are often nil
  # on live loadMarkets, so a fallback would silently address the wrong asset.
  #
  # Three answers, not one: markets never loaded (setup, keep raising),
  # no matching symbol (caller input), and a matched market with no usable
  # asset_index (incomplete market data, keep raising). The nil guard is
  # `is_nil/1` because asset_index is 0-based — truthiness would treat the
  # first universe row as missing.
  defp asset_index(%Exchange{markets: nil}, symbol) when is_binary(symbol) do
    raise ArgumentError, "hyperliquid action build: markets are not loaded for #{symbol}"
  end

  defp asset_index(%Exchange{} = exchange, symbol) when is_binary(symbol) do
    case find_market(exchange, symbol) do
      nil ->
        raise Error.bad_symbol(
                message: "hyperliquid action build: no market for #{symbol}",
                exchange: "hyperliquid",
                raw: %{"reason" => "unknown_symbol", "symbol" => symbol}
              )

      market ->
        asset_index_from_market(market, symbol)
    end
  end

  defp asset_index_from_market(market, symbol) do
    case market_asset_index(market) do
      idx when not is_nil(idx) -> parse_market_asset_index!(idx, symbol)
      nil -> raise ArgumentError, "hyperliquid action build: loaded market has no asset_index for #{symbol}"
    end
  end

  defp market_asset_index(%{asset_index: idx}) when not is_nil(idx), do: idx
  defp market_asset_index(%{"asset_index" => idx}) when not is_nil(idx), do: idx
  defp market_asset_index(%{"assetIndex" => idx}) when not is_nil(idx), do: idx
  defp market_asset_index(_market), do: nil

  # Unified `RequestShape.apply` may receive either the Bourse unified symbol
  # (`SOL/USDC:USDC`) or the already-denormalized exchange id (`SOLUSDC`) —
  # `build_final_params` denormalizes before apply. Match both shapes against
  # the markets cache (raw maps in recorded-response replay, `%Market{}` live).
  defp find_market(%Exchange{markets: markets} = exchange, symbol) when is_list(markets) do
    Enum.find(markets, fn market -> market_matches_symbol?(market, symbol, exchange) end)
  end

  defp find_market(%Exchange{markets: markets} = exchange, symbol) when is_map(markets) do
    Map.get(markets, symbol) ||
      Enum.find_value(markets, fn {_k, market} ->
        if market_matches_symbol?(market, symbol, exchange), do: market
      end)
  end

  defp find_market(_exchange, _symbol), do: nil

  defp market_matches_symbol?(market, symbol, exchange) do
    market_symbol = market_field(market, "symbol") || market_field(market, :symbol)
    market_id = market_field(market, "id") || market_field(market, :id)

    cond do
      market_symbol == symbol -> true
      is_binary(market_id) and market_id == symbol -> true
      is_binary(market_symbol) and Symbol.to_exchange_id(market_symbol, exchange) == symbol -> true
      true -> false
    end
  end

  defp market_field(market, key) when is_map(market), do: Map.get(market, key)
  defp market_field(_market, _key), do: nil

  defp parse_int_param!(value) do
    case parse_int(value) do
      {:ok, int} -> int
      :error -> reject_invalid_integer!(value)
    end
  end

  defp parse_market_asset_index!(value, symbol) do
    case parse_int(value) do
      {:ok, int} ->
        int

      :error ->
        raise ArgumentError, "hyperliquid action build: loaded market has no asset_index for #{symbol}"
    end
  end

  defp parse_int(value) when is_integer(value), do: {:ok, value}

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_int(_value), do: :error

  defp reject_invalid_integer!(value) do
    raise Error.invalid_parameters(
            message: "hyperliquid action build: expected integer, got #{inspect(value)}",
            exchange: "hyperliquid",
            raw: %{"reason" => "invalid_integer", "value" => value}
          )
  end

  # Hyperliquid L1 wire form for p/s (and transfer amounts): no trailing zeros.
  # Authority: official SDK `float_to_wire` — Decimal.normalize after parse —
  # and docs: "if implementing signing, trailing zeroes should be removed."
  # Binary inputs must take the same path as floats; passthrough of a
  # non-canonical string (e.g. "0.00020") signs different msgpack bytes than
  # the venue reconstructs → garbage recovered signer ("User or API Wallet … does not exist").
  defp number_string(nil), do: "0"
  defp number_string(value) when is_integer(value), do: Integer.to_string(value)

  defp number_string(value) when is_float(value) do
    value |> Decimal.from_float() |> Decimal.normalize() |> Decimal.to_string(:normal)
  end

  defp number_string(%Decimal{} = value), do: value |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp number_string(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} ->
        decimal |> Decimal.normalize() |> Decimal.to_string(:normal)

      _ ->
        raise Error.invalid_parameters(
                message: "hyperliquid action build: expected numeric string, got #{inspect(value)}",
                exchange: "hyperliquid",
                raw: %{"reason" => "invalid_numeric", "value" => value}
              )
    end
  end

  defp number_string(value) do
    raise Error.invalid_parameters(
            message: "hyperliquid action build: expected number, got #{inspect(value)}",
            exchange: "hyperliquid",
            raw: %{"reason" => "invalid_numeric", "value" => value}
          )
  end

  defp present?(params, key), do: not is_nil(Map.get(params, key))

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false
end
