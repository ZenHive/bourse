defmodule Bourse.Signing.HyperliquidTest do
  @moduledoc """
  Deterministic cryptographic regression vectors for
  `Bourse.Signing.Hyperliquid`.

  Provenance: the pinned `%{r, s, v}` values were originally produced by
  running CCXT JS `signL1Action` / `signUserSignedAction` (repo `../ccxt`)
  with the fixed test private key — an unverified authoring reference, not a
  semantic authority. They are kept as frozen regression vectors; venue
  semantics are established by live Hyperliquid acceptance evidence, never by
  these vectors.
  """
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Signing
  alias Bourse.Signing.Hyperliquid
  alias Bourse.Signing.SignedRequest

  # Deterministic test key (never a real wallet).
  @private_key "0x0123456789012345678901234567890123456789012345678901234567890123"
  @action %{"type" => "order", "orders" => [], "grouping" => "na"}
  @nonce 1_700_000_000_000

  describe "action_hash/4" do
    test "produces the stable action hash without a vault" do
      assert @action |> Hyperliquid.action_hash(nil, @nonce) |> Base.encode16(case: :lower) ==
               "eb4729f4d12c2bdaa7cae0e877016eaee3e646ba05bd7d861c705a44b1dfc586"
    end

    test "threads the vault address into the hash" do
      hash =
        @action
        |> Hyperliquid.action_hash("1234567890123456789012345678901234567890", @nonce)
        |> Base.encode16(case: :lower)

      assert hash == "2537d63c60d9bbc1e1f5113fde77729fdd53ccd5c58781df743b0e99d5753390"
    end
  end

  describe "pack_l1_action!/1" do
    test "pins Hyperliquid cancel field order" do
      action = %{"type" => "cancel", "cancels" => [%{"a" => 0, "o" => 1}]}

      assert Base.encode16(Hyperliquid.pack_l1_action!(action), case: :lower) ==
               "82a474797065a663616e63656ca763616e63656c739182a16100a16f01"

      refute Hyperliquid.pack_l1_action!(action) == Msgpax.pack!(action, iodata: false)
    end

    test "pins Hyperliquid order and nested row field order" do
      action = %{
        "type" => "order",
        "orders" => [
          %{
            "a" => 0,
            "b" => true,
            "p" => "1",
            "s" => "2",
            "r" => false,
            "t" => %{"limit" => %{"tif" => "Gtc"}}
          }
        ],
        "grouping" => "na"
      }

      assert Base.encode16(Hyperliquid.pack_l1_action!(action), case: :lower) ==
               "83a474797065a56f72646572a66f72646572739186a16100a162c3a170a131a173a132a172c2a17481a56c696d697481a3746966a3477463a867726f7570696e67a26e61"

      refute Hyperliquid.pack_l1_action!(action) == Msgpax.pack!(action, iodata: false)
    end

    test "pins subaccount transfer field order" do
      action = %{
        "type" => "subAccountTransfer",
        "subAccountUser" => "0xabc",
        "isDeposit" => true,
        "usd" => 1
      }

      assert Msgpax.unpack!(Hyperliquid.pack_l1_action!(action)) == action
    end

    test "pins vaultTransfer field order and rejects unknown fields (task 384)" do
      action = %{
        "type" => "vaultTransfer",
        "vaultAddress" => "0xc751489d24a33172541ea451bc253d7a9e98c781",
        "isDeposit" => false,
        "usd" => 100
      }

      packed = Hyperliquid.pack_l1_action!(action)
      assert Msgpax.unpack!(packed) == action

      # Canonical wire order is type → vaultAddress → isDeposit → usd regardless of
      # the input map's insertion order (Msgpax alone would follow insertion order).
      reordered = %{
        "usd" => 100,
        "isDeposit" => false,
        "vaultAddress" => "0xc751489d24a33172541ea451bc253d7a9e98c781",
        "type" => "vaultTransfer"
      }

      assert Hyperliquid.pack_l1_action!(reordered) == packed

      assert_raise ArgumentError, ~r/unsupported Hyperliquid action fields/, fn ->
        Hyperliquid.pack_l1_action!(Map.put(action, "destination", "0xdead"))
      end

      assert_raise ArgumentError, ~r/requires vaultAddress/, fn ->
        Hyperliquid.pack_l1_action!(%{
          "type" => "vaultTransfer",
          "isDeposit" => false,
          "usd" => 100
        })
      end
    end

    test "packs isolated-margin and TWAP actions in their authored wire order" do
      margin = %{"type" => "updateIsolatedMargin", "asset" => 7, "isBuy" => true, "ntli" => -1_250_000}

      twap = %{
        "type" => "twapOrder",
        "twap" => %{"a" => 7, "b" => true, "s" => "0.01", "r" => false, "m" => 2, "t" => false}
      }

      assert Msgpax.unpack!(Hyperliquid.pack_l1_action!(margin)) == margin
      assert Msgpax.unpack!(Hyperliquid.pack_l1_action!(twap)) == twap
    end

    test "packs optional order fields and trigger order types" do
      action = %{
        "type" => "order",
        "orders" => [
          %{
            "a" => 0,
            "b" => true,
            "p" => "1",
            "s" => "2",
            "r" => false,
            "t" => %{"trigger" => %{"isMarket" => true, "triggerPx" => "3", "tpsl" => "tp"}},
            "c" => "0x00000000000000000000000000000000"
          }
        ],
        "grouping" => "na",
        "builder" => %{"b" => "0xabc", "f" => 10}
      }

      assert Msgpax.unpack!(Hyperliquid.pack_l1_action!(action)) == action
    end

    test "rejects malformed supported L1 actions" do
      assert_raise ArgumentError, ~r/order row must be a map/, fn ->
        Hyperliquid.pack_l1_action!(%{"type" => "order", "orders" => [nil], "grouping" => "na"})
      end

      assert_raise ArgumentError, ~r/exactly one of limit or trigger/, fn ->
        Hyperliquid.pack_l1_action!(%{
          "type" => "order",
          "orders" => [%{"a" => 0, "b" => true, "p" => "1", "s" => "2", "r" => false, "t" => %{}}],
          "grouping" => "na"
        })
      end

      assert_raise ArgumentError, ~r/order type must be a map/, fn ->
        Hyperliquid.pack_l1_action!(%{
          "type" => "order",
          "orders" => [%{"a" => 0, "b" => true, "p" => "1", "s" => "2", "r" => false, "t" => true}],
          "grouping" => "na"
        })
      end

      assert_raise ArgumentError, ~r/builder must be a map/, fn ->
        Hyperliquid.pack_l1_action!(%{
          "type" => "order",
          "orders" => [],
          "grouping" => "na",
          "builder" => "invalid"
        })
      end

      assert_raise ArgumentError, ~r/cancel row must be a map/, fn ->
        Hyperliquid.pack_l1_action!(%{"type" => "cancel", "cancels" => [nil]})
      end

      assert_raise ArgumentError, ~r/must be a list/, fn ->
        Hyperliquid.pack_l1_action!(%{"type" => "cancel", "cancels" => "invalid"})
      end

      assert_raise ArgumentError, ~r/requires cancels/, fn ->
        Hyperliquid.pack_l1_action!(%{"type" => "cancel"})
      end
    end

    test "uses array16 for cancel batches larger than fifteen rows" do
      action = %{"type" => "cancel", "cancels" => List.duplicate(%{"a" => 0, "o" => 1}, 16)}

      assert Msgpax.unpack!(Hyperliquid.pack_l1_action!(action)) == action
    end

    test "raises for a missing or unsupported action type" do
      assert_raise ArgumentError, ~r/requires a string type/, fn ->
        Hyperliquid.pack_l1_action!(%{})
      end

      assert_raise ArgumentError, ~r/unsupported Hyperliquid L1 action type/, fn ->
        Hyperliquid.pack_l1_action!(%{"type" => "unknown"})
      end
    end
  end

  describe "sign_l1_action/3" do
    test "byte-equal signature without a vault address" do
      assert Hyperliquid.sign_l1_action(@action, @nonce, private_key: @private_key) ==
               %{
                 r: "aaff8f727a586705b933e2188e676865645897c540ccb49701f7475bf8b18ae6",
                 s: "2ce46ed6a2a2c201cc7ff442794d4e6362e712e7ead67e6d015d68c11acbfd26",
                 v: 27
               }
    end

    test "byte-equal signature with a vault address (0x stripped)" do
      assert Hyperliquid.sign_l1_action(@action, @nonce,
               private_key: @private_key,
               vault_address: "0x1234567890123456789012345678901234567890"
             ) ==
               %{
                 r: "bb05a018980c4a5bfd14a31ee31a883e50a956c937a07b1399134bf73aff7ba4",
                 s: "59c2f8c0fcc507fa4a15efcbcf27007266030d08e157d1e3190730b898ea7a12",
                 v: 28
               }
    end

    test "byte-equal signature with an expires_after field" do
      assert Hyperliquid.sign_l1_action(@action, @nonce,
               private_key: @private_key,
               expires_after: 1_800_000_000_000
             ) ==
               %{
                 r: "3d4116a4496bbfd2a7c2d7b6df9f00863264bbab921bee00d4ebc5f9329fae05",
                 s: "7ac3551d6057578ce5a65fe1311cdaa567326b86911a245136b01ca820dfce21",
                 v: 28
               }
    end

    test "testnet flips the phantom-agent source, changing the signature" do
      mainnet = Hyperliquid.sign_l1_action(@action, @nonce, private_key: @private_key)
      testnet = Hyperliquid.sign_l1_action(@action, @nonce, private_key: @private_key, testnet: true)

      refute mainnet == testnet
    end

    test "raises without a private key" do
      assert_raise ArgumentError, ~r/requires a :private_key/, fn ->
        Hyperliquid.sign_l1_action(@action, @nonce, [])
      end
    end
  end

  describe "sign_user_signed_action/3" do
    @usd_send_types %{
      "HyperliquidTransaction:UsdSend" => [
        %{"name" => "hyperliquidChain", "type" => "string"},
        %{"name" => "destination", "type" => "string"},
        %{"name" => "amount", "type" => "string"},
        %{"name" => "time", "type" => "uint64"}
      ]
    }
    @usd_send_message %{
      "hyperliquidChain" => "Mainnet",
      "destination" => "0x0000000000000000000000000000000000000001",
      "amount" => "100",
      "time" => @nonce
    }

    test "byte-equal signature for a UsdSend user-signed action" do
      assert Hyperliquid.sign_user_signed_action(@usd_send_types, @usd_send_message, private_key: @private_key) ==
               %{
                 r: "5af112a176af28958bc53be6810ccc294348971d5897cc81b620637322f6e057",
                 s: "7fe0c29c6ba2c5b91566dce5faab3a270f93686cd448980f3c36c4e99f089294",
                 v: 28
               }
    end
  end

  describe "sign/3 (Behaviour) and Bourse.Signing.sign/4 dispatch" do
    setup do
      credentials = %Credentials{api_key: "0xwallet", secret: @private_key}

      request = %{
        method: :post,
        path: "https://api.hyperliquid.xyz/exchange",
        body: nil,
        params: %{action: @action, nonce: @nonce}
      }

      %{credentials: credentials, request: request}
    end

    test "builds the POST /exchange envelope with the signature", ctx do
      signed = Hyperliquid.sign(ctx.request, ctx.credentials, %{})

      assert signed.method == :post
      assert {"Content-Type", "application/json"} in signed.headers
      body = Jason.decode!(signed.body)
      assert body["action"] == @action
      assert body["nonce"] == @nonce
      assert body["signature"]["v"] == 27
      refute Map.has_key?(body, "vaultAddress")
    end

    test "accepts generated string-keyed request params", ctx do
      request = %{ctx.request | params: %{"action" => @action, "nonce" => @nonce}}

      assert %SignedRequest{} = Hyperliquid.sign(request, ctx.credentials, %{})
    end

    test "signs a usd class transfer as a user-signed action", ctx do
      action = %{
        "type" => "usdClassTransfer",
        "hyperliquidChain" => "Testnet",
        "amount" => "1",
        "toPerp" => true,
        "nonce" => @nonce
      }

      request = %{ctx.request | params: %{action: action, nonce: @nonce}}
      body = request |> Hyperliquid.sign(ctx.credentials, %{}) |> Map.fetch!(:body) |> Jason.decode!()

      assert body["action"] == action
      assert body["signature"]["r"] =~ ~r/\A0x[0-9a-f]{64}\z/
    end

    test "includes vaultAddress when threaded through params", ctx do
      params = Map.put(ctx.request.params, :vault_address, "0xabc0000000000000000000000000000000000def")
      request = %{ctx.request | params: params}
      signed = Hyperliquid.sign(request, ctx.credentials, %{})
      body = Jason.decode!(signed.body)

      assert body["vaultAddress"] == "abc0000000000000000000000000000000000def"
    end

    test "routes through Bourse.Signing.sign/4 for the :hyperliquid pattern", ctx do
      signed = Signing.sign(:hyperliquid, ctx.request, ctx.credentials, %{})
      assert Jason.decode!(signed.body)["signature"]["r"] =~ ~r/\A0x[0-9a-f]{64}\z/
    end

    test "raises when the action is missing from params", ctx do
      request = %{ctx.request | params: %{nonce: @nonce}}

      assert_raise ArgumentError, ~r/requires :action/, fn ->
        Hyperliquid.sign(request, ctx.credentials, %{})
      end
    end
  end
end
