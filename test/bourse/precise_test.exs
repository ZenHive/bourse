defmodule Bourse.PreciseTest do
  use ExUnit.Case, async: true

  alias Bourse.Precise

  doctest Precise

  # Compatibility vectors transcribed from the pinned CCXT reference corpus at
  # priv/specs/json/ccxt/ts/src/test/base/test.precise.ts.
  # Operand fixtures match Bourse's `w/x/y/z/a` exactly.
  @w "-1.123e-6"
  @x "0.00000002"
  @y "69696900000"
  @z "0"
  @a "1e8"

  describe "string_mul/2 compatibility" do
    test "commutative product, trailing zeros reduced" do
      assert Precise.string_mul(@x, @y) == "1393.938"
      assert Precise.string_mul(@y, @x) == "1393.938"
    end

    test "signed product with negative exponent operand" do
      assert Precise.string_mul(@x, @w) == "-0.00000000000002246"
      assert Precise.string_mul(@w, @x) == "-0.00000000000002246"
    end

    test "scientific-notation operand normalizes" do
      assert Precise.string_mul(@x, @a) == "2"
      assert Precise.string_mul(@a, @x) == "2"
      assert Precise.string_mul(@y, @a) == "6969690000000000000"
      assert Precise.string_mul(@a, @y) == "6969690000000000000"
    end

    test "zero operand yields '0' regardless of side" do
      for other <- [@w, @x, @y] do
        assert Precise.string_mul(@z, other) == "0"
        assert Precise.string_mul(other, @z) == "0"
      end
    end

    test "nil operand yields nil (Bourse undefined)" do
      assert Precise.string_mul(nil, @x) == nil
      assert Precise.string_mul(@x, nil) == nil
      assert Precise.string_mul(nil, nil) == nil
    end
  end

  describe "string_add/2" do
    test "adds decimal strings without float drift" do
      assert Precise.string_add("0.91974100", "0.00025900") == "0.92"
      assert Precise.string_add("1", "0") == "1"
      assert Precise.string_add(nil, "1") == nil
    end
  end

  describe "string_div/3 (Bourse stringDiv parity)" do
    test "default precision (18) truncates toward zero" do
      assert Precise.string_div(@x, @y) == "0"
      assert Precise.string_div(@y, @x) == "3484845000000000000"
      assert Precise.string_div(@a, @y) == "0.001434784043479695"
    end

    test "explicit precision controls decimal places" do
      assert Precise.string_div(@x, @y, 1) == "0"
      assert Precise.string_div(@x, @y, 19) == "0.0000000000000000002"
      assert Precise.string_div(@x, @y, 20) == "0.00000000000000000028"
      assert Precise.string_div(@x, @y, 21) == "0.000000000000000000286"
      assert Precise.string_div(@x, @y, 22) == "0.0000000000000000002869"
    end

    test "zero and negative precision round to whole/tens places" do
      assert Precise.string_div(@y, @a) == "696.969"
      assert Precise.string_div(@y, @a, 0) == "696"
      assert Precise.string_div(@y, @a, 1) == "696.9"
      assert Precise.string_div(@y, @a, 2) == "696.96"
      assert Precise.string_div(@y, @a, -1) == "690"
    end

    test "signed division truncates toward zero" do
      assert Precise.string_div(@x, @w) == "-0.017809439002671415"
      assert Precise.string_div(@w, @x) == "-56.15"
    end

    test "accepts provider decimals longer than Decimal's default parse limit" do
      numerator = "-2.6455959784245548835819950103759765625"
      divisor = "-132.2074413704858670826070010662078857421875"

      assert Precise.string_div(numerator, divisor, 4) == "0.02"
    end

    test "division by zero yields nil (Bourse undefined)" do
      assert Precise.string_div(@x, @z) == nil
      assert Precise.string_div("5", "0") == nil
    end

    test "nil operand yields nil" do
      assert Precise.string_div(nil, @x) == nil
      assert Precise.string_div(@x, nil) == nil
    end
  end
end
