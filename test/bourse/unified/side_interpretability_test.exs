defmodule Bourse.Unified.SideInterpretabilityTest do
  @moduledoc """
  Uninterpretable `side` values must never become a direction.

  Task 663 refused a positional `:side`. This module pins the whole class:
  nested `orders[]` entries, methods whose required params do not name
  `:side`, and RequestShape helpers that used to default an unmatched value
  to buy or sell.
  """

  use ExUnit.Case, async: true

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Unified
  alias Bourse.Unified.RequestShape

  @invalid_sides [:sell, :buy, "hold", 1]

  describe "unified write boundary" do
    test "every method_defs entry that can carry a side refuses an uninterpretable value" do
      for {method, _js_name, required, _description} <- Unified.method_defs(),
          params <- side_carrier_params(required) do
        for side <- @invalid_sides do
          assert {:error, %Error{type: :invalid_parameters} = error} =
                   Unified.validate_param_values(put_invalid_side(params, side), method),
                 "#{method} accepted #{inspect(side)} in #{inspect(params)}"

          assert error.message =~ "Invalid side: #{inspect(side)}"
          assert error.message =~ ~s(Accepted forms: "buy" or "sell")
          assert error.raw["reason"] == "invalid_side"
          assert error.raw["accepted"] == ["buy", "sell"]
          assert error.raw["side"] == inspect(side)
        end
      end
    end

    test "a side nested under a key the method table does not name is still refused" do
      params = %{"payload" => %{"batch" => [%{"side" => :sell}]}}

      assert {:error, %Error{type: :invalid_parameters} = error} =
               Unified.validate_param_values(params, :fetch_ticker)

      assert error.raw["reason"] == "invalid_side"
      assert error.message =~ "Invalid side: :sell"
    end

    test "string buy and sell in a two-entry batch still pass the boundary" do
      params = %{
        "orders" => [
          %{"amount" => 1, "price" => 1, "side" => "buy", "symbol" => "BTC/USDT", "type" => "limit"},
          %{"amount" => 1, "price" => 2, "side" => "sell", "symbol" => "BTC/USDT", "type" => "limit"}
        ]
      }

      assert {:ok, ^params} = Unified.validate_param_values(params, :create_orders)
    end

    test "refusal does not depend on sanity or loaded markets" do
      exchange = Exchange.new!("deribit", sandbox: true)
      assert exchange.markets == nil

      orders = [%{amount: 10, price: 1, side: :sell, symbol: "BTC/USD:BTC", type: "limit"}]

      assert {:error, %Error{type: :invalid_parameters} = error} = Bourse.create_orders(exchange, orders)

      assert error.raw["reason"] == "invalid_side"
      assert error.message =~ ~s(Accepted forms: "buy" or "sell")
    end

    test "every public batch write that takes orders refuses a nested atom side" do
      exchange = Exchange.new!("deribit", sandbox: true)
      orders = [%{amount: 10, price: 1, side: :sell, symbol: "BTC/USD:BTC", type: "limit"}]

      for {method, _js_name, required, _description} <- Unified.method_defs(), :orders in required do
        assert {:error, %Error{type: :invalid_parameters} = error} = apply(Bourse, method, [exchange, orders]),
               "#{method} did not refuse a nested atom side"

        assert error.raw["reason"] == "invalid_side"
      end
    end
  end

  describe "RequestShape does not map an unmatched side to a direction" do
    test "Hyperliquid buy_side? refuses atoms, unknown strings, and numbers" do
      exchange = Exchange.new!("hyperliquid", sandbox: true)

      for {params, js_name} <- hyperliquid_side_shapes() do
        for side <- @invalid_sides do
          error =
            assert_raise Error, fn ->
              RequestShape.apply(put_invalid_side(params, side), exchange, js_name)
            end

          assert error.type == :invalid_parameters, "#{js_name} #{inspect(side)}"
          assert error.raw["reason"] == "invalid_side"
          assert error.message =~ inspect(side)
        end
      end
    end

    test "Bybit hedged position index refuses an unmatched side" do
      exchange = Exchange.new!("bybit", sandbox: true)

      params = %{
        "amount" => 1,
        "category" => "linear",
        "hedged" => true,
        "price" => 1,
        "side" => "hold",
        "symbol" => "BTC/USDT:USDT",
        "type" => "limit"
      }

      error =
        assert_raise Error, fn ->
          RequestShape.apply(params, exchange, "createOrder")
        end

      assert error.type == :invalid_parameters
      assert error.raw["reason"] == "invalid_side"
    end

    # Per-venue audit of RequestShape side-to-direction mappings (task 665).
    # alpaca / coinbaseexchange / deribit — no RequestShape module.
    # binance family — String.upcase; a non-binary side crashes rather than
    # becoming BUY/SELL.
    # bybit — position_index/opposite refuse unmatched (were catch-all 2/"buy").
    # derive — buy_or_sell! refuses unmatched (was `side == "buy"` → sell hash).
    # hyperliquid — buy_side? refuses unmatched (was catch-all false → SELL).
    # lighter — side_is_ask! already refused.
    # okx — order side is passed through; posSide is set only for exact
    # "buy"/"sell" or omitted.
    test "no RequestShape clause defaults an unmatched side to a direction" do
      violations =
        "lib/bourse/unified/request_shape"
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.flat_map(&direction_default_clauses/1)

      assert violations == [],
             """
             A RequestShape catch-all mapped an unmatched side to a direction:

             #{Enum.join(violations, "\n")}
             """
    end
  end

  defp side_carrier_params(required) do
    cond do
      :side in required and :orders in required ->
        [%{"side" => :placeholder}, %{"orders" => [%{"side" => :placeholder}]}]

      :side in required ->
        [%{"side" => :placeholder}]

      :orders in required ->
        [%{"orders" => [%{"side" => :placeholder}]}]

      true ->
        []
    end
  end

  defp put_invalid_side(%{"orders" => [order]}, side) when is_map(order) do
    %{"orders" => [Map.put(order, "side", side)]}
  end

  defp put_invalid_side(%{"side" => _old} = params, side), do: Map.put(params, "side", side)

  defp put_invalid_side(params, side) when is_map(params), do: Map.put(params, "side", side)

  defp hyperliquid_side_shapes do
    twap = %{"amount" => 1, "duration" => 60_000, "side" => "buy", "symbol" => "BTC/USDC:USDC"}

    batch = %{
      "orders" => [
        %{"amount" => 1, "price" => 1, "side" => "buy", "symbol" => "BTC/USDC:USDC", "type" => "limit"}
      ]
    }

    [{twap, "createTwapOrder"}, {batch, "createOrders"}]
  end

  defp direction_default_clauses(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!(file: path)

    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:defp, meta, [{name, _name_meta, args}, [do: body]]} = node, acc ->
          {node, maybe_violation(path, meta[:line], name, args, body) ++ acc}

        {:def, meta, [{name, _name_meta, args}, [do: body]]} = node, acc ->
          {node, maybe_violation(path, meta[:line], name, args, body) ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp maybe_violation(path, line, name, args, body) when is_list(args) do
    if unary_catch_all_side?(name, args) and direction_literal?(body) do
      ["#{path}:#{line} #{name}/#{length(args)} defaults unmatched side to #{inspect(body)}"]
    else
      []
    end
  end

  defp maybe_violation(_path, _line, _name, _args, _body), do: []

  defp unary_catch_all_side?(name, args) when is_atom(name) and is_list(args) do
    name_string = Atom.to_string(name)
    side_named_fn? = String.contains?(name_string, "side")
    unmatched_args? = args != [] and Enum.all?(args, &variable_arg?/1)

    cond do
      not unmatched_args? ->
        false

      length(args) == 1 and (side_named_fn? or Enum.any?(args, &side_arg_name?/1)) ->
        true

      side_named_fn? ->
        true

      true ->
        false
    end
  end

  defp unary_catch_all_side?(_name, _args), do: false

  defp variable_arg?({name, _meta, ctx}) when is_atom(name) and not is_list(ctx), do: true
  defp variable_arg?(_arg), do: false

  defp side_arg_name?({name, _meta, _ctx}) when is_atom(name) do
    name_string = name |> Atom.to_string() |> String.trim_leading("_")
    name_string == "side" or String.contains?(name_string, "side")
  end

  defp side_arg_name?(_arg), do: false

  defp direction_literal?(true), do: true
  defp direction_literal?(false), do: true
  defp direction_literal?("buy"), do: true
  defp direction_literal?("sell"), do: true
  defp direction_literal?(1), do: true
  defp direction_literal?(2), do: true
  defp direction_literal?(_body), do: false
end
