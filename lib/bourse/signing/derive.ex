defmodule Bourse.Signing.Derive do
  @moduledoc """
  First-party signing for Derive (API v3).

  Derive has **two** signature paths, both secp256k1 over a Keccak-256 digest:

  - **Session login** (every private REST request) — EIP-191 personal-message
    signing of the millisecond timestamp string. Emits the header trio
    `X-DeriveWallet` (the owner wallet = `credentials.api_key`),
    `X-DeriveTimestamp`, `X-DeriveSignature` (signed with `credentials.secret`).
  - **Action signing** (`sign_order/2`) — EIP-712 typed data under the fixed
    `Matching` domain. Additive on order endpoints only: when `:order` is in
    params, the packed signature is injected into the JSON body under
    `"signature"`. Never a precondition for private reads.

  Both produce Derive's 65-byte packed signature (`0x ‖ r ‖ s ‖ v`).

  ## Credentials

  - `credentials.api_key` — the wallet that owns the subaccounts: the owner EOA
    or multisig (`X-DeriveWallet`, and the action's `owner`).
  - `credentials.secret` — the private key of that wallet, or of a session key
    the wallet registered through `private/set_session_key`. The venue recovers
    the signer and answers `14026 "Session key not found"` when it is neither.

  ## Domain

  `name "Matching"`, `version "1.0"`, `verifyingContract
  0xeB8d770ec18DB98Db922E9D83260A585b9F0DeAD` on every network; only `chainId`
  differs (`1` mainnet, `11155111` testnet). The two separators below are the
  values Derive publishes at
  https://docs.derive.xyz/authentication/action-signing.md, and the test suite
  recomputes them from those domain fields.
  """

  @behaviour Bourse.Signing.Behaviour

  alias Bourse.Credentials
  alias Bourse.Signing
  alias Bourse.Signing.Crypto
  alias Onchain.ABI.FunctionSelector
  alias Onchain.ABI.TypeEncoder

  # Published v3 `Matching` domain separators (chainId 1 / 11155111).
  @domain_separator_prod "da616dfabb88681b08e1592820a41d55ddc62d68de110e327ae99d734506fe19"
  @domain_separator_sandbox "24d674cd5f2b9d564691c51e9d88f649b99246a2244dd74ce27b96578d773e85"

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
    |> Crypto.packed_signature()
  end

  @doc "Hashes Derive's trade-module tuple for an EIP-712 order signature."
  @spec trade_module_data_hash(String.t(), integer(), String.t(), String.t(), String.t(), integer(), boolean()) ::
          binary()
  def trade_module_data_hash(base_asset, sub_id, price, amount, max_fee, subaccount_id, is_bid)
      when is_binary(base_asset) and is_integer(sub_id) and is_integer(subaccount_id) and is_boolean(is_bid) do
    base_asset
    |> trade_module_data(
      sub_id,
      unit_integer(price),
      unit_integer(amount),
      unit_integer(max_fee),
      subaccount_id,
      is_bid
    )
    |> Crypto.keccak256()
  end

  @doc """
  ABI-encodes Derive's trade-module tuple from already-scaled 1e18 integers.

  Returns the encoded blob rather than its hash, because a caller that has to
  *show* a customer what they are about to sign needs the bytes while a caller
  that only signs needs the hash. Both go through here, so the field order and
  the ABI types are stated once — two copies that agree today are the shape
  that later signs one struct while displaying another.

  `price`, `amount` and `max_fee` arrive already multiplied by 1e18; the
  string-taking `trade_module_data_hash/7` does that scaling itself.
  """
  @spec trade_module_data(String.t(), integer(), integer(), integer(), integer(), integer(), boolean()) :: binary()
  def trade_module_data(base_asset, sub_id, price, amount, max_fee, subaccount_id, is_bid)
      when is_binary(base_asset) and is_integer(sub_id) and is_integer(price) and is_integer(amount) and
             is_integer(max_fee) and is_integer(subaccount_id) and is_boolean(is_bid) do
    abi_encode_static([base_asset, sub_id, price, amount, max_fee, subaccount_id, is_bid], @trade_module_data_types)
  end

  @doc "Derives the signer address (owner wallet or session key) used by Derive's action envelope."
  @spec signer_address(String.t()) :: String.t()
  def signer_address(private_key) when is_binary(private_key) do
    Crypto.address_from_private_key(private_key)
  end

  @doc """
  Computes the EIP-191 personal-message hash (`hashMessage`) for `message`.
  """
  @spec hash_message(String.t()) :: binary()
  def hash_message(message) when is_binary(message) do
    Crypto.hash_message(message)
  end

  @doc """
  Signs `message` with EIP-191 personal signing, returning the packed
  `0x ‖ r ‖ s ‖ v` signature string. Options: `:private_key` (required).
  """
  @spec sign_message(String.t(), keyword()) :: String.t()
  def sign_message(message, opts) do
    Crypto.sign_message(message, opts)
  end

  @doc """
  `Bourse.Signing.Behaviour` entry point.

  Always emits the REST auth-header trio (`X-DeriveWallet` / `X-DeriveTimestamp` /
  `X-DeriveSignature`) for private requests. When `:order` (or `"order"`) is
  present in params, also injects the EIP-712 packed order signature into the
  JSON body under `"signature"` and drops the order tuple. Order signing is
  additive — private reads with only a JSON body (or empty params) succeed
  without an `:order` precondition.
  """

  # --- internals ---

  @impl true
  @spec sign(Signing.request(), Credentials.t(), Signing.config()) :: Signing.signed_request()
  def sign(request, credentials, config) do
    wallet = require_wallet!(credentials)
    private_key = credentials.secret
    timestamp = to_string(Signing.timestamp_ms_from_config(config))

    auth_signature = sign_message(timestamp, private_key: private_key)

    headers = [
      {"Content-Type", "application/json"},
      {"X-DeriveWallet", wallet},
      {"X-DeriveTimestamp", timestamp},
      {"X-DeriveSignature", auth_signature}
    ]

    body = build_body(request, credentials, config)

    %Bourse.Signing.SignedRequest{
      url: request.path,
      method: request.method,
      headers: headers,
      body: body
    }
  end

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

  defp order_domain_separator(opts) do
    if Keyword.get(opts, :testnet, false) do
      Base.decode16!(@domain_separator_sandbox, case: :lower)
    else
      Base.decode16!(@domain_separator_prod, case: :lower)
    end
  end

  # ABI-encodes static-only types into concatenated 32-byte words via `Onchain.ABI`.
  defp abi_encode_static(values, types) do
    decoded = Enum.zip_with(values, types, &decode_abi_value/2)
    type_maps = Enum.map(types, &%{type: FunctionSelector.decode_type(&1)})
    TypeEncoder.encode_raw(decoded, type_maps)
  end

  defp decode_abi_value(value, "bytes32"), do: Crypto.decode_fixed!(value, 32, "Derive ABI: bytes32")
  defp decode_abi_value(value, "address"), do: Crypto.decode_fixed!(value, 20, "Derive ABI: address")
  defp decode_abi_value(value, "uint256") when is_integer(value), do: value
  defp decode_abi_value(value, "int256") when is_integer(value), do: value
  defp decode_abi_value(true, "bool"), do: true
  defp decode_abi_value(false, "bool"), do: false

  defp unit_integer(value) when is_integer(value), do: value * @unit_scale

  defp unit_integer(value) when is_float(value), do: value |> Float.to_string() |> unit_integer()

  defp unit_integer(value) when is_binary(value) do
    value
    |> Decimal.new()
    |> Decimal.mult(Decimal.new(@unit_scale))
    |> Decimal.to_integer()
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
    raise ArgumentError, "Derive signing requires credentials.api_key (X-DeriveWallet)"
  end
end
