defmodule Bourse.Signing.CryptoTest do
  @moduledoc "Coverage for the shared DEX crypto primitives."
  use ExUnit.Case, async: true

  alias Bourse.Signing.Crypto

  describe "keccak256/1" do
    test "hashes a binary" do
      assert "" |> Crypto.keccak256() |> Base.encode16(case: :lower) ==
               "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
    end

    test "accepts iodata" do
      assert Crypto.keccak256(["ab", ?c]) == Crypto.keccak256("abc")
    end
  end

  describe "strip_0x/1" do
    test "strips lowercase and uppercase prefixes, passes through bare hex" do
      assert Crypto.strip_0x("0xdeadbeef") == "deadbeef"
      assert Crypto.strip_0x("0XDEADBEEF") == "DEADBEEF"
      assert Crypto.strip_0x("deadbeef") == "deadbeef"
    end
  end

  describe "decode_private_key/1" do
    test "takes the last 64 hex chars, 0x-prefixed or not" do
      key = "0x0123456789012345678901234567890123456789012345678901234567890123"
      assert byte_size(Crypto.decode_private_key(key)) == 32
      assert Crypto.decode_private_key(key) == Crypto.decode_private_key(String.trim_leading(key, "0x"))
    end
  end

  describe "decode_hex/1 and encode_hex/1 round-trip" do
    test "round-trips through hex" do
      assert "0x" |> Kernel.<>("00ff10") |> Crypto.decode_hex() |> Crypto.encode_hex() == "00ff10"
    end
  end

  describe "sign_hash/2" do
    @key Crypto.decode_private_key("0x0123456789012345678901234567890123456789012345678901234567890123")

    test "returns r/s hex and v = 27 + recovery_id" do
      digest = Crypto.keccak256("message")
      sig = Crypto.sign_hash(digest, @key)

      assert sig.r =~ ~r/\A[0-9a-f]{64}\z/
      assert sig.s =~ ~r/\A[0-9a-f]{64}\z/
      assert sig.v in [27, 28]
    end

    test "raises on an invalid private key" do
      digest = Crypto.keccak256("message")

      assert_raise ArgumentError, ~r/secp256k1 sign failed/, fn ->
        Crypto.sign_hash(digest, <<0::256>>)
      end
    end

    test "rejects a binary digest that is not exactly 32 bytes" do
      short = :binary.copy(<<0xAA>>, 31)

      assert_raise FunctionClauseError, fn ->
        Crypto.sign_hash(short, @key)
      end
    end

    test "rejects a non-binary private key" do
      digest = Crypto.keccak256("message")

      assert_raise FunctionClauseError, fn ->
        Crypto.sign_hash(digest, untyped(:not_a_binary_key))
      end
    end
  end

  describe "hash_message/1, sign_message/2, recover_signer_address/2" do
    @private_key "0x0123456789012345678901234567890123456789012345678901234567890123"
    @vector_message "1700000000000"
    @vector_hash "1362375365df31a82fb5331c8b5ae150f25d8ee09c8431ae46bac7625862136a"
    @vector_signature "0xe65c3e066894a1631220983b5da8617e21512ead950bb3ec6f38899349ebbe8d5f9111ffd4fa1bdfde707eae5f752ccdf11f3b5911ba014e92c2b9a50140b6a71b"

    test "hash_message matches the Derive personal-message vector" do
      assert @vector_message |> Crypto.hash_message() |> Base.encode16(case: :lower) == @vector_hash
    end

    test "sign_message matches the Derive packed signature vector" do
      assert Crypto.sign_message(@vector_message, private_key: @private_key) == @vector_signature
    end

    test "sign_message requires :private_key" do
      assert_raise ArgumentError, ~r/private_key/, fn ->
        Crypto.sign_message(@vector_message, [])
      end
    end

    test "recover_signer_address round-trips a packed EIP-191 signature" do
      signature = Crypto.sign_message(@vector_message, private_key: @private_key)
      assert {:ok, address} = Crypto.recover_signer_address(@vector_message, signature)
      assert address =~ ~r/^0x[0-9a-f]{40}$/
      assert {:ok, ^address} = Crypto.recover_signer_address(@vector_message, signature)
    end

    test "recover_signer_address rejects a malformed packed signature" do
      assert {:error, :invalid_signature} =
               Crypto.recover_signer_address(@vector_message, "0x" <> String.duplicate("00", 65))

      assert {:error, :invalid_signature} = Crypto.recover_signer_address(@vector_message, "not-a-signature")
    end

    test "EIP-191 envelope uses byte_size, not UTF-8 length" do
      # "é" is one grapheme (String.length 1) and two UTF-8 bytes. EIP-191
      # prefixes the byte length; Cartouche.Recover.prefix_eth/1 uses String.length.
      message = "é"
      envelope = "\x19Ethereum Signed Message:\n" <> Integer.to_string(byte_size(message)) <> message
      assert Crypto.hash_message(message) == Crypto.keccak256(envelope)
      refute Crypto.hash_message(message) == Crypto.keccak256(Cartouche.Recover.prefix_eth(message))
    end
  end

  describe "address derivation, low-s, and recovery conventions" do
    # Yellow-paper / libsecp256k1 well-known vector: privkey 1 → this address.
    @privkey_one <<1::256>>
    @address_one "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf"

    test "address_from_private_key matches the secp256k1 privkey-1 vector" do
      assert Crypto.address_from_private_key(@privkey_one) == @address_one
      assert Crypto.address_from_private_key("0x" <> String.duplicate("00", 31) <> "01") == @address_one
    end

    test "sign_hash emits canonical low-s and Ethereum v = 27 + recovery_id" do
      digest = Crypto.keccak256("low-s vector")
      sig = Crypto.sign_hash(digest, @privkey_one)
      s = String.to_integer(sig.s, 16)

      assert s > 0
      assert s <= Crypto.secp256k1_half_n()
      assert Crypto.secp256k1_n() == 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
      assert sig.v in [27, 28]
      assert byte_size(sig.r) == 64
      assert byte_size(sig.s) == 64
    end

    test "recover_signer_address recovers privkey-1 from an EIP-191 signature" do
      signature = Crypto.sign_message("hello", private_key: "0x" <> String.duplicate("00", 31) <> "01")
      assert {:ok, @address_one} = Crypto.recover_signer_address("hello", signature)
    end
  end

  # Hides the value from compile-time type inference so the runtime guard, not the
  # type checker, is what rejects it.
  defp untyped(value), do: Enum.random([value])
end
