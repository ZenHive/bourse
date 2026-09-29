defmodule Bourse.Lighter.CredentialCheckTest do
  use ExUnit.Case, async: false

  alias Bourse.Lighter.CredentialCheck
  alias Mix.Tasks.Bourse.BuildLighterSigner

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_lighter

  # Every assertion below is against the venue's own registry. There is no
  # offline shape to assert instead: the whole point of this check is that the
  # configured triple and the venue's registry can disagree, and only the venue
  # knows which indices it holds.

  test "the configured credential triple matches what the venue has registered" do
    assert :ok = CredentialCheck.run(sandbox: true)
  end

  test "an unoccupied api_key_index is reported as the empty slot it is, naming the occupied ones" do
    occupied = occupied_indices()
    empty_index = Enum.find(0..254, &(&1 not in occupied))

    assert {:error, message} = CredentialCheck.run(sandbox: true, api_key_index: empty_index)
    assert message =~ "api_key_index #{empty_index} is EMPTY"
    assert message =~ "Do NOT run `mix bourse.provision_lighter`"

    for index <- occupied do
      assert message =~ to_string(index)
    end
  end

  test "the configured signing key is located at the configured index, not merely present" do
    configured = String.to_integer(System.fetch_env!("LIGHTER_TESTNET_API_KEY_INDEX"))

    assert {:ok, ^configured} = CredentialCheck.locate(derived_public_key(), sandbox: true)
  end

  test "a key the account does not carry is reported as not registered" do
    unregistered = String.duplicate("a", 80)

    assert {:error, :not_registered} = CredentialCheck.locate(unregistered, sandbox: true)
  end

  test "a malformed account index is refused before any request is made" do
    assert {:error, message} = CredentialCheck.run(sandbox: true, account_index: "not-an-index")
    assert message =~ ":account_index"
    assert message =~ "non-negative integer"
  end

  test "the provisioning refusal explains why a second key is worse than the symptom" do
    message = CredentialCheck.provision_refusal_message(7, 3, 0)

    assert message =~ "ALREADY registered"
    assert message =~ "account_index 7"
    assert message =~ "api_key_index 3"
    assert message =~ "break\nevery machine still configured with 3"
    assert message =~ "export LIGHTER_TESTNET_API_KEY_INDEX=3"
    assert message =~ "harness server"
  end

  test "the refusal asks for no config change when the configured index is already the registered one" do
    message = CredentialCheck.provision_refusal_message(7, 3, 3)

    assert message =~ "already names that index; nothing to change"
    refute message =~ "export LIGHTER_TESTNET_API_KEY_INDEX"
  end

  test "the zero-arity forms read the configured environment" do
    assert :ok = CredentialCheck.run()
    assert {:ok, _index} = CredentialCheck.locate(derived_public_key())
  end

  test "an unreachable host is reported as unreachable, never as a credential verdict" do
    assert {:error, message} =
             CredentialCheck.run(account_index: 1, base_url: "http://127.0.0.1:1")

    assert message =~ "Could not reach Lighter at http://127.0.0.1:1"
    refute message =~ "EMPTY"
  end

  # The venue answers an unknown account_index with an api_keys list carrying no
  # registered key -- exactly the shape a real account holding no keys returns.
  # There is no "no such account" signal to read, so the check cannot report one:
  # an unknown account and an empty account are indistinguishable from outside,
  # and both correctly read as EMPTY. Pinned here so a future session does not
  # "fix" the check to claim a distinction the venue never makes.
  test "an account the venue does not know is indistinguishable from one holding no keys" do
    assert {:error, message} = CredentialCheck.run(sandbox: true, account_index: 999_999_999)

    # Lighter lists no keys for an unknown account rather than erroring, so an
    # explicit index cannot tell "gone" from "empty". The default path never
    # hits this: it resolves the account from the wallet, where a missing
    # account is its own 21100 verdict.
    assert message =~ "account_index 999999999 carries NO registered key at all"
    refute message =~ "did not list api keys"
  end

  test "a non-JSON response is reported by status rather than parsed as a registry" do
    assert {:error, message} =
             CredentialCheck.run(
               account_index: 1,
               base_url: "https://testnet.zklighter.elliot.ai/not-the-api"
             )

    assert message =~ "unexpected_status"
  end

  test "a wallet with no account is reported as a testnet reset with the operator repair" do
    # An address nobody provisions: the venue answers 21100 "account not found".
    assert {:error, message} =
             CredentialCheck.resolve_account_index(
               l1_address: "0x0000000000000000000000000000000000000001",
               sandbox: true
             )

    assert message =~ "21100"
    assert message =~ "testnet has been reset"
    assert message =~ "mix bourse.provision_lighter"
  end

  test "sandbox: false selects the mainnet host" do
    assert {:error, message} = CredentialCheck.run(sandbox: false, account_index: 999_999_999)
    refute message =~ "testnet.zklighter"
  end

  defp occupied_indices do
    account_index = System.fetch_env!("LIGHTER_TESTNET_ACCOUNT_INDEX")

    %{status: 200, body: %{"api_keys" => keys}} =
      Req.get!(
        "https://testnet.zklighter.elliot.ai/api/v1/apikeys" <>
          "?account_index=#{account_index}&api_key_index=255",
        receive_timeout: 15_000
      )

    for %{"api_key_index" => index, "public_key" => public_key} <- keys,
        String.trim(public_key, "0") != "",
        do: index
  end

  defp derived_public_key do
    source_dir = BuildLighterSigner.source_dir()
    go = System.find_executable("go") || flunk("Go is required to derive the zk public key")

    {output, 0} =
      System.cmd(go, ["run", "./cmd/derive_pubkey"],
        cd: source_dir,
        stderr_to_stdout: true,
        env: [{"LIGHTER_SIGNER_API_PRIVATE_KEY", System.fetch_env!("LIGHTER_TESTNET_API_PRIVATE_KEY")}]
      )

    String.trim(output)
  end
end
