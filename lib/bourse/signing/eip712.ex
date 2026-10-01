defmodule Bourse.Signing.EIP712 do
  @moduledoc """
  Minimal EIP-712 typed-data encoder for the custom DEX signing modules
  (`Bourse.Signing.Hyperliquid`).

  Thin representation adapter over Onchain 0.16 `Onchain.Typed`. The
  public functions still take Bourse's map/`%{"name","type"}` shapes and return
  the EIP-712 digest preimage `0x1901 ‖ domainSeparator ‖ hashStruct`.

  ## Hashing boundaries

  * `encode/4` hashes with an **explicit** `primary_type`. Onchain.Typed.encode/1
    infers the primary type from value keys (`find_type/2`); that is not used.
  * `hash_struct/3` calls `Onchain.Typed.hash_struct/3` (keccak of typeHash ‖
    encodeData). Callers that need a digest (`Hyperliquid.sign_l1_action/3`)
    keccak the preimage themselves — this module does not hash the 0x1901
    envelope.
  * Field types are parsed by `Onchain.Typed.Type.deserialize_type/1`, which
    covers every `uintN`/`intN`/`bytesN` width (Hyperliquid user-signed actions
    use `uint64`).
  * Onchain left-pads short `bytes32`/`address` values. Bourse rejects them
    so a truncated hex string cannot silently become a different word.

  ## Scope

  Only **atomic** field types are supported (`string`, `bytes`, `bytes32`,
  `address`, `bool`, `uint*`). Struct-typed fields (nested custom types) and
  `int*` values raise — no supported message type needs them (signed integers
  for Derive orders go through `Onchain.ABI`, not this encoder). None of the
  supported Hyperliquid message types use nested structs or ints.

  The `EIP712Domain` type is rendered in ethers' canonical field order
  (`name`, `version`, `chainId`, `verifyingContract`, `salt`), including only the
  fields present in the supplied domain — `Onchain.Typed.Domain.domain_type/1`.
  """

  alias Bourse.Signing.Crypto
  alias Onchain.Typed
  alias Onchain.Typed.Domain
  alias Onchain.Typed.Type

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
    onchain_types = to_onchain_types(types)
    fields = Map.fetch!(types, primary_type)
    onchain_message = to_onchain_message(fields, message)
    Typed.hash_struct(primary_type, onchain_message, onchain_types)
  end

  defp to_onchain_types(types) do
    Map.new(types, fn {name, fields} ->
      {name, %Type{fields: Enum.map(fields, &to_onchain_field/1)}}
    end)
  end

  defp to_onchain_field(%{"name" => name, "type" => type}) do
    {name, parse_atomic_type(type)}
  end

  # Onchain.Typed.Type.deserialize_type/1 parses every int/uint/bytes width; a
  # custom (struct) type comes back as its name and an unknown one raises.
  defp parse_atomic_type(type) when is_binary(type) do
    case Type.deserialize_type(type) do
      parsed when is_atom(parsed) or is_tuple(parsed) -> parsed
      _custom -> raise ArgumentError, "EIP712: unsupported field type #{inspect(type)}"
    end
  rescue
    RuntimeError -> reraise ArgumentError, [message: "EIP712: unsupported field type #{inspect(type)}"], __STACKTRACE__
  end

  defp to_onchain_message(fields, message) do
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
    Crypto.decode_fixed!(value, n, "EIP712: bytes#{n}")
  end

  defp convert_value("address", value), do: Crypto.decode_fixed!(value, 20, "EIP712: address")

  defp convert_value(type, value) when is_integer(value) do
    raise ArgumentError, "EIP712: unsupported field type #{inspect(type)}"
  end

  defp convert_value(type, value) do
    raise ArgumentError, "EIP712: unsupported field #{inspect(type)} for #{inspect(value)}"
  end
end
