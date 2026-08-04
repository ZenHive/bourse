defmodule Bourse.Signing.Derive do
  @moduledoc """
  First-party signing for Derive (Lyra v2, on Optimism).

  Derive has **two** signature paths, both secp256k1 over a Keccak-256 digest:

  - **REST auth headers** (every private request) — EIP-191 personal-message
    signing of the millisecond timestamp. Emits the header trio:
    `X-LyraWallet` (smart-contract wallet = `credentials.api_key`),
    `X-LyraTimestamp`, `X-LyraSignature` (session-key = `credentials.secret`).
  - **Order signing** (`sign_order/2`) — EIP-712 typed data with a *fixed*
    domain separator. Additive on order endpoints only: when `:order` is in
    params, the packed signature is injected into the JSON body under
    `"signature"`. Never a precondition for private reads.

  Both produce Derive's 65-byte packed signature (`0x ‖ r ‖ s ‖ v`).

  ## Credentials

  - `credentials.api_key` — Derive smart-contract wallet address (`X-LyraWallet`).
    Not the owner EOA unless that address is also a registered session key.
  - `credentials.secret` — private key of a **registered** session key (or the
    wallet itself when it signs). Edge proxy verifies recovered signer against
    the wallet / session-key registry before the app runs; owner EOA is not
    auto-registered on UI onboarding.
  """

  @behaviour Bourse.Signing.Behaviour

  alias Bourse.Credentials
  alias Bourse.Signing
  alias Bourse.Signing.Crypto

  # Derive trade-module domain separators (Optimism mainnet / testnet).
  @domain_separator_prod "d96e5f90797da7ec8dc4e276260c7f3f87fedf68775fbe1ef116e996fc60441b"
  @domain_separator_sandbox "9bcf4dc06df5d8bf23af818d5716491b995020f377d3b7b64c29ed14e3dd1105"

  # ABI types for Derive's eight-field order tuple.
  @order_types ~w(bytes32 uint256 uint256 address bytes32 uint256 address address)
  @trade_module_data_types ~w(address uint256 int256 int256 uint256 uint256 bool)
  @unit_scale 1_000_000_000_000_000_000

  @doc """
  Computes the 32-byte order hash (`hashOrderMessage`).

  `order` is the eight-element list of field values in Derive order:
  `[action_typehash, subaccount_id, nonce, trade_module_address,
  trade_module_data_hash, signature_expiry, derive_wallet_address, wallet_address]`.

  Options: `:testnet` selects the sandbox domain separator (default `false`).
  """
  @spec hash_order_message([term()], keyword()) :: binary()
  def hash_order_message(order, opts \\ []) when is_list(order) do
    account_hash = order |> abi_encode_static(@order_types) |> Crypto.keccak256()
    domain_separator = order_domain_separator(opts)
    Crypto.keccak256(<<0x19, 0x01>> <> domain_separator <> account_hash)
  end

  @doc """
  Signs an order, returning Derive's packed `0x ‖ r ‖ s ‖ v` signature string.

  Options: `:private_key` (required), `:testnet` (default `false`).
  """
  @spec sign_order([term()], keyword()) :: String.t()
  def sign_order(order, opts) do
    private_key = fetch_private_key(opts)

    order
    |> hash_order_message(opts)
    |> Crypto.sign_hash(private_key)
    |> signature_hex()
  end

  @doc "Hashes Derive's trade-module tuple for an EIP-712 order signature."
  @spec trade_module_data_hash(String.t(), integer(), String.t(), String.t(), String.t(), integer(), boolean()) ::
          binary()
  def trade_module_data_hash(base_asset, sub_id, price, amount, max_fee, subaccount_id, is_bid)
      when is_binary(base_asset) and is_integer(sub_id) and is_integer(subaccount_id) and is_boolean(is_bid) do
    [
      base_asset,
      sub_id,
      unit_integer(price),
      unit_integer(amount),
      unit_integer(max_fee),
      subaccount_id,
      is_bid
    ]
    |> abi_encode_static(@trade_module_data_types)
    |> Crypto.keccak256()
  end

  @doc "Derives the session-key EOA address used by Derive's order envelope."
  @spec signer_address(String.t()) :: String.t()
  def signer_address(private_key) when is_binary(private_key) do
    {:ok, <<4, public_key::binary-size(64)>>} =
      private_key |> Crypto.decode_private_key() |> ExSecp256k1.create_public_key()

    <<_::binary-size(12), address::binary-size(20)>> = Crypto.keccak256(public_key)
    "0x" <> Crypto.encode_hex(address)
  end

  @doc """
  Computes the EIP-191 personal-message hash (`hashMessage`) for `message`.
  """
  @spec hash_message(String.t()) :: binary()
  def hash_message(message) when is_binary(message) do
    prefix = "\x19Ethereum Signed Message:\n" <> Integer.to_string(byte_size(message))
    Crypto.keccak256(prefix <> message)
  end

  @doc """
  Signs `message` with EIP-191 personal signing, returning the packed
  `0x ‖ r ‖ s ‖ v` signature string. Options: `:private_key` (required).
  """
  @spec sign_message(String.t(), keyword()) :: String.t()
  def sign_message(message, opts) do
    private_key = fetch_private_key(opts)

    message
    |> hash_message()
    |> Crypto.sign_hash(private_key)
    |> signature_hex()
  end

  @doc """
  `Bourse.Signing.Behaviour` entry point.

  Always emits the REST auth-header trio (`X-LyraWallet` / `X-LyraTimestamp` /
  `X-LyraSignature`) for private requests. When `:order` (or `"order"`) is
  present in params, also injects the EIP-712 packed order signature into the
  JSON body under `"signature"` and drops the order tuple. Order signing is
  additive — private reads with only a JSON body (or empty params) succeed
  without an `:order` precondition.
  """
  @impl true
  @spec sign(Signing.request(), Credentials.t(), Signing.config()) :: Signing.signed_request()
  def sign(request, credentials, config) do
    wallet = require_wallet!(credentials)
    private_key = credentials.secret
    timestamp = to_string(Signing.timestamp_ms_from_config(config))

    auth_signature = sign_message(timestamp, private_key: private_key)

    headers = [
      {"Content-Type", "application/json"},
      {"X-LyraWallet", wallet},
      {"X-LyraTimestamp", timestamp},
      {"X-LyraSignature", auth_signature}
    ]

    body = build_body(request, credentials, config)

    %Bourse.Signing.SignedRequest{
      url: request.path,
      method: request.method,
      headers: headers,
      body: body
    }
  end

  # --- internals ---

  defp build_body(request, credentials, config) do
    params = request.params || %{}
    order = Map.get(params, :order) || Map.get(params, "order")

    cond do
      is_list(order) ->
        testnet = Map.get(config, :testnet, credentials.sandbox)
        order_signature = sign_order(order, private_key: credentials.secret, testnet: testnet)

        params
        |> Map.drop([:order, "order"])
        |> Map.put("signature", order_signature)
        |> Jason.encode!()

      is_binary(request.body) ->
        request.body

      map_size(params) > 0 ->
        Jason.encode!(params)

      true ->
        "{}"
    end
  end

  # Derive signatures pack `0x` + r(64) + s(64) + v(2 hex).
  defp signature_hex(%{r: r, s: s, v: v}) do
    "0x" <> r <> s <> (v |> Integer.to_string(16) |> String.downcase())
  end

  defp order_domain_separator(opts) do
    if Keyword.get(opts, :testnet, false) do
      Base.decode16!(@domain_separator_sandbox, case: :lower)
    else
      Base.decode16!(@domain_separator_prod, case: :lower)
    end
  end

  # ABI-encodes static-only types into concatenated 32-byte words.
  defp abi_encode_static(values, types) do
    values
    |> Enum.zip(types)
    |> Enum.map_join(fn {value, type} -> encode_word(type, value) end)
  end

  # Only the static types in Derive's two signed tuples are supported.
  defp encode_word("bytes32", value), do: to_bytes32(value)
  defp encode_word("address", value), do: encode_address(value)
  defp encode_word("uint256", value) when is_integer(value), do: <<value::unsigned-big-256>>
  defp encode_word("int256", value) when is_integer(value), do: <<value::signed-big-256>>
  defp encode_word("bool", true), do: <<0::248, 1>>
  defp encode_word("bool", false), do: <<0::256>>

  defp unit_integer(value) when is_integer(value), do: value * @unit_scale

  defp unit_integer(value) when is_float(value), do: value |> Float.to_string() |> unit_integer()

  defp unit_integer(value) when is_binary(value) do
    value
    |> Decimal.new()
    |> Decimal.mult(Decimal.new(@unit_scale))
    |> Decimal.to_integer()
  end

  defp to_bytes32(value) when is_binary(value) and byte_size(value) == 32, do: value
  defp to_bytes32(value) when is_binary(value), do: decode_fixed(value, 32, "bytes32")

  defp encode_address(value) when is_binary(value) and byte_size(value) == 20, do: <<0::96>> <> value
  defp encode_address(value) when is_binary(value), do: <<0::96>> <> decode_fixed(value, 20, "address")

  defp decode_fixed(value, size, label) do
    bytes = value |> Crypto.strip_0x() |> Base.decode16!(case: :mixed)

    if byte_size(bytes) == size do
      bytes
    else
      raise ArgumentError, "Derive ABI: #{label} must be #{size} bytes, got #{byte_size(bytes)}"
    end
  end

  defp fetch_private_key(opts) do
    case Keyword.fetch(opts, :private_key) do
      {:ok, key} when is_binary(key) -> Crypto.decode_private_key(key)
      _ -> raise ArgumentError, "Derive signing requires a :private_key option"
    end
  end

  defp require_wallet!(%Credentials{api_key: wallet}) when is_binary(wallet) and wallet != "" do
    wallet
  end

  defp require_wallet!(_credentials) do
    raise ArgumentError, "Derive signing requires credentials.api_key (X-LyraWallet)"
  end
end
