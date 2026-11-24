defmodule Bourse.Signing.Derive.PreparedOrderTest do
  use ExUnit.Case, async: true

  alias Bourse.Signing.Crypto
  alias Bourse.Signing.Derive.PreparedOrder

  doctest PreparedOrder

  @params %{
    "subaccount_id" => 30_769,
    "nonce" => 1_790_476_000_000_000_123,
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

  test "keyless preparation matches an independent EIP-712 encoder on both networks" do
    assert {:ok, result} = PreparedOrder.prepare(@params, :mainnet)
    # ethers 6.13.4 TypedDataEncoder.hash over result.typed_data
    assert result.digest == "0x00650c0b01346fd90683dac6de1f579ef39ce6328b1f6aed7b5bed016f10812c"
    assert result.typed_data["domain"]["chainId"] == 1
    assert result.body["nonce"] == "1790476000000000123"

    assert {:ok, testnet} = PreparedOrder.prepare(@params, :testnet)
    assert testnet.digest == "0xd8bfa4ee0fdfb74cd370858098e5cbce219cf119cc2ac24700550e7dc767a0e8"
    assert testnet.typed_data["domain"]["chainId"] == 11_155_111
    assert testnet.typed_data["message"]["module"] == result.typed_data["message"]["module"]
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

  # Hashed as an EIP-712 domain, the chain id and Matching address must
  # reproduce the separators Derive publishes per network
  # (https://docs.derive.xyz/authentication/action-signing.md). The Trade module
  # address is graded only by live acceptance — see the ledger entry.
  for {environment, separator} <- [
        mainnet: "da616dfabb88681b08e1592820a41d55ddc62d68de110e327ae99d734506fe19",
        testnet: "24d674cd5f2b9d564691c51e9d88f649b99246a2244dd74ce27b96578d773e85"
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
      "nonce" => 1_790_476_000_000_000_124,
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
    for value <- ~w(0.000000000001 1.000000000001 123456789.123456789123 100 0.1) do
      assert {:ok, result} = PreparedOrder.prepare(Map.put(@params, "limit_price", value), :mainnet)
      assert result.body["limit_price"] == value
    end
  end

  test "a refusal names the field it refused" do
    for key <- ~w(amount limit_price max_fee),
        value <- [nil, "", "NaN", "Infinity", "-1", "0.0000000000000000001", "0.0000000000001", 0.1] do
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
