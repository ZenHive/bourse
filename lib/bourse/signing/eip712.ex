defmodule Bourse.Signing.EIP712 do
  @moduledoc """
  Minimal EIP-712 typed-data encoder for the custom DEX signing modules
  (`Bourse.Signing.Hyperliquid`).

  Implements canonical EIP-712 encoding for the atomic-field message types
  Hyperliquid uses (`Agent`, `HyperliquidTransaction:*`). The
  result is the EIP-712 digest preimage `0x1901 ‖ domainSeparator ‖ hashStruct`,
  as defined by EIP-712.

  ## Scope

  Only **atomic** field types are supported (`string`, `bytes`, `bytes32`,
  `address`, `bool`, `uint*`, `int*`). Struct-typed fields (nested custom types)
  raise — none of the supported Hyperliquid message types use them, so a nested
  type is a programming error rather than a silent wrong signature.

  The `EIP712Domain` type is rendered in ethers' canonical field order
  (`name`, `version`, `chainId`, `verifyingContract`, `salt`), including only the
  fields present in the supplied domain.
  """

  alias Bourse.Signing.Crypto

  @type field :: %{required(String.t()) => String.t()}
  @type domain :: %{optional(String.t()) => term()}

  # ethers renders EIP712Domain fields in this fixed canonical order,
  # regardless of the order they appear in the supplied domain map.
  @domain_field_order [
    {"name", "string"},
    {"version", "string"},
    {"chainId", "uint256"},
    {"verifyingContract", "address"},
    {"salt", "bytes32"}
  ]

  @doc """
  Encodes typed data into the EIP-712 digest preimage
  `0x1901 ‖ domainSeparator ‖ hashStruct(primaryType, message)`.
  """
  @spec encode(domain(), %{String.t() => [field()]}, String.t(), map()) :: binary()
  def encode(domain, types, primary_type, message) do
    <<0x19, 0x01>> <> domain_separator(domain) <> hash_struct(primary_type, types, message)
  end

  @doc "Computes the 32-byte EIP-712 domain separator for `domain`."
  @spec domain_separator(domain()) :: binary()
  def domain_separator(domain) do
    fields = Enum.filter(@domain_field_order, fn {name, _type} -> Map.has_key?(domain, name) end)
    type_string = "EIP712Domain(" <> Enum.map_join(fields, ",", fn {n, t} -> "#{t} #{n}" end) <> ")"
    type_hash = Crypto.keccak256(type_string)

    encoded =
      Enum.map_join(fields, fn {name, type} ->
        encode_field(type, Map.fetch!(domain, name))
      end)

    Crypto.keccak256(type_hash <> encoded)
  end

  @doc "Computes `hashStruct(primaryType) = keccak256(typeHash ‖ encodeData)`."
  @spec hash_struct(String.t(), %{String.t() => [field()]}, map()) :: binary()
  def hash_struct(primary_type, types, message) do
    fields = Map.fetch!(types, primary_type)
    type_string = encode_type(primary_type, fields)
    type_hash = Crypto.keccak256(type_string)

    encoded =
      Enum.map_join(fields, fn %{"name" => name, "type" => type} ->
        encode_field(type, Map.fetch!(message, name))
      end)

    Crypto.keccak256(type_hash <> encoded)
  end

  defp encode_type(primary_type, fields) do
    body = Enum.map_join(fields, ",", fn %{"name" => name, "type" => type} -> "#{type} #{name}" end)
    "#{primary_type}(#{body})"
  end

  # --- Atomic field encoders (each returns exactly 32 bytes) ---

  defp encode_field("string", value) when is_binary(value), do: Crypto.keccak256(value)

  defp encode_field("bytes", value) when is_binary(value), do: Crypto.keccak256(value)

  defp encode_field("bytes32", value), do: to_bytes32(value)

  defp encode_field("address", value), do: encode_address(value)

  defp encode_field("bool", true), do: <<0::248, 1>>
  defp encode_field("bool", false), do: <<0::256>>

  defp encode_field(type, value) when is_integer(value) do
    if uint_or_int?(type) do
      <<value::unsigned-big-256>>
    else
      raise ArgumentError, "EIP712: unsupported field type #{inspect(type)}"
    end
  end

  defp encode_field(type, value) do
    raise ArgumentError, "EIP712: unsupported field #{inspect(type)} for #{inspect(value)}"
  end

  defp uint_or_int?(type) do
    String.starts_with?(type, "uint") or String.starts_with?(type, "int")
  end

  # bytes32 value: raw 32-byte binary, or a (0x-prefixed) 64-char hex string.
  defp to_bytes32(value) when is_binary(value) and byte_size(value) == 32, do: value

  defp to_bytes32(value) when is_binary(value) do
    bytes = value |> Crypto.strip_0x() |> Base.decode16!(case: :mixed)

    if byte_size(bytes) == 32 do
      bytes
    else
      raise ArgumentError, "EIP712: bytes32 must be 32 bytes, got #{byte_size(bytes)}"
    end
  end

  # address: 20-byte value right-aligned in a 32-byte word.
  defp encode_address(value) when is_binary(value) do
    bytes = value |> Crypto.strip_0x() |> Base.decode16!(case: :mixed)

    if byte_size(bytes) == 20 do
      <<0::96>> <> bytes
    else
      raise ArgumentError, "EIP712: address must be 20 bytes, got #{byte_size(bytes)}"
    end
  end
end
