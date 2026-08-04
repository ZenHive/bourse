defmodule Bourse.Signing.DeriveTest do
  @moduledoc """
  Deterministic cryptographic regression vectors for `Bourse.Signing.Derive`.

  Provenance: the pinned signatures were originally produced by running CCXT
  JS `signOrder` / `signMessage` (repo `../ccxt`) with the fixed test private
  key — an unverified authoring reference, not a semantic authority. They are
  kept as frozen regression vectors; venue semantics are established by the
  live Derive acceptance evidence, never by these vectors.
  """
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Signing
  alias Bourse.Signing.Derive

  @private_key "0x0123456789012345678901234567890123456789012345678901234567890123"
  @action_typehash "0x4d7a9f27c403ff9c0f19bce61d76d82f9aa29f8d6d4b0c5474607d9770d1af17"
  @trade_module "0xB8D20c2B7a1Ad2EE33Bc50eF10876eD3035b5e7b"
  @data_hash "0xaabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
  @wallet "0x108b9aF9279a525b8A8AeAbE7AC2bA925Bc50075"
  @order [
    @action_typehash,
    1,
    1_700_000_000_000,
    @trade_module,
    @data_hash,
    1_737_200_000,
    @wallet,
    @wallet
  ]
  @order_signature "0xad87490af8285ace67d6de949932cd4e2eea83a824811e0ddf8af6b606c4116f53ffc10544a4e775552b8f09d1e96eebc4b80dc4836f52b50ec558915e374a661c"

  describe "hash_order_message/2" do
    test "retains compatibility with CCXT hashOrderMessage" do
      assert @order |> Derive.hash_order_message() |> Base.encode16(case: :lower) ==
               "4b5d5fc519a09174ca351f0e2105c31094aff13748e5ecdd1aaab08286b5b9d3"
    end

    test "sandbox uses a different domain separator" do
      refute Derive.hash_order_message(@order, testnet: true) ==
               Derive.hash_order_message(@order, testnet: false)
    end
  end

  describe "sign_order/2" do
    test "byte-equal packed signature" do
      assert Derive.sign_order(@order, private_key: @private_key) == @order_signature
    end

    test "raises without a private key" do
      assert_raise ArgumentError, ~r/requires a :private_key/, fn ->
        Derive.sign_order(@order, [])
      end
    end
  end

  describe "hash_message/1 and sign_message/2 (EIP-191 personal signing)" do
    test "hash_message retains compatibility with CCXT hashMessage" do
      assert "1700000000000" |> Derive.hash_message() |> Base.encode16(case: :lower) ==
               "1362375365df31a82fb5331c8b5ae150f25d8ee09c8431ae46bac7625862136a"
    end

    test "sign_message retains compatibility with CCXT signMessage" do
      assert Derive.sign_message("1700000000000", private_key: @private_key) ==
               "0xe65c3e066894a1631220983b5da8617e21512ead950bb3ec6f38899349ebbe8d5f9111ffd4fa1bdfde707eae5f752ccdf11f3b5911ba014e92c2b9a50140b6a71b"
    end
  end

  describe "hash_order_message/2 ABI encoding edges" do
    test "accepts raw binary bytes32 and address values (same hash as hex form)" do
      raw_order = [
        Base.decode16!("4d7a9f27c403ff9c0f19bce61d76d82f9aa29f8d6d4b0c5474607d9770d1af17", case: :lower),
        1,
        1_700_000_000_000,
        @trade_module,
        Base.decode16!("aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899", case: :lower),
        1_737_200_000,
        Base.decode16!("108b9aF9279a525b8A8AeAbE7AC2bA925Bc50075", case: :mixed),
        @wallet
      ]

      assert Derive.hash_order_message(raw_order) == Derive.hash_order_message(@order)
    end

    test "raises on a malformed bytes32 field" do
      bad = List.replace_at(@order, 0, "0xabcd")

      assert_raise ArgumentError, ~r/bytes32 must be 32 bytes/, fn ->
        Derive.hash_order_message(bad)
      end
    end

    test "raises on a malformed address field" do
      bad = List.replace_at(@order, 3, "0xabcd")

      assert_raise ArgumentError, ~r/address must be 20 bytes/, fn ->
        Derive.hash_order_message(bad)
      end
    end
  end

  describe "trade_module_data_hash/7" do
    @base_asset "0x0000000000000000000000000000000000000001"

    test "buy and sell hash differently (the is_bid bool is load-bearing)" do
      buy = Derive.trade_module_data_hash(@base_asset, 0, "100", "0.1", "200", 144_422, true)
      sell = Derive.trade_module_data_hash(@base_asset, 0, "100", "0.1", "200", 144_422, false)

      assert byte_size(buy) == 32
      assert byte_size(sell) == 32
      refute buy == sell
    end

    test "scales decimal strings, integers and floats to the same 1e18 units" do
      from_string = Derive.trade_module_data_hash(@base_asset, 0, "100", "2", "200", 1, true)
      from_integer = Derive.trade_module_data_hash(@base_asset, 0, 100, 2, 200, 1, true)
      from_float = Derive.trade_module_data_hash(@base_asset, 0, 100.0, 2.0, 200.0, 1, true)

      assert from_string == from_integer
      assert from_string == from_float
    end

    test "a fractional amount is not truncated to whole units" do
      whole = Derive.trade_module_data_hash(@base_asset, 0, "100", "1", "200", 1, true)
      fractional = Derive.trade_module_data_hash(@base_asset, 0, "100", "1.5", "200", 1, true)

      refute whole == fractional
    end
  end

  describe "signer_address/1" do
    test "derives the EOA used as the order signer" do
      address = Derive.signer_address(@private_key)

      assert String.starts_with?(address, "0x")
      assert String.length(address) == 42
      assert address == String.downcase(address)
    end
  end

  describe "sign/3 (Behaviour) and Bourse.Signing.sign/4 dispatch" do
    setup do
      credentials = %Credentials{api_key: @wallet, secret: @private_key}

      request = %{
        method: :post,
        path: "https://api.lyra.finance/private/order",
        body: nil,
        params: %{order: @order, instrument_name: "ETH-PERP"}
      }

      %{credentials: credentials, request: request}
    end

    test "emits the REST auth-header trio on every private request", ctx do
      request = %{ctx.request | params: %{"wallet" => @wallet}, body: nil}
      signed = Derive.sign(request, ctx.credentials, %{timestamp_ms_override: 1_700_000_000_000})

      assert {"Content-Type", "application/json"} in signed.headers
      assert {"X-LyraWallet", @wallet} in signed.headers
      assert {"X-LyraTimestamp", "1700000000000"} in signed.headers

      sig = signed.headers |> Map.new() |> Map.fetch!("X-LyraSignature")
      assert sig == Derive.sign_message("1700000000000", private_key: @private_key)
      assert Jason.decode!(signed.body) == %{"wallet" => @wallet}
    end

    test "uses a pre-encoded JSON body without requiring :order", ctx do
      body = Jason.encode!(%{"wallet" => @wallet, "subaccount_id" => 144_422})
      request = %{ctx.request | params: %{}, body: body}

      signed = Derive.sign(request, ctx.credentials, %{timestamp_ms_override: 1_700_000_000_000})

      assert {"X-LyraWallet", @wallet} in signed.headers
      assert signed.body == body
    end

    test "empty params and nil body encode as empty JSON object", ctx do
      request = %{ctx.request | params: %{}, body: nil}
      signed = Derive.sign(request, ctx.credentials, %{timestamp_ms_override: 1_700_000_000_000})
      assert signed.body == "{}"
      assert {"X-LyraSignature", _} = List.keyfind(signed.headers, "X-LyraSignature", 0)
    end

    test "order EIP-712 signature is additive — injects body signature and drops :order", ctx do
      signed = Derive.sign(ctx.request, ctx.credentials, %{timestamp_ms_override: 1_700_000_000_000})

      assert {"X-LyraWallet", @wallet} in signed.headers
      assert {"X-LyraTimestamp", "1700000000000"} in signed.headers
      body = Jason.decode!(signed.body)
      assert body["signature"] == @order_signature
      assert body["instrument_name"] == "ETH-PERP"
      refute Map.has_key?(body, "order")
    end

    test "effective testnet config overrides credential fallback for order domains", ctx do
      signed = Derive.sign(ctx.request, ctx.credentials, %{testnet: true, timestamp_ms_override: 1_700_000_000_000})

      assert Jason.decode!(signed.body)["signature"] ==
               Derive.sign_order(@order, private_key: @private_key, testnet: true)
    end

    test "routes through Bourse.Signing.sign/4 for the :derive pattern", ctx do
      signed = Signing.sign(:derive, ctx.request, ctx.credentials, %{timestamp_ms_override: 1_700_000_000_000})
      assert Jason.decode!(signed.body)["signature"] == @order_signature
      assert {"X-LyraSignature", _} = List.keyfind(signed.headers, "X-LyraSignature", 0)
    end

    test "raises without credentials.api_key (X-LyraWallet)", ctx do
      credentials = %Credentials{api_key: nil, secret: @private_key}

      assert_raise ArgumentError, ~r/credentials\.api_key \(X-LyraWallet\)/, fn ->
        Derive.sign(ctx.request, credentials, %{})
      end
    end
  end
end
