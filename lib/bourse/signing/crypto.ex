defmodule Bourse.Signing.Crypto do
  @moduledoc """
  Shared low-level crypto primitives for the custom DEX signing modules
  (`Bourse.Signing.Hyperliquid`, `Bourse.Signing.Derive`).

  Wraps the Keccak-256 (`ex_keccak`) and secp256k1 (`ex_secp256k1`) NIFs.
  Signatures use RFC-6979 deterministic nonces, low-`s` normalization, and
  Ethereum recovery value `v = 27 + recovery_id`.
  """

  @type signature :: %{r: String.t(), s: String.t(), v: non_neg_integer()}

  @doc "Keccak-256 digest of `data` (32 raw bytes)."
  @spec keccak256(iodata()) :: binary()
  def keccak256(data) when is_binary(data), do: ExKeccak.hash_256(data)
  def keccak256(data), do: ExKeccak.hash_256(IO.iodata_to_binary(data))

  @doc """
  Signs a 32-byte `digest` with the secp256k1 `private_key`.

  Returns `%{r, s, v}` where `r`/`s` are lowercase
  64-char hex strings (no `0x`) and `v = 27 + recovery_id`. Signatures use
  RFC-6979 deterministic nonces and canonical low-`s` values.
  """
  @spec sign_hash(binary(), binary()) :: signature()
  def sign_hash(digest, private_key) when is_binary(digest) and byte_size(digest) == 32 and is_binary(private_key) do
    case ExSecp256k1.sign(digest, private_key) do
      {:ok, {r, s, recovery_id}} ->
        %{r: encode_hex(r), s: encode_hex(s), v: 27 + recovery_id}

      {:error, reason} ->
        raise ArgumentError, "secp256k1 sign failed: #{inspect(reason)}"
    end
  end

  @doc """
  Decodes a (`0x`-prefixed) hex private key into the 32-byte binary
  `ExSecp256k1` expects. Accepts the last 64 hex characters.
  """
  @spec decode_private_key(String.t()) :: binary()
  def decode_private_key(private_key) when is_binary(private_key) do
    hex = private_key |> strip_0x() |> String.slice(-64..-1//1)
    Base.decode16!(hex, case: :mixed)
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
end
