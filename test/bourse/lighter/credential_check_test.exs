defmodule Bourse.Lighter.CredentialCheckOfflineTest do
  use ExUnit.Case, async: true

  alias Bourse.Lighter.CredentialCheck

  # These assert about OUR classification of a registry, not about the venue.
  # The venue-facing half — that the registry we classify is the one Lighter
  # actually serves — is `test/live/lighter/credential_check_test.exs`, and
  # nothing here substitutes for it.

  describe "classify/4" do
    test "an occupied configured slot with no key to compare is accepted" do
      assert :ok = CredentialCheck.classify([key(3, "aa")], 230, 3)
    end

    test "an occupied configured slot holding the expected key is accepted" do
      assert :ok = CredentialCheck.classify([key(3, "aa")], 230, 3, "aa")
    end

    test "case and 0x prefix do not make a matching key look foreign" do
      assert :ok = CredentialCheck.classify([key(3, "abcd")], 230, 3, "0xABCD")
    end

    test "an empty configured slot names the occupied indices and forbids provisioning" do
      assert {:error, message} =
               CredentialCheck.classify([key(0, "aa"), key(10, "bb")], 153, 3)

      assert message =~ "api_key_index 3 is EMPTY on account_index 153"
      assert message =~ "Registered indices on this account: 0, 10."
      assert message =~ "the account is not the problem"
      assert message =~ "Do NOT run `mix bourse.provision_lighter`"
      assert message =~ "harness server"
      assert message =~ "carrying a stale\nexport from before it was fixed"
      assert message =~ "restart the session"
    end

    test "an account carrying no keys at all says so rather than listing nothing" do
      assert {:error, message} = CredentialCheck.classify([], 230, 3)
      assert message =~ "No key is registered on this account at all."
    end

    test "our key registered at another index asks for the index, not a provision" do
      assert {:error, message} =
               CredentialCheck.classify([key(0, "bb"), key(3, "aa")], 230, 0, "aa")

      assert message =~ "IS registered on account_index\n230, but at api_key_index 3"
      assert message =~ "export LIGHTER_TESTNET_API_KEY_INDEX=3"
      assert message =~ "nothing needs provisioning"
    end

    test "a filled slot holding someone else's key points at the account, not the index" do
      assert {:error, message} = CredentialCheck.classify([key(3, "bb")], 230, 3, "aa")

      assert message =~ "it is NOT the key that\nLIGHTER_TESTNET_API_PRIVATE_KEY derives"
      assert message =~ "LIGHTER_TESTNET_ACCOUNT_INDEX still names the account"
      assert message =~ "the file is not the\nproblem"
    end
  end

  describe "provision_refusal_message/3" do
    test "explains why minting a second key is worse than the symptom" do
      message = CredentialCheck.provision_refusal_message(230, 3, 0)

      assert message =~ "ALREADY registered"
      assert message =~ "export LIGHTER_TESTNET_API_KEY_INDEX=3"
    end

    test "asks for no change when the configuration already names the registered index" do
      message = CredentialCheck.provision_refusal_message(230, 3, 3)

      assert message =~ "already names that index; nothing to change"
      refute message =~ "export LIGHTER_TESTNET_API_KEY_INDEX"
    end
  end

  describe "index parsing" do
    test "a non-numeric account index is refused before any request is made" do
      assert {:error, message} = CredentialCheck.run(account_index: "not-an-index")
      assert message =~ "LIGHTER_TESTNET_ACCOUNT_INDEX"
      assert message =~ "non-negative integer"
    end

    test "a non-numeric key index is refused before any request is made" do
      assert {:error, message} =
               CredentialCheck.run(account_index: 1, api_key_index: "3.5")

      assert message =~ "LIGHTER_TESTNET_API_KEY_INDEX"
    end

    test "a negative index is refused" do
      assert {:error, message} = CredentialCheck.run(account_index: "-1")
      assert message =~ "non-negative integer"
    end

    test "an index of an unusable type reports the variable as unset" do
      assert {:error, message} = CredentialCheck.run(account_index: :missing)
      assert message =~ "LIGHTER_TESTNET_ACCOUNT_INDEX is not set"
    end
  end

  defp key(index, public_key), do: %{index: index, public_key: public_key}
end
