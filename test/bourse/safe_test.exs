defmodule Bourse.SafeTest do
  use ExUnit.Case, async: true

  alias Bourse.Safe

  # Identity typed as term() so dialyzer can't narrow a deliberately-bad
  # argument and flag a negative (guard-failure) test as unreachable.
  @spec term(term()) :: term()
  defp term(x), do: x

  describe "value/3 — flat map and list access" do
    test "nil key returns default" do
      assert Safe.value(%{"a" => 1}, nil, :def) == :def
    end

    test "reads a present string key" do
      assert Safe.value(%{"a" => 1}, "a", :def) == 1
    end

    test "reads via atom/string key variants" do
      assert Safe.value(%{a: 1}, "a", :def) == 1
      assert Safe.value(%{"a" => 1}, :a, :def) == 1
    end

    test "missing key returns default" do
      assert Safe.value(%{"a" => 1}, "b", :def) == :def
    end

    test "nil and empty-string values fall through to default" do
      assert Safe.value(%{"a" => nil}, "a", :def) == :def
      assert Safe.value(%{"a" => ""}, "a", :def) == :def
    end

    test "list index access" do
      assert Safe.value([10, 20, 30], 1, :def) == 20
      assert Safe.value([10], 5, :def) == :def
    end

    test "non-map, non-list data returns default" do
      assert Safe.value("scalar", "a", :def) == :def
      assert Safe.value(42, 0, :def) == :def
    end
  end

  describe "value/3 — nested dotted key paths" do
    @nested %{
      "stats" => %{"high" => "73641.74", "low" => "68933.02"},
      "top" => "1"
    }

    test "reads a nested value through a dotted path" do
      assert Safe.value(@nested, "stats.high", :def) == "73641.74"
      assert Safe.value(@nested, "stats.low", :def) == "68933.02"
    end

    test "missing leaf in an existing nested map returns default" do
      assert Safe.value(@nested, "stats.max_price", :def) == :def
    end

    test "missing intermediate segment returns default" do
      assert Safe.value(@nested, "absent.high", :def) == :def
    end

    test "dotted path into a non-map intermediate returns default" do
      assert Safe.value(@nested, "top.high", :def) == :def
    end

    test "deeper-than-two-level path" do
      data = %{"a" => %{"b" => %{"c" => "deep"}}}
      assert Safe.value(data, "a.b.c", :def) == "deep"
      assert Safe.value(data, "a.b.x", :def) == :def
    end

    test "a flat key without a dot is unaffected" do
      assert Safe.value(@nested, "top", :def) == "1"
    end
  end

  describe "value_any/3" do
    test "returns the first present, non-empty key" do
      assert Safe.value_any(%{"a" => "", "b" => "x"}, ["a", "b"], :def) == "x"
    end

    test "falls back across a dotted key list (Bourse safeString2 over nested)" do
      data = %{"stats" => %{"max_price" => "74835.36"}}
      assert Safe.value_any(data, ["stats.high", "stats.max_price", "high"], :def) == "74835.36"
    end

    test "default when no key present" do
      assert Safe.value_any(%{"a" => 1}, ["x", "y"], :def) == :def
    end

    test "non-list keys argument is unsupported (guard)" do
      # `term/1` launders the deliberately-bad (non-list) keys arg past
      # dialyzer's success-typing check while still exercising the guard.
      assert_raise FunctionClauseError, fn -> Safe.value_any(%{}, term("a"), :def) end
    end
  end

  describe "string/1 and string_lower/1" do
    test "string coerces scalars, drops the rest" do
      assert Safe.string("x") == "x"
      assert Safe.string(5) == "5"
      assert Safe.string(1.5) == "1.5"
      assert Safe.string(true) == "true"
      assert Safe.string(nil) == nil
      assert Safe.string(%{}) == nil
    end

    test "string_lower downcases" do
      assert Safe.string_lower("OKX") == "okx"
      assert Safe.string_lower(nil) == nil
    end
  end

  describe "integer/1" do
    test "coerces integers, floats, and numeric strings" do
      assert Safe.integer(7) == 7
      assert Safe.integer(7.9) == 7
      assert Safe.integer("  42 ") == 42
      assert Safe.integer("") == nil
      assert Safe.integer("nope") == nil
      assert Safe.integer(nil) == nil
      assert Safe.integer(%{}) == nil
    end
  end

  describe "number/1" do
    test "coerces numbers and numeric strings" do
      assert Safe.number(7) == 7
      assert Safe.number(7.5) == 7.5
      assert Safe.number(" 10.4727 ") == 10.4727
      assert Safe.number("") == nil
      assert Safe.number("nope") == nil
      assert Safe.number(nil) == nil
      assert Safe.number(%{}) == nil
    end
  end

  describe "bool/1" do
    test "coerces booleans, numbers, and strings" do
      assert Safe.bool(true) == true
      assert Safe.bool(0) == false
      assert Safe.bool(0.0) == false
      assert Safe.bool(3) == true
      assert Safe.bool("true") == true
      assert Safe.bool("1") == true
      assert Safe.bool("false") == false
      assert Safe.bool("0") == false
      assert Safe.bool("maybe") == nil
      assert Safe.bool(nil) == nil
      assert Safe.bool(%{}) == nil
    end
  end
end
