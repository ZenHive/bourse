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

    test "rejects malformed uintN/bytesN and unknown lowercase types" do
      for {type, value} <- [{"uint0", 1}, {"uint", 1}, {"bytes0", <<>>}, {"bytesfoo", <<>>}, {"bag", "x"}] do
        types = %{"Bad" => [%{"name" => "x", "type" => type}]}

        assert_raise ArgumentError, ~r/unsupported field type/, fn ->
          EIP712.hash_struct("Bad", types, %{"x" => value})
        end
      end
    end

    test "bytes16 is accepted as an atomic sized-bytes field" do
      types = %{"B" => [%{"name" => "h", "type" => "bytes16"}]}
      raw = :binary.copy(<<0xAB>>, 16)
      assert byte_size(EIP712.hash_struct("B", types, %{"h" => raw})) == 32
    end

    test "rejects a value whose Elixir type does not match the field" do
      types = %{"S" => [%{"name" => "x", "type" => "string"}]}

      assert_raise ArgumentError, ~r/unsupported field type/, fn ->
        EIP712.hash_struct("S", types, %{"x" => 5})
      end

      assert_raise ArgumentError, ~r/unsupported field/, fn ->
        EIP712.hash_struct("S", types, %{"x" => :atom})
      end
    end
  end

  describe "independently constructed EIP-712 vectors" do
    test "Ether Mail domain separator matches EIP-712 (ethers canonical fields)" do
      domain = %{
        "name" => "Ether Mail",
        "version" => "1",
        "chainId" => 1,
        "verifyingContract" => "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"
      }

      # EIP-712 example: https://eips.ethereum.org/EIPS/eip-712
      assert Base.encode16(EIP712.domain_separator(domain), case: :lower) ==
               "f2cee375fa42b42143804025fc449deafd50cc031ca257e0b194a650a912090f"
    end

    test "Person hashStruct matches encodeData built from the EIP-712 rules" do
      types = %{
        "Person" => [
          %{"name" => "name", "type" => "string"},
          %{"name" => "wallet", "type" => "address"}
        ]
      }

      message = %{
        "name" => "Cow",
        "wallet" => "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"
      }

      type_hash = Crypto.keccak256("Person(string name,address wallet)")
      name_hash = Crypto.keccak256("Cow")
      wallet = <<0xCD2A3D9F938E13CD947EC05ABC7FE734DF8DD826::160>>
      expected = Crypto.keccak256(type_hash <> name_hash <> <<0::96, wallet::binary>>)

      assert EIP712.hash_struct("Person", types, message) == expected
    end

    test "uint64 encodes as a 32-byte integer word, not as keccak of digits" do
      types = %{"Qty" => [%{"name" => "n", "type" => "uint64"}]}
      type_hash = Crypto.keccak256("Qty(uint64 n)")
      expected = Crypto.keccak256(type_hash <> <<7::256>>)
      assert EIP712.hash_struct("Qty", types, %{"n" => 7}) == expected
    end

    test "encode/4 hashes the named primary type, not a sibling with overlapping keys" do
      types = %{
        "Agent" => [
          %{"name" => "source", "type" => "string"},
          %{"name" => "connectionId", "type" => "bytes32"}
        ],
        "Other" => [
          %{"name" => "source", "type" => "string"},
          %{"name" => "connectionId", "type" => "bytes32"},
          %{"name" => "extra", "type" => "string"}
        ]
      }

      domain = %{"name" => "Exchange", "version" => "1", "chainId" => 1337}
      connection_id = :binary.copy(<<0xAB>>, 32)
      agent = %{"source" => "a", "connectionId" => connection_id}

      encoded = EIP712.encode(domain, types, "Agent", agent)
      assert encoded == <<0x19, 0x01>> <> EIP712.domain_separator(domain) <> EIP712.hash_struct("Agent", types, agent)

      refute EIP712.hash_struct("Agent", types, agent) ==
               EIP712.hash_struct("Other", types, Map.put(agent, "extra", "x"))
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
