defmodule Bourse.Signing.Crypto do
  @moduledoc """
  Shared low-level crypto primitives for the custom DEX signing modules
  (`Bourse.Signing.Hyperliquid`, `Bourse.Signing.Derive`) and Lighter L1
  ChangePubKey personal-message signatures.

  Thin representation adapter over Onchain 0.16 (`Onchain.Hash.keccak`,
  `Onchain.Signer.Secp256k1.sign_payload/get_address`, `Onchain.Recover`
  digest recovery). Signatures use RFC-6979 deterministic nonces, low-`s`
  normalization, and Ethereum recovery value `v = 27 + recovery_id`.
  """

  alias Onchain.Recover
  alias Onchain.Signer.Secp256k1

  @type signature :: %{r: String.t(), s: String.t(), v: non_neg_integer()}

  # secp256k1 group order n; Ethereum signatures must be low-s (s <= n/2).
  @secp256k1_n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
  @secp256k1_half_n div(@secp256k1_n, 2)

  @doc """
  Computes the EIP-191 personal-message hash (`hashMessage`) for `message`:
  keccak of `0x19 ‖ "Ethereum Signed Message:\\n" ‖ byte_size ‖ message`, the
  envelope built by `Onchain.Recover.prefix_eth/1`. EIP-191 measures the
  message in bytes; `crypto_test.exs` pins that on a multi-byte message.
  """
  @spec hash_message(String.t()) :: binary()
  def hash_message(message) when is_binary(message) do
    message |> Recover.prefix_eth() |> keccak256()
  end

  @doc """
  Signs `message` with EIP-191 personal signing, returning the packed
  `0x ‖ r ‖ s ‖ v` signature string. Options: `:private_key` (required).
  """
  @spec sign_message(String.t(), keyword()) :: String.t()
  def sign_message(message, opts) when is_binary(message) and is_list(opts) do
    private_key = fetch_private_key(opts)

    message
    |> hash_message()
    |> sign_hash(private_key)
    |> packed_signature()
  end

  @doc """
  Recovers the EIP-191 signer address from `message` and a packed `0x ‖ r ‖ s ‖ v`
  signature. `v` may be 27/28 or the raw recovery id 0/1.
  """
  @spec recover_signer_address(String.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_signature}
  def recover_signer_address(message, signature) when is_binary(message) and is_binary(signature) do
    digest = hash_message(message)

    try do
      address = Recover.recover_eth_from_digest(digest, signature)
      {:ok, "0x" <> encode_hex(address)}
    rescue
      _error in [ArgumentError, ErlangError, FunctionClauseError, MatchError] ->
        {:error, :invalid_signature}
    end
  end

  @doc "Keccak-256 digest of `data` (32 raw bytes)."
  @spec keccak256(iodata()) :: binary()
  def keccak256(data) when is_binary(data), do: Onchain.Hash.keccak(data)
  def keccak256(data), do: data |> IO.iodata_to_binary() |> Onchain.Hash.keccak()

  @doc """
  Signs a 32-byte `digest` with the secp256k1 `private_key`.

  Returns `%{r, s, v}` where `r`/`s` are lowercase
  64-char hex strings (no `0x`) and `v = 27 + recovery_id`. Signatures use
  RFC-6979 deterministic nonces and canonical low-`s` values.

  `Onchain.Signer.Secp256k1.sign_payload/2` signs the digest directly (no
  second keccak). Low-`s` is enforced with `Onchain.Recover.normalize_low_s/1`,
  which clears the recovery id when it flips `s`, so recovery is re-derived
  with `Onchain.Recover.find_recid_from_digest/3` against the same digest.
  """
  @spec sign_hash(binary(), binary()) :: signature()
  def sign_hash(digest, private_key) when is_binary(digest) and byte_size(digest) == 32 and is_binary(private_key) do
    case signed_components(digest, private_key) do
      {:ok, {low_s, recid}} ->
        %{r: integer_hex(low_s.r), s: integer_hex(low_s.s), v: 27 + recid}

      {:error, reason} ->
        raise ArgumentError, "secp256k1 sign failed: #{inspect(reason)}"
    end
  end

  @doc """
  Derives the lowercase `0x`-prefixed Ethereum address for `private_key`.
  """
  @spec address_from_private_key(String.t() | binary()) :: String.t()
  def address_from_private_key(private_key) when is_binary(private_key) do
    key = if byte_size(private_key) == 32, do: private_key, else: decode_private_key(private_key)

    {:ok, address} = Secp256k1.get_address(key)
    "0x" <> encode_hex(address)
  end

  @doc """
  Decodes a (`0x`-prefixed) hex private key into the 32-byte binary
  `Onchain.Signer.Secp256k1` expects. Accepts the last 64 hex characters.
  """
  @spec decode_private_key(String.t()) :: binary()
  def decode_private_key(private_key) when is_binary(private_key) do
    hex = private_key |> strip_0x() |> String.slice(-64..-1//1)
    Base.decode16!(hex, case: :mixed)
  end

  @doc """
  Returns `value` as exactly `size` raw bytes: a `size`-byte binary passes
  through, anything else is decoded as (`0x`-prefixed) hex. A short or long value
  raises instead of being padded, so a truncated hex string cannot silently
  become a different word. `label` prefixes the error message.
  """
  @spec decode_fixed!(binary(), pos_integer(), String.t()) :: binary()
  def decode_fixed!(value, size, _label) when is_binary(value) and byte_size(value) == size, do: value

  def decode_fixed!(value, size, label) when is_binary(value) do
    bytes = decode_hex(value)

    if byte_size(bytes) == size do
      bytes
    else
      raise ArgumentError, "#{label} must be #{size} bytes, got #{byte_size(bytes)}"
    end
  end

  @doc "Lowercase hex-encodes a binary (no `0x` prefix)."
  @spec encode_hex(binary()) :: String.t()
  def encode_hex(binary), do: Base.encode16(binary, case: :lower)

  @doc "Decodes a (`0x`-prefixed) hex string into a binary."
  @spec decode_hex(String.t()) :: binary()
  def decode_hex(hex), do: hex |> strip_0x() |> Base.decode16!(case: :mixed)

  @doc "Strips a leading `0x`/`0X` prefix if present."
  @spec strip_0x(String.t()) :: String.t()
  def strip_0x("0x" <> rest), do: rest
  def strip_0x("0X" <> rest), do: rest
  def strip_0x(hex) when is_binary(hex), do: hex

  @doc "secp256k1 curve order `n` — used by tests asserting the low-`s` bound."
  @spec secp256k1_n() :: pos_integer()
  def secp256k1_n, do: @secp256k1_n

  @doc "Half the secp256k1 curve order — canonical signatures have `s <= n/2`."
  @spec secp256k1_half_n() :: pos_integer()
  def secp256k1_half_n, do: @secp256k1_half_n

  defp signed_components(digest, private_key) do
    {:ok, signature} = Secp256k1.sign_payload(digest, private_key)
    {:ok, address} = Secp256k1.get_address(private_key)
    low_s = Recover.normalize_low_s(signature)
    {:ok, recid} = Recover.find_recid_from_digest(digest, low_s, address)
    {:ok, {low_s, recid}}
  rescue
    error in [ArgumentError, ErlangError, FunctionClauseError, MatchError] ->
      {:error, Exception.message(error)}
  end

  @doc "Packs `%{r, s, v}` into the `0x ‖ r ‖ s ‖ v` hex signature string."
  @spec packed_signature(signature()) :: String.t()
  def packed_signature(%{r: r, s: s, v: v}) do
    "0x" <> r <> s <> (v |> Integer.to_string(16) |> String.downcase())
  end

  defp integer_hex(value) when is_integer(value) and value >= 0 do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(64, "0")
  end

  defp fetch_private_key(opts) do
    case Keyword.fetch(opts, :private_key) do
      {:ok, key} when is_binary(key) -> decode_private_key(key)
      _other -> raise ArgumentError, "signing requires a :private_key option"
    end
  end
end
