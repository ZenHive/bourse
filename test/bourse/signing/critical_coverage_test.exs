defmodule Bourse.Signing.CriticalCoverageTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Signing
  alias Bourse.Signing.HmacRecipe
  alias Bourse.Signing.Hyperliquid
  alias Bourse.Signing.Request
  alias Bourse.Signing.SignedRequest

  @private_key "0x0123456789012345678901234567890123456789012345678901234567890123"

  test "query encoding and timestamps cover nil and caller-supplied scalar edges" do
    assert Signing.encode_query_pairs([{"empty", nil}]) == "empty="
    assert Signing.timestamp_iso8601_from_config(%{timestamp: "fixed"}) == "fixed"
  end

  test "a root HMAC recipe accepts ISO seconds derived from a fixed millisecond timestamp" do
    recipe = %{
      "canonical_string" => %{"GET" => %{"components" => [%{"source" => "timestamp"}, %{"source" => "hostname"}]}},
      "crypto_op" => %{"algo" => "hmac_sha256"},
      "signature_placement" => %{"location" => "header", "key" => "X-Signature"},
      "timestamp" => %{"format" => "iso8601_seconds"}
    }

    request = %Request{method: :get, path: "/x", params: %{}, body: nil}
    credentials = %Credentials{api_key: "key", secret: "secret"}

    assert %SignedRequest{headers: [{"X-Signature", signature}]} =
             HmacRecipe.sign(request, credentials, %{
               sign_recipe: recipe,
               timestamp_ms_override: 1_700_000_000_123,
               hostname: "api.example.test"
             })

    assert is_binary(signature)
  end

  test "Hyperliquid signs withdraw actions and packs schedule cancellation" do
    credentials = %Credentials{api_key: "wallet", secret: @private_key}

    action = %{
      "type" => "withdraw3",
      "hyperliquidChain" => "Testnet",
      "destination" => "0x0000000000000000000000000000000000000001",
      "amount" => "1",
      "time" => 1_700_000_000_000
    }

    request = %Request{
      method: :post,
      path: "/exchange",
      params: %{"action" => action, "nonce" => 1_700_000_000_000},
      body: nil
    }

    assert %SignedRequest{body: body} = Hyperliquid.sign(request, credentials, %{testnet: true})

    assert {:ok, %{"action" => ^action, "signature" => %{"r" => "0x" <> _, "s" => "0x" <> _, "v" => v}}} =
             Jason.decode(body)

    assert is_integer(v)

    assert %{"type" => "scheduleCancel", "time" => 123} ==
             %{"type" => "scheduleCancel", "time" => 123}
             |> Hyperliquid.pack_l1_action!()
             |> Msgpax.unpack!()
  end

  test "Hyperliquid rejects non-map TWAP rows" do
    assert_raise ArgumentError, ~r/TWAP row must be a map/, fn ->
      Hyperliquid.pack_l1_action!(%{"type" => "twapOrder", "twap" => [:invalid]})
    end
  end
end
