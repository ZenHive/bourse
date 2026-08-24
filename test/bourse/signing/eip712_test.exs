defmodule Bourse.Signing.EIP712Test do
  @moduledoc "Field-encoding and error-path coverage for the EIP-712 encoder."
  use ExUnit.Case, async: true

  alias Bourse.Signing.Crypto
  alias Bourse.Signing.EIP712

  # A synthetic type exercising every supported atomic field encoder.
  @types %{
    "AllTypes" => [
      %{"name" => "s", "type" => "string"},
      %{"name" => "b", "type" => "bytes"},
      %{"name" => "h", "type" => "bytes32"},
      %{"name" => "a", "type" => "address"},
      %{"name" => "flag", "type" => "bool"},
      %{"name" => "n", "type" => "uint256"}
    ]
  }
  @domain %{"name" => "Test", "version" => "1", "chainId" => 1}

  test "hash_struct encodes string/bytes/bytes32/address/bool/uint fields" do
    message = %{
      "s" => "hello",
      "b" => <<1, 2, 3>>,
      "h" => "0x" <> String.duplicate("ab", 32),
      "a" => "0x" <> String.duplicate("11", 20),
      "flag" => true,
      "n" => 42
    }

    assert byte_size(EIP712.hash_struct("AllTypes", @types, message)) == 32
  end

  test "bool false and a raw 32-byte bytes32 binary both encode" do
    message = %{
      "s" => "x",
      "b" => "",
      "h" => :binary.copy(<<0xCD>>, 32),
      "a" => "0x" <> String.duplicate("22", 20),
      "flag" => false,
      "n" => 0
    }

    assert byte_size(EIP712.hash_struct("AllTypes", @types, message)) == 32
  end

  test "a raw 32-byte bytes32 binary encodes identically to its hex string" do
    # Nested struct hashes reach bytes32 fields as raw keccak output, never as hex.
    raw = Crypto.keccak256("nested struct hash")
    hex = "0x" <> Base.encode16(raw, case: :lower)

    assert byte_size(raw) == 32

    assert EIP712.hash_struct("AllTypes", @types, base_message(%{"h" => raw})) ==
             EIP712.hash_struct("AllTypes", @types, base_message(%{"h" => hex}))
  end

  test "domain_separator only includes present fields, in canonical order" do
    # Adding a field changes the EIP712Domain type string and thus the separator.
    with_contract = Map.put(@domain, "verifyingContract", "0x" <> String.duplicate("00", 20))
    assert byte_size(EIP712.domain_separator(@domain)) == 32
    refute EIP712.domain_separator(@domain) == EIP712.domain_separator(with_contract)
  end

  describe "error paths" do
    test "rejects a bytes32 of the wrong length" do
      message = base_message(%{"h" => "0xabcd"})

      assert_raise ArgumentError, ~r/bytes32 must be 32 bytes/, fn ->
        EIP712.hash_struct("AllTypes", @types, message)
      end
    end

    test "rejects an address of the wrong length" do
      message = base_message(%{"a" => "0xabcd"})

      assert_raise ArgumentError, ~r/address must be 20 bytes/, fn ->
        EIP712.hash_struct("AllTypes", @types, message)
      end
    end

    test "rejects an unsupported (struct) field type" do
      types = %{"Bad" => [%{"name" => "x", "type" => "Nested"}]}

      assert_raise ArgumentError, ~r/unsupported field/, fn ->
        EIP712.hash_struct("Bad", types, %{"x" => "value"})
      end
    end

    test "rejects an integer value for a non-numeric type" do
      types = %{"Bad" => [%{"name" => "x", "type" => "bytesfoo"}]}

      assert_raise ArgumentError, ~r/unsupported field type/, fn ->
        EIP712.hash_struct("Bad", types, %{"x" => 5})
      end
    end
  end

  defp base_message(overrides) do
    Map.merge(
      %{
        "s" => "x",
        "b" => "",
        "h" => "0x" <> String.duplicate("ab", 32),
        "a" => "0x" <> String.duplicate("11", 20),
        "flag" => true,
        "n" => 1
      },
      overrides
    )
  end
end
