defmodule Bourse.LighterSigningIntegrationTest do
  use ExUnit.Case, async: false

  alias Bourse.Credentials
  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.Signing.Lighter, as: LighterSigning

  @moduletag :integration
  @moduletag :network
  @moduletag :exchange_lighter

  @testnet_url "https://testnet.zklighter.elliot.ai"
  @auth_lifetime_seconds 300

  test "testnet accepts an official auth token and rejects an unauthorized signing key" do
    credentials = require_credentials!()
    account_index = String.to_integer(System.fetch_env!("LIGHTER_TESTNET_ACCOUNT_INDEX"))

    exchange =
      Exchange.new!("lighter",
        credentials: credentials,
        sandbox: true,
        options: %{account_index: account_index}
      )

    auth_deadline = System.system_time(:second) + @auth_lifetime_seconds

    assert {:ok, %{status: 200, body: %{"code" => 200} = body}} =
             Bourse.Lighter.private_get_accountlimits(exchange, %{
               "account_index" => account_index,
               "auth_deadline" => auth_deadline
             })

    assert is_binary(body["user_tier"])

    mismatched_account_index = account_index + 1
    mismatched = %{exchange | options: Map.put(exchange.options, :account_index, mismatched_account_index)}

    on_exit(fn ->
      assert :ok = LighterSigning.terminate_helper(credentials, helper_config(exchange))
      assert :ok = LighterSigning.terminate_helper(credentials, helper_config(mismatched))
    end)

    assert {:error,
            %Error{
              type: :authentication_error,
              code: 29_500,
              raw: %{"code" => 29_500, "message" => message}
            }} =
             Bourse.Lighter.private_get_accountlimits(mismatched, %{
               "account_index" => mismatched_account_index,
               "auth_deadline" => auth_deadline
             })

    assert message =~ "invalid signature"
  end

  defp require_credentials! do
    required = [
      "LIGHTER_TESTNET_API_KEY_INDEX",
      "LIGHTER_TESTNET_ACCOUNT_INDEX",
      "LIGHTER_TESTNET_API_PRIVATE_KEY"
    ]

    missing = Enum.reject(required, &present_env?/1)

    if missing != [] do
      flunk("""
      Missing Lighter testnet credentials: #{Enum.join(missing, ", ")}

      Set:
        export LIGHTER_TESTNET_API_KEY_INDEX="your-authorized-index"
        export LIGHTER_TESTNET_ACCOUNT_INDEX="your-account-index"
        export LIGHTER_TESTNET_API_PRIVATE_KEY="your-40-byte-hex-api-signing-key"

      Create an account-authorized API key at: https://testnet.zklighter.elliot.ai
      """)
    end

    Credentials.new!(
      api_key: System.fetch_env!("LIGHTER_TESTNET_API_KEY_INDEX"),
      uid: System.fetch_env!("LIGHTER_TESTNET_ACCOUNT_INDEX"),
      secret: System.fetch_env!("LIGHTER_TESTNET_API_PRIVATE_KEY")
    )
  end

  defp present_env?(name) do
    case System.get_env(name) do
      value when is_binary(value) -> String.trim(value) != ""
      nil -> false
    end
  end

  defp helper_config(exchange) do
    exchange.signing_config
    |> Map.put(:base_url, @testnet_url)
    |> Map.put(:testnet, exchange.sandbox)
    |> Map.put(:exchange_options, exchange.options)
  end
end
