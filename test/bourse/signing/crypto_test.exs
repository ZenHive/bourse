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
  end
end
