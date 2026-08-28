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

    test "a keyword-list order entry with an atom side is refused as invalid_side" do
      params = %{"orders" => [[side: :sell, symbol: "BTC/USDT", amount: 1, price: 1, type: "limit"]]}

      assert {:error, %Error{type: :invalid_parameters} = error} =
               Unified.validate_param_values(params, :create_orders)

      assert error.raw["reason"] == "invalid_side"
      assert error.message =~ "Invalid side: :sell"
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

    test "Bybit attached trigger direction refuses an unmatched side" do
      exchange = Exchange.new!("bybit", sandbox: true)

      params = %{
        "amount" => 1,
        "category" => "linear",
        "price" => 1,
        "side" => "hold",
        "stopLossPrice" => 1,
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

    test "OKX closePosition refuses an unmatched side rather than forwarding it as posSide" do
      exchange = Exchange.new!("okx", sandbox: true)
      params = %{"side" => "shrot", "symbol" => "BTC/USDT:USDT"}

      error =
        assert_raise Error, fn ->
          RequestShape.apply(params, exchange, "closePosition")
        end

      assert error.type == :invalid_parameters
      assert error.raw["reason"] == "invalid_side"
      assert error.message =~ ~s(Invalid side: "shrot")
    end

    # Per-venue audit of RequestShape side-to-direction mappings (task 665).
    # alpaca / coinbaseexchange / deribit — no RequestShape module.
    # binance family — String.upcase; a non-binary side crashes rather than
    # becoming BUY/SELL.
    # bybit — position_index/opposite/attached_trigger_direction refuse unmatched
    # (were catch-all 2/"buy"/1).
    # derive — buy_or_sell! refuses unmatched (was `side == "buy"` → sell hash).
    # hyperliquid — buy_side? refuses unmatched (was catch-all false → SELL).
    # lighter — side_is_ask! already refused.
    # okx — order side is passed through; closePosition unmatched is refused
    # (was forwarded as posSide).
    test "no RequestShape clause defaults an unmatched side to a direction" do
      violations =
        Enum.flat_map(
          ["lib/bourse/unified/request_shape.ex" | Path.wildcard("lib/bourse/unified/request_shape/**/*.ex")],
          &direction_default_clauses/1
        )

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
    funs = collect_fun_clauses(ast)
    grouped = Enum.group_by(funs, &{&1.name, length(&1.args)})

    clause_violations =
      Enum.flat_map(funs, fn fun ->
        siblings = Map.fetch!(grouped, {fun.name, length(fun.args)})
        maybe_clause_violation(path, fun, siblings)
      end)

    case_violations = Enum.flat_map(funs, &case_and_cond_violations(path, &1))
    clause_violations ++ case_violations
  end

  defp collect_fun_clauses(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:def, meta, [{:when, _, [{name, _, args}, _guard]}, [do: body]]} = node, acc when is_atom(name) ->
          {node, [fun_clause(name, args, body, meta) | acc]}

        {:defp, meta, [{:when, _, [{name, _, args}, _guard]}, [do: body]]} = node, acc when is_atom(name) ->
          {node, [fun_clause(name, args, body, meta) | acc]}

        {:def, meta, [{name, _, args}, [do: body]]} = node, acc when is_atom(name) ->
          {node, [fun_clause(name, args, body, meta) | acc]}

        {:defp, meta, [{name, _, args}, [do: body]]} = node, acc when is_atom(name) ->
          {node, [fun_clause(name, args, body, meta) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp fun_clause(name, args, body, meta) do
    %{name: name, args: args || [], body: body, line: meta[:line]}
  end

  defp maybe_clause_violation(path, fun, siblings) do
    if catch_all_args?(fun.args) and direction_literal?(fun.body) and side_family?(fun, siblings) do
      [
        "#{path}:#{fun.line} #{fun.name}/#{length(fun.args)} defaults unmatched side to #{inspect(fun.body)}"
      ]
    else
      []
    end
  end

  defp case_and_cond_violations(path, fun) do
    {_ast, acc} =
      Macro.prewalk(fun.body, [], fn
        {:case, meta, [_expr, [do: clauses]]} = node, acc when is_list(clauses) ->
          {node, maybe_branch_violation(path, meta[:line], fun, :case, clauses) ++ acc}

        {:cond, meta, [[do: clauses]]} = node, acc when is_list(clauses) ->
          {node, maybe_branch_violation(path, meta[:line], fun, :cond, clauses) ++ acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp maybe_branch_violation(path, line, fun, kind, clauses) do
    {catch_alls, specifics} = Enum.split_with(clauses, &catch_all_arrow?/1)

    Enum.flat_map(catch_alls, fn {:->, _meta, [_left, body]} ->
      if direction_literal?(body) and (side_named_fun?(fun) or mentions_buy_or_sell?(specifics)) do
        [
          "#{path}:#{line} #{fun.name}/#{length(fun.args)} #{kind} catch-all defaults unmatched side to #{inspect(body)}"
        ]
      else
        []
      end
    end)
  end

  defp catch_all_arrow?({:->, _meta, [[true], _body]}), do: true
  defp catch_all_arrow?({:->, _meta, [left, _body]}), do: Enum.all?(List.wrap(left), &catch_all_pattern?/1)
  defp catch_all_arrow?(_clause), do: false

  defp catch_all_pattern?({:when, _meta, _args}), do: false
  defp catch_all_pattern?(pattern), do: variable_arg?(pattern)

  defp catch_all_args?(args) when is_list(args) and args != [], do: Enum.all?(args, &variable_arg?/1)
  defp catch_all_args?(_args), do: false

  defp side_family?(fun, siblings) do
    side_named_fun?(fun) or Enum.any?(siblings, &clause_mentions_buy_or_sell?/1)
  end

  defp side_named_fun?(fun) do
    name_string = Atom.to_string(fun.name)
    String.contains?(name_string, "side") or Enum.any?(fun.args, &side_arg_name?/1)
  end

  defp clause_mentions_buy_or_sell?(fun), do: mentions_buy_or_sell?(fun.args) or mentions_buy_or_sell?(fun.body)

  defp mentions_buy_or_sell?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        "buy", _acc -> {"buy", true}
        "sell", _acc -> {"sell", true}
        :buy, _acc -> {:buy, true}
        :sell, _acc -> {:sell, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp variable_arg?({:_, _meta, _ctx}), do: true
  defp variable_arg?({name, _meta, ctx}) when is_atom(name) and not is_list(ctx), do: true
  defp variable_arg?(_arg), do: false

  defp side_arg_name?({name, _meta, _ctx}) when is_atom(name) do
    name_string = name |> Atom.to_string() |> String.trim_leading("_")
    name_string != "" and (name_string == "side" or String.contains?(name_string, "side"))
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
