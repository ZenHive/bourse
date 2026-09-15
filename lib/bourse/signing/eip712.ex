defmodule Bourse.Signing.EIP712 do
  @moduledoc """
  Minimal EIP-712 typed-data encoder for the custom DEX signing modules
  (`Bourse.Signing.Hyperliquid`).

  Thin representation adapter over Cartouche 0.9.0 `Cartouche.Typed`. The
  public functions still take Bourse's map/`%{"name","type"}` shapes and return
  the EIP-712 digest preimage `0x1901 ‖ domainSeparator ‖ hashStruct`.

  ## Hashing boundaries

  * `encode/4` hashes with an **explicit** `primary_type`. Cartouche.Typed.encode/1
    infers the primary type from value keys (`find_type/2`); that is not used.
  * `hash_struct/3` calls `Cartouche.Typed.hash_struct/3` (keccak of typeHash ‖
    encodeData). Callers that need a digest (`Hyperliquid.sign_l1_action/3`)
    keccak the preimage themselves — this module does not hash the 0x1901
    envelope.
  * Cartouche.Typed.Type.deserialize_type/1 only accepts `uint256` among the
    `uint*` family. Hyperliquid user-signed actions use `uint64`; the adapter
    parses `uintN`/`bytesN` into `{:uint, n}`/`{:bytes, n}` tuples that
    `serialize_type/1` and `encode_data_value/2` already accept.
  * Cartouche left-pads short `bytes32`/`address` values. Bourse rejects them
    so a truncated hex string cannot silently become a different word.

  ## Scope

  Only **atomic** field types are supported (`string`, `bytes`, `bytes32`,
  `address`, `bool`, `uint*`). Struct-typed fields (nested custom types) and
  `int*` raise — Cartouche 0.9.0 Typed has no `{:int, n}` primitive (signed
  integers for Derive orders go through Hieroglyph ABI, not this encoder).
  None of the supported Hyperliquid message types use nested structs or ints.

  The `EIP712Domain` type is rendered in ethers' canonical field order
  (`name`, `version`, `chainId`, `verifyingContract`, `salt`), including only the
  fields present in the supplied domain — `Cartouche.Typed.Domain.domain_type/1`.
  """

  alias Bourse.Signing.Crypto
  alias Cartouche.Typed
  alias Cartouche.Typed.Domain
  alias Cartouche.Typed.Type

  @type field :: %{required(String.t()) => String.t()}
  @type domain :: %{optional(String.t()) => term()}

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
  def domain_separator(domain) when is_map(domain) do
    typed = %Typed{domain: Domain.deserialize(domain), types: %{}, value: %{}}
    Typed.domain_seperator(typed)
  end

  @doc "Computes `hashStruct(primaryType) = keccak256(typeHash ‖ encodeData)`."
  @spec hash_struct(String.t(), %{String.t() => [field()]}, map()) :: binary()
  def hash_struct(primary_type, types, message) do
    cartouche_types = to_cartouche_types(types)
    fields = Map.fetch!(types, primary_type)
    cartouche_message = to_cartouche_message(fields, message)
    Typed.hash_struct(primary_type, cartouche_message, cartouche_types)
  end

  defp to_cartouche_types(types) do
    Map.new(types, fn {name, fields} ->
      {name, %Type{fields: Enum.map(fields, &to_cartouche_field/1)}}
    end)
  end

  defp to_cartouche_field(%{"name" => name, "type" => type}) do
    {name, parse_atomic_type(type)}
  end

  # Cartouche.Typed.Type.deserialize_type/1 handles address/string/bytes/bool/uint256/bytes32
  # and uppercase custom types. uint64 (Hyperliquid) and other uintN/bytesN are parsed here.
  defp parse_atomic_type(type) when is_binary(type) do
    case parse_cartouche_type(type) do
      parsed when is_atom(parsed) or is_tuple(parsed) -> parsed
      _custom -> raise ArgumentError, "EIP712: unsupported field type #{inspect(type)}"
    end
  end

  defp parse_cartouche_type(type) do
    Type.deserialize_type(type)
  rescue
    RuntimeError -> parse_sized_type(type)
  end

  defp parse_sized_type("uint" <> rest) do
    case Integer.parse(rest) do
      {n, ""} when n > 0 -> {:uint, n}
      _other -> raise ArgumentError, "EIP712: unsupported field type #{inspect("uint" <> rest)}"
    end
  end

  defp parse_sized_type("bytes" <> rest) do
    case Integer.parse(rest) do
      {n, ""} when n > 0 -> {:bytes, n}
      _other -> raise ArgumentError, "EIP712: unsupported field type #{inspect("bytes" <> rest)}"
    end
  end

  defp parse_sized_type(type) do
    raise ArgumentError, "EIP712: unsupported field type #{inspect(type)}"
  end

  defp to_cartouche_message(fields, message) do
    Map.new(fields, fn %{"name" => name, "type" => type} ->
      {name, convert_value(type, Map.fetch!(message, name))}
    end)
  end

  defp convert_value("string", value) when is_binary(value), do: value
  defp convert_value("bytes", value) when is_binary(value), do: value
  defp convert_value("bool", value) when is_boolean(value), do: value
  defp convert_value("uint" <> _rest, value) when is_integer(value), do: value

  defp convert_value("bytes" <> rest, value) when rest != "" do
    {n, ""} = Integer.parse(rest)
    exact_bytes(value, n, "bytes#{n}")
  end

  defp convert_value("address", value), do: exact_bytes(value, 20, "address")

  defp convert_value(type, value) when is_integer(value) do
    raise ArgumentError, "EIP712: unsupported field type #{inspect(type)}"
  end

  defp convert_value(type, value) do
    raise ArgumentError, "EIP712: unsupported field #{inspect(type)} for #{inspect(value)}"
  end

  defp exact_bytes(value, size, _label) when is_binary(value) and byte_size(value) == size, do: value

  defp exact_bytes(value, size, label) when is_binary(value) do
    bytes = value |> Crypto.strip_0x() |> Base.decode16!(case: :mixed)

    if byte_size(bytes) == size do
      bytes
    else
      raise ArgumentError, "EIP712: #{label} must be #{size} bytes, got #{byte_size(bytes)}"
    end
  end
end
