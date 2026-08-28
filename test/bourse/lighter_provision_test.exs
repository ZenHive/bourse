defmodule Bourse.LighterProvisionTest do
  use ExUnit.Case, async: true

  alias Bourse.LighterProvision
  alias Bourse.Signing.Crypto

  @pub_key "48d4615592bf39d71889f5127c7710c36912b733a1f8f32cb9446a7aec4e34461348642d459cbc77"
  @l1_private_key "0x0123456789012345678901234567890123456789012345678901234567890123"
  @golden_l1_body """
  Register Lighter Account

  pubkey: 0x#{@pub_key}
  nonce: 0x000000000000000c
  account index: 0x0000000000000001
  api key index: 0x0000000000000000
  Only sign this message for a trusted client!\
  """

  test "l1_message matches TemplateChangePubKey integer encoding" do
    assert LighterProvision.l1_message(@pub_key, 12, 1, 0) == @golden_l1_body
    assert LighterProvision.hex10(12) == "0x000000000000000c"
    assert LighterProvision.change_pub_key_tx_type() == 8
    assert LighterProvision.testnet_chain_id() == 300
  end

  test "assert_signer accepts a matching recovered address and rejects a mismatch" do
    message = LighterProvision.l1_message(@pub_key, 12, 1, 0)
    signature = LighterProvision.sign_l1_message(message, @l1_private_key)
    assert {:ok, address} = Crypto.recover_signer_address(message, signature)
    assert :ok = LighterProvision.assert_signer(address, message, signature)

    assert {:error, {:signer_mismatch, ^address, expected}} =
             LighterProvision.assert_signer("0x" <> String.duplicate("00", 20), message, signature)

    assert expected == "0x" <> String.duplicate("00", 20)
    assert {:error, :invalid_signature} = LighterProvision.assert_signer(address, message, "not-a-signature")
  end

  test "parse helpers read venue envelopes and reject misses" do
    assert LighterProvision.faucet_ok?(%{"code" => 200, "message" => "ok"})
    assert LighterProvision.code_ok?(%{"code" => "200"})
    refute LighterProvision.faucet_ok?(%{"code" => 400})

    assert {:ok, 153} =
             LighterProvision.parse_account_index(%{
               "code" => 200,
               "sub_accounts" => [%{"index" => 153}]
             })

    assert {:ok, 153} =
             LighterProvision.parse_account_index(%{
               "code" => 200,
               "sub_accounts" => [%{"account_index" => "153"}]
             })

    assert {:error, :account_not_found} =
             LighterProvision.parse_account_index(%{"code" => 200, "sub_accounts" => []})

    assert {:ok, %{public_key: @pub_key, nonce: 1}} =
             LighterProvision.parse_api_key(
               %{
                 "code" => 200,
                 "api_keys" => [
                   %{"api_key_index" => 3, "public_key" => "0x" <> @pub_key, "nonce" => "1"}
                 ]
               },
               3
             )

    assert {:error, :api_key_not_found} =
             LighterProvision.parse_api_key(%{"code" => 200, "api_keys" => []}, 3)

    assert {:ok, 0} = LighterProvision.parse_nonce(%{"code" => 200, "nonce" => 0})
    assert {:ok, 1} = LighterProvision.parse_nonce(%{"code" => 200, "nonce" => "1"})
    assert {:error, :nonce_not_found} = LighterProvision.parse_nonce(%{"code" => 200})
    assert {:error, :nonce_not_found} = LighterProvision.parse_nonce(%{"code" => 200, "nonce" => "nope"})
    assert {:error, :nonce_not_found} = LighterProvision.parse_nonce(%{"code" => 500, "nonce" => 1})
    assert {:error, :nonce_not_found} = LighterProvision.parse_nonce(%{})
    assert {:error, :account_not_found} = LighterProvision.parse_account_index(%{})

    assert {:error, :account_not_found} =
             LighterProvision.parse_account_index(%{"code" => 500, "sub_accounts" => [%{"index" => 1}]})

    assert {:error, :account_not_found} =
             LighterProvision.parse_account_index(%{"code" => 200, "sub_accounts" => [%{"name" => "x"}]})

    assert {:error, :api_key_not_found} = LighterProvision.parse_api_key(%{}, 3)
    assert {:error, :api_key_not_found} = LighterProvision.parse_api_key(%{"code" => 500, "api_keys" => []}, 3)

    assert {:error, :api_key_not_found} =
             LighterProvision.parse_api_key(%{"code" => 200, "api_keys" => [%{"api_key_index" => 3}]}, 3)

    refute LighterProvision.code_ok?(%{})
    assert LighterProvision.testnet_url() == "https://testnet.zklighter.elliot.ai"
  end

  test "only the provision mix task reads LIGHTER_TESTNET_L1_*" do
    hits =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        path
        |> File.read!()
        |> String.contains?("LIGHTER_TESTNET_L1_")
      end)

    assert hits == ["lib/mix/tasks/bourse.provision_lighter.ex"]
  end

  test "LighterProvision is unpackaged and undocumented, matching LiveLane" do
    refute Bourse.MixProject.document_module?(LighterProvision, %{})
    refute Bourse.MixProject.document_module?(Mix.Tasks.Bourse.ProvisionLighter, %{})
    refute Bourse.MixProject.document_module?(Bourse.LiveLane.FirstFrame, %{})
  end
end
