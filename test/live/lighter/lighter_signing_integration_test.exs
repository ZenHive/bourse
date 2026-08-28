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

    # Same account and key index, one nibble of the API private key flipped: length
    # and scalar range are preserved, so the helper still produces a signature and
    # the venue is what refuses it.
    unauthorized_credentials = %{credentials | secret: flip_one_nibble(credentials.secret)}
    unauthorized = %{exchange | credentials: unauthorized_credentials}

    # A real account this key was never registered against. Lighter answers for the
    # *binding*, not the account's existence — 152 exists on testnet and returns the
    # same code as an index that does not (both observed live 2026-08-28).
    foreign_account_index = account_index + 1
    foreign = %{exchange | options: Map.put(exchange.options, :account_index, foreign_account_index)}

    on_exit(fn ->
      assert :ok = LighterSigning.terminate_helper(credentials, helper_config(exchange))
      assert :ok = LighterSigning.terminate_helper(unauthorized_credentials, helper_config(unauthorized))
      assert :ok = LighterSigning.terminate_helper(credentials, helper_config(foreign))
    end)

    auth_deadline = System.system_time(:second) + @auth_lifetime_seconds

    assert {:ok, %{status: 200, body: %{"code" => 200} = body}} =
             Bourse.Lighter.private_get_accountlimits(exchange, %{
               "account_index" => account_index,
               "auth_deadline" => auth_deadline
             })

    assert is_binary(body["user_tier"])

    assert {:error,
            %Error{
              type: :authentication_error,
              code: 29_500,
              raw: %{"code" => 29_500, "message" => signature_message}
            }} =
             Bourse.Lighter.private_get_accountlimits(unauthorized, %{
               "account_index" => account_index,
               "auth_deadline" => auth_deadline
             })

    assert signature_message =~ "invalid signature"

    assert {:error,
            %Error{
              type: :authentication_error,
              code: 20_013,
              raw: %{"code" => 20_013, "message" => binding_message}
            }} =
             Bourse.Lighter.private_get_accountlimits(foreign, %{
               "account_index" => foreign_account_index,
               "auth_deadline" => auth_deadline
             })

    assert binding_message =~ "couldnt find account"
  end

  test "testnet accepts unified order reads with and without a market scope" do
    credentials = require_credentials!()
    account_index = String.to_integer(System.fetch_env!("LIGHTER_TESTNET_ACCOUNT_INDEX"))

    exchange =
      Exchange.new!("lighter",
        credentials: credentials,
        sandbox: true,
        options: %{account_index: account_index}
      )

    on_exit(fn -> assert :ok = LighterSigning.terminate_helper(credentials, helper_config(exchange)) end)

    opts = [account_index: account_index, auth_deadline: System.system_time(:second) + @auth_lifetime_seconds]

    assert {:ok, open_orders} = Bourse.fetch_open_orders(exchange, opts)
    assert {:ok, closed_orders} = Bourse.fetch_closed_orders(exchange, opts)
    assert is_list(open_orders)
    assert is_list(closed_orders)

    assert {:ok, exchange} = Bourse.load_markets(exchange)
    symbol = exchange.markets |> List.first() |> Map.fetch!(:symbol)

    assert {:ok, scoped_open_orders} = Bourse.fetch_open_orders(exchange, [{:symbol, symbol} | opts])
    assert {:ok, scoped_closed_orders} = Bourse.fetch_closed_orders(exchange, [{:symbol, symbol} | opts])
    assert is_list(scoped_open_orders)
    assert is_list(scoped_closed_orders)
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

  # Keeps the hex length and stays far inside the scalar range, so the signer still
  # signs and only the venue can reject the result.
  defp flip_one_nibble(<<head::binary-40, nibble::binary-1, tail::binary>>) do
    head <> if(nibble == "a", do: "b", else: "a") <> tail
  end

  defp helper_config(exchange) do
    exchange.signing_config
    |> Map.put(:base_url, @testnet_url)
    |> Map.put(:testnet, exchange.sandbox)
    |> Map.put(:exchange_options, exchange.options)
  end
end
