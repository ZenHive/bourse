defmodule Bourse.LighterProvision do
  @moduledoc """
  Testnet Lighter account provisioning helpers.

  Builds the L1 ChangePubKey personal-message, checks the recovered signer
  against the account address, and parses venue JSON for the mix task. The L1
  private key is an explicit argument — this module never reads the
  environment.
  """

  alias Bourse.Signing.Crypto

  @testnet_url "https://testnet.zklighter.elliot.ai"
  @testnet_chain_id 300
  @change_pub_key_tx_type 8
  @l1_template """
  Register Lighter Account

  pubkey: 0x~s
  nonce: ~s
  account index: ~s
  api key index: ~s
  Only sign this message for a trusted client!\
  """

  @doc "Lighter testnet REST host used by provisioning."
  @spec testnet_url() :: String.t()
  def testnet_url, do: @testnet_url

  @doc "Lighter testnet chain id (part of the zk-signed payload)."
  @spec testnet_chain_id() :: 300
  def testnet_chain_id, do: @testnet_chain_id

  @doc "L2 transaction type for ChangePubKey."
  @spec change_pub_key_tx_type() :: 8
  def change_pub_key_tx_type, do: @change_pub_key_tx_type

  @doc "Formats the L1 personal-message body TemplateChangePubKey covers."
  @spec l1_message(String.t(), non_neg_integer(), pos_integer(), non_neg_integer()) :: String.t()
  def l1_message(pub_key, nonce, account_index, api_key_index)
      when is_binary(pub_key) and is_integer(nonce) and nonce >= 0 do
    format_l1_message(pub_key, nonce, account_index, api_key_index)
  end

  @doc "EIP-191 personal-signs `message` with the explicit L1 private key."
  @spec sign_l1_message(String.t(), String.t()) :: String.t()
  def sign_l1_message(message, l1_private_key) when is_binary(message) and is_binary(l1_private_key) do
    Crypto.sign_message(message, private_key: l1_private_key)
  end

  @doc """
  Recovers the signer from `signature` and requires it equal `l1_address`.
  """
  @spec assert_signer(String.t(), String.t(), String.t()) ::
          :ok | {:error, {:signer_mismatch, String.t(), String.t()} | :invalid_signature}
  def assert_signer(l1_address, message, signature)
      when is_binary(l1_address) and is_binary(message) and is_binary(signature) do
    expected = normalize_address(l1_address)

    case Crypto.recover_signer_address(message, signature) do
      {:ok, recovered} ->
        if recovered == expected do
          :ok
        else
          {:error, {:signer_mismatch, recovered, expected}}
        end

      {:error, :invalid_signature} ->
        {:error, :invalid_signature}
    end
  end

  @doc "Lowercase `0x`-prefixed 20-byte address."
  @spec normalize_address(String.t()) :: String.t()
  def normalize_address(address) when is_binary(address) do
    "0x" <> (address |> Crypto.strip_0x() |> String.downcase())
  end

  @doc "Lowercase hex public key without a `0x` prefix."
  @spec normalize_pub_key(String.t()) :: String.t()
  def normalize_pub_key(pub_key) when is_binary(pub_key) do
    pub_key |> Crypto.strip_0x() |> String.downcase()
  end

  @doc "Fixed-width `0x` + 16 hex digits used in TemplateChangePubKey integer fields."
  @spec hex10(non_neg_integer()) :: String.t()
  def hex10(value) when is_integer(value) and value >= 0 do
    "0x" <> (value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(16, "0"))
  end

  @doc "True when a Lighter JSON envelope carries success code 200."
  @spec code_ok?(map()) :: boolean()
  def code_ok?(%{"code" => 200}), do: true
  def code_ok?(%{"code" => "200"}), do: true
  def code_ok?(_body), do: false

  @doc "Reads the faucet success envelope."
  @spec faucet_ok?(map()) :: boolean()
  def faucet_ok?(body), do: code_ok?(body)

  @doc "Picks the first account index from `accountsByL1Address`."
  @spec parse_account_index(map()) :: {:ok, pos_integer()} | {:error, :account_not_found}
  def parse_account_index(%{"sub_accounts" => accounts} = body) when is_list(accounts) do
    parse_sub_accounts(code_ok?(body), accounts)
  end

  def parse_account_index(_body), do: {:error, :account_not_found}

  @doc "Reads one API-key row from `GET /api/v1/apikeys`."
  @spec parse_api_key(map(), non_neg_integer()) ::
          {:ok, %{public_key: String.t(), nonce: integer()}} | {:error, :api_key_not_found}
  def parse_api_key(%{"api_keys" => keys} = body, api_key_index) when is_list(keys) and is_integer(api_key_index) do
    parse_api_keys(code_ok?(body), keys, api_key_index)
  end

  def parse_api_key(_body, _api_key_index), do: {:error, :api_key_not_found}

  @doc "Reads `nextNonce` from the venue envelope."
  @spec parse_nonce(map()) :: {:ok, non_neg_integer()} | {:error, :nonce_not_found}
  def parse_nonce(%{"nonce" => nonce} = body) do
    parse_ok_nonce(code_ok?(body), nonce)
  end

  def parse_nonce(_body), do: {:error, :nonce_not_found}

  defp format_l1_message(pub_key, nonce, account_index, api_key_index)
       when is_integer(account_index) and account_index > 0 and api_key_index in 0..255 do
    @l1_template
    |> :io_lib.format([
      pub_key |> Crypto.strip_0x() |> String.downcase(),
      hex10(nonce),
      hex10(account_index),
      hex10(api_key_index)
    ])
    |> IO.iodata_to_binary()
  end

  defp parse_sub_accounts(false, _accounts), do: {:error, :account_not_found}

  defp parse_sub_accounts(true, accounts) do
    case Enum.find_value(accounts, &account_index/1) do
      index when is_integer(index) and index > 0 -> {:ok, index}
      _other -> {:error, :account_not_found}
    end
  end

  defp parse_api_keys(false, _keys, _api_key_index), do: {:error, :api_key_not_found}

  defp parse_api_keys(true, keys, api_key_index) do
    keys
    |> Enum.find(&matching_api_key?(&1, api_key_index))
    |> api_key_row()
  end

  defp parse_ok_nonce(false, _nonce), do: {:error, :nonce_not_found}

  defp parse_ok_nonce(true, nonce) do
    case json_integer(nonce) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> {:error, :nonce_not_found}
    end
  end

  defp account_index(account) when is_map(account) do
    case json_integer(Map.get(account, "index") || Map.get(account, "account_index")) do
      index when is_integer(index) and index > 0 -> index
      _other -> nil
    end
  end

  defp account_index(_account), do: nil

  defp matching_api_key?(key, api_key_index) when is_map(key) do
    json_integer(Map.get(key, "api_key_index")) == api_key_index
  end

  defp matching_api_key?(_key, _api_key_index), do: false

  defp api_key_row(%{"public_key" => public_key} = key) when is_binary(public_key) do
    case json_integer(Map.get(key, "nonce")) do
      nonce when is_integer(nonce) ->
        {:ok, %{public_key: normalize_pub_key(public_key), nonce: nonce}}

      _other ->
        {:error, :api_key_not_found}
    end
  end

  defp api_key_row(_key), do: {:error, :api_key_not_found}

  defp json_integer(value) when is_integer(value), do: value

  defp json_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp json_integer(_value), do: nil
end
