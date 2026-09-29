defmodule Bourse.Signing.Derive.PreparedOrderTest do
  use ExUnit.Case, async: true

  alias Bourse.Signing.Crypto
  alias Bourse.Signing.Derive.PreparedOrder

  doctest PreparedOrder

  @params %{
    "subaccount_id" => 30_769,
    "nonce" => 1_790_476_000_000_001,
    "signature_expiry_sec" => 1_790_476_600,
    "owner" => "0x8772185a1516f0d61fC1c2524926BfC69F95d698",
    "signer" => "0x0000000000000000000000000000000000000001",
    "base_asset_address" => "0x4BB4C3CDc7562f08e9910A0C7D8bB7e108861eB4",
    "base_asset_sub_id" => "2576980377601821772800",
    "instrument_name" => "ETH-20270924-6000-P",
    "direction" => "buy",
    "amount" => "0.1",
    "limit_price" => "100",
    "max_fee" => "1"
  }

  test "keyless preparation matches the provider Python SDK and independent EIP-712 encoder" do
    assert {:ok, result} = PreparedOrder.prepare(@params, :mainnet)
    # derive_action_signing.SignedAction._to_typed_data_hash and ethers.TypedDataEncoder.hash
    assert result.digest == "0x40b6c7a8cee212dbf762eaaa850beaf9d4f8b52e4931db666cc48269eeba1896"
    assert result.typed_data["domain"]["chainId"] == 957
    assert result.body["amount"] == "0.1"
    refute Map.has_key?(result.body, "signature")
    refute Map.has_key?(result.body, "owner")
  end

  # The typehash is derived from @action_fields rather than transcribed, so this
  # is what notices an edit to that list: the derived value must still be the
  # constant Derive publishes. Without it the field list could change silently,
  # and a wallet would display one struct while the digest committed to another.
  test "the derived Action typehash is still the one the provider publishes" do
    assert PreparedOrder.action_type() ==
             "Action(uint256 subaccountId,uint256 nonce,address module,bytes data," <>
               "uint256 expiry,address owner,address signer)"

    assert Base.encode16(Crypto.keccak256(PreparedOrder.action_type()), case: :lower) ==
             "4d7a9f27c403ff9c0f19bce61d76d82f9aa29f8d6d4b0c5474607d9770d1af17"
  end

  # The chain id and Matching address are the only parts of @deployments this
  # repo can grade on its own: hashed as an EIP-712 domain they must reproduce
  # the separators Bourse.Signing.Derive pins independently. The Trade module
  # addresses have no such check — see the module doc and the ledger entry.
  for {environment, separator} <- [
        mainnet: "d96e5f90797da7ec8dc4e276260c7f3f87fedf68775fbe1ef116e996fc60441b",
        testnet: "9bcf4dc06df5d8bf23af818d5716491b995020f377d3b7b64c29ed14e3dd1105"
      ] do
    test "the #{environment} domain reproduces Derive's independently pinned separator" do
      assert {:ok, %{typed_data: %{"domain" => domain}}} = PreparedOrder.prepare(@params, unquote(environment))

      encoded =
        Crypto.keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)") <>
          Crypto.keccak256(domain["name"]) <>
          Crypto.keccak256(domain["version"]) <>
          <<domain["chainId"]::256>> <>
          <<0::96>> <> Base.decode16!(String.trim_leading(domain["verifyingContract"], "0x"), case: :mixed)

      assert Base.encode16(Crypto.keccak256(encoded), case: :lower) == unquote(separator)
    end
  end

  test "every signed field and the deployment alter the digest" do
    {:ok, original} = PreparedOrder.prepare(@params, :mainnet)

    changes = %{
      "subaccount_id" => 30_770,
      "nonce" => 1_790_476_000_000_002,
      "signature_expiry_sec" => 1_790_476_601,
      "owner" => @params["signer"],
      "signer" => @params["owner"],
      "base_asset_address" => @params["owner"],
      "base_asset_sub_id" => "1",
      "amount" => "0.2",
      "limit_price" => "101",
      "max_fee" => "2",
      "direction" => "sell"
    }

    for {key, value} <- changes do
      assert {:ok, changed} = PreparedOrder.prepare(Map.put(@params, key, value), :mainnet)
      refute changed.digest == original.digest, key
    end

    assert {:ok, sandbox} = PreparedOrder.prepare(@params, :testnet)
    refute sandbox.digest == original.digest
  end

  # The wire body has to state the same number the signed word commits to, or a
  # customer authorizes one price and submits another. Scaling by 1e18 and back
  # is where that can silently round, so the round-trip is asserted at the
  # magnitudes the int256 tuple actually admits — not only at "0.1".
  test "the wire terms restate the signed integers exactly at every admitted magnitude" do
    for value <- ~w(0.000000000000000001 1.000000000000000001 123456789.123456789123456789 100 0.1) do
      assert {:ok, result} = PreparedOrder.prepare(Map.put(@params, "limit_price", value), :mainnet)
      assert result.body["limit_price"] == value
    end
  end

  test "a refusal names the field it refused" do
    for key <- ~w(amount limit_price max_fee),
        value <- [nil, "", "NaN", "Infinity", "-1", "0.0000000000000000001", 0.1] do
      assert {:error, {:invalid_field, ^key}} = PreparedOrder.prepare(Map.put(@params, key, value), :mainnet)
    end

    for key <- ~w(owner signer base_asset_address), value <- [nil, "0x1", "0x" <> String.duplicate("z", 40)] do
      assert {:error, {:invalid_field, ^key}} = PreparedOrder.prepare(Map.put(@params, key, value), :mainnet)
    end

    for key <- ~w(subaccount_id nonce signature_expiry_sec base_asset_sub_id), value <- [-1, "1.5", nil] do
      assert {:error, {:invalid_field, ^key}} = PreparedOrder.prepare(Map.put(@params, key, value), :mainnet)
    end

    assert {:error, {:invalid_field, "direction"}} =
             PreparedOrder.prepare(Map.put(@params, "direction", "long"), :mainnet)

    assert {:error, {:invalid_field, "instrument_name"}} =
             PreparedOrder.prepare(Map.put(@params, "instrument_name", ""), :mainnet)

    assert {:error, {:unknown_environment, :unknown}} = PreparedOrder.prepare(@params, :unknown)
    assert {:error, :invalid_params} = PreparedOrder.prepare(nil, :mainnet)
    assert {:ok, _} = PreparedOrder.prepare(Map.put(@params, "max_fee", "0"), :mainnet)
    assert {:error, {:invalid_field, "amount"}} = PreparedOrder.prepare(Map.put(@params, "amount", "0"), :mainnet)
  end

  # order_type and time_in_force never reach the signed blob, so rewriting a
  # caller's value would leave a perfectly valid digest attached to terms they
  # never asked for. Absent means the supported value; named means it must be it.
  test "an unsupported order type or time in force is refused, not quietly rewritten" do
    assert {:ok, _} =
             PreparedOrder.prepare(Map.merge(@params, %{"order_type" => "limit", "time_in_force" => "gtc"}), :mainnet)

    assert {:error, {:unsupported, "order_type", "market"}} =
             PreparedOrder.prepare(Map.put(@params, "order_type", "market"), :mainnet)

    assert {:error, {:unsupported, "time_in_force", "ioc"}} =
             PreparedOrder.prepare(Map.put(@params, "time_in_force", "ioc"), :mainnet)
  end
end
