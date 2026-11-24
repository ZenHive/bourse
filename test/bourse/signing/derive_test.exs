defmodule Bourse.Signing.DeriveTest do
  @moduledoc """
  Deterministic cryptographic regression vectors for `Bourse.Signing.Derive`.

  Provenance: the v3 action digests and signatures were produced independently
  with ethers 6.13.4 (`AbiCoder`, `TypedDataEncoder.hashDomain`, `SigningKey`)
  from the domain fields Derive publishes at
  https://docs.derive.xyz/authentication/action-signing.md, with the fixed test
  private key; the EIP-191 session-login vectors with ethers `hashMessage` /
  `Wallet.signMessage`. They are regression vectors for our own encoding; venue
  acceptance is established by live Derive evidence, never here.
  """
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Signing
  alias Bourse.Signing.Crypto
  alias Bourse.Signing.Derive

  @private_key "0x0123456789012345678901234567890123456789012345678901234567890123"
  @action_typehash "0x4d7a9f27c403ff9c0f19bce61d76d82f9aa29f8d6d4b0c5474607d9770d1af17"
  @trade_module "0xB8D20c2B7a1Ad2EE33Bc50eF10876eD3035b5e7b"
  @data_hash "0xaabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
  @wallet "0x108b9aF9279a525b8A8AeAbE7AC2bA925Bc50075"
  @order [
    @action_typehash,
    1,
    1_700_000_000_000_000_123,
    @trade_module,
    @data_hash,
    1_737_200_000,
    @wallet,
    @wallet
  ]
  @order_signature "0x456581bc160d0c95ef9fe19fa98061245c0b62676039d39993d470610e895d8f33b9b721d7c7add7e484c03d77902a2a42e622e73fe48ec4bafe1aecc58f62371b"

  describe "hash_order_message/2" do
    test "mainnet digest matches an independent ethers encoding under chainId 1" do
      assert @order |> Derive.hash_order_message() |> Base.encode16(case: :lower) ==
               "70dd676b5743cb7337c3bf68bd5c71f11f8a45606aef016f5cf61c4a79e26ca9"
    end

    test "testnet digest matches an independent ethers encoding under chainId 11155111" do
      assert @order |> Derive.hash_order_message(testnet: true) |> Base.encode16(case: :lower) ==
               "71ce696220d54997754c0e7ed7f8f71fc2a68ca2dff98a87d9a5fac9ae9b0550"
    end
  end

  describe "sign_order/2" do
    test "byte-equal packed signature" do
      assert Derive.sign_order(@order, private_key: @private_key) == @order_signature

      assert Derive.sign_order(@order, private_key: @private_key, testnet: true) ==
               "0xf01d25bf6c981a71335cc52f2c94e573b9e6dff28454fd69e0a7135999d17c5b48ced351b666d789db4aff9de69ea0f2f3be4b21638974ff52e7702dd28ae7271c"
    end

    test "raises without a private key" do
      assert_raise ArgumentError, ~r/requires a :private_key/, fn ->
        Derive.sign_order(@order, [])
      end
    end
  end

  describe "hash_message/1 and sign_message/2 (EIP-191 personal signing)" do
    test "hash_message matches ethers hashMessage" do
      assert "1700000000000" |> Derive.hash_message() |> Base.encode16(case: :lower) ==
               "1362375365df31a82fb5331c8b5ae150f25d8ee09c8431ae46bac7625862136a"
    end

    test "sign_message matches ethers Wallet.signMessage" do
      assert Derive.sign_message("1700000000000", private_key: @private_key) ==
               "0xe65c3e066894a1631220983b5da8617e21512ead950bb3ec6f38899349ebbe8d5f9111ffd4fa1bdfde707eae5f752ccdf11f3b5911ba014e92c2b9a50140b6a71b"
    end
  end

  describe "hash_order_message/2 ABI encoding edges" do
    test "accepts raw binary bytes32 and address values (same hash as hex form)" do
      raw_order = [
        Base.decode16!("4d7a9f27c403ff9c0f19bce61d76d82f9aa29f8d6d4b0c5474607d9770d1af17", case: :lower),
        1,
        1_700_000_000_000_000_123,
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

    test "signed int256 words follow the ABI two's-complement spec, including -1" do
      # Solidity abi.encode(int256(-1)) is 32 0xff bytes (the ABI spec, not a
      # previously-computed bourse hash).
      minus_one = Onchain.ABI.TypeEncoder.encode_raw([-1], [%{type: Onchain.ABI.FunctionSelector.decode_type("int256")}])
      assert minus_one == :binary.copy(<<0xFF>>, 32)

      scale = 1_000_000_000_000_000_000
      price = 100 * scale
      amount = -1 * scale
      max_fee = 200 * scale

      encoded =
        <<1::256, 0::256, price::signed-256, amount::signed-256, max_fee::256, 1::256, 1::256>>

      expected = Crypto.keccak256(encoded)
      assert Derive.trade_module_data_hash(@base_asset, 0, 100, -1, 200, 1, true) == expected
    end
  end

  describe "signer_address/1" do
    test "derives the EOA used as the order signer" do
      address = Derive.signer_address(@private_key)

      assert String.starts_with?(address, "0x")
      assert String.length(address) == 42
      assert address == String.downcase(address)
      assert address == Crypto.address_from_private_key(@private_key)
    end
  end

  describe "sign/3 (Behaviour) and Bourse.Signing.sign/4 dispatch" do
    setup do
      credentials = %Credentials{api_key: @wallet, secret: @private_key}

      request = %{
        method: :post,
        path: "https://api.derive.xyz/v3/private/order",
        body: nil,
        params: %{order: @order, instrument_name: "ETH-PERP"}
      }

      %{credentials: credentials, request: request}
    end

    test "emits the REST auth-header trio on every private request", ctx do
      request = %{ctx.request | params: %{"wallet" => @wallet}, body: nil}
      signed = Derive.sign(request, ctx.credentials, %{timestamp_ms_override: 1_700_000_000_000})

      assert {"Content-Type", "application/json"} in signed.headers
      assert {"X-DeriveWallet", @wallet} in signed.headers
      assert {"X-DeriveTimestamp", "1700000000000"} in signed.headers

      sig = signed.headers |> Map.new() |> Map.fetch!("X-DeriveSignature")
      assert sig == Derive.sign_message("1700000000000", private_key: @private_key)
      assert Jason.decode!(signed.body) == %{"wallet" => @wallet}
    end

    test "uses a pre-encoded JSON body without requiring :order", ctx do
      body = Jason.encode!(%{"wallet" => @wallet, "subaccount_id" => 144_422})
      request = %{ctx.request | params: %{}, body: body}

      signed = Derive.sign(request, ctx.credentials, %{timestamp_ms_override: 1_700_000_000_000})

      assert {"X-DeriveWallet", @wallet} in signed.headers
      assert signed.body == body
    end

    test "empty params and nil body encode as empty JSON object", ctx do
      request = %{ctx.request | params: %{}, body: nil}
      signed = Derive.sign(request, ctx.credentials, %{timestamp_ms_override: 1_700_000_000_000})
      assert signed.body == "{}"
      assert {"X-DeriveSignature", _} = List.keyfind(signed.headers, "X-DeriveSignature", 0)
    end

    test "order EIP-712 signature is additive — injects body signature and drops :order", ctx do
      signed = Derive.sign(ctx.request, ctx.credentials, %{timestamp_ms_override: 1_700_000_000_000})

      assert {"X-DeriveWallet", @wallet} in signed.headers
      assert {"X-DeriveTimestamp", "1700000000000"} in signed.headers
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
      assert {"X-DeriveSignature", _} = List.keyfind(signed.headers, "X-DeriveSignature", 0)
    end

    test "raises without credentials.api_key (X-DeriveWallet)", ctx do
      credentials = %Credentials{api_key: nil, secret: @private_key}

      assert_raise ArgumentError, ~r/credentials\.api_key \(X-DeriveWallet\)/, fn ->
        Derive.sign(ctx.request, credentials, %{})
      end
    end
  end
end
