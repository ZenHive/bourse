defmodule Bourse.Signing.Derive.PreparedOrder do
  @moduledoc "Keyless Derive v2 order preparation for customer-local EIP-712 authorization."

  alias ABI.FunctionSelector
  alias ABI.TypeEncoder
  alias Bourse.Signing.Crypto
  alias Bourse.Signing.Derive

  @action_typehash "4d7a9f27c403ff9c0f19bce61d76d82f9aa29f8d6d4b0c5474607d9770d1af17"
  @action_fields [
    {"subaccountId", "uint256"},
    {"nonce", "uint256"},
    {"module", "address"},
    {"data", "bytes"},
    {"expiry", "uint256"},
    {"owner", "address"},
    {"signer", "address"}
  ]
  @domain_fields [{"name", "string"}, {"version", "string"}, {"chainId", "uint256"}, {"verifyingContract", "address"}]
  @deployments %{
    mainnet: {957, "0xeB8d770ec18DB98Db922E9D83260A585b9F0DeAD", "0xB8D20c2B7a1Ad2EE33Bc50eF10876eD3035b5e7b"},
    testnet: {901, "0x3cc154e220c2197c5337b7Bd13363DD127Bc0C6E", "0x87F2863866D85E3192a35A73b388BD625D83f2be"}
  }

  @doc "Builds typed data and wire terms without keys, signatures, clocks, nonces, or network side effects."
  @spec prepare(map(), :mainnet | :testnet) :: {:ok, map()} | {:error, :invalid_order}
  def prepare(params, environment) when is_map(params) do
    with {chain, matching, trade} <- @deployments[environment],
         {:ok, subaccount} <- uint(params["subaccount_id"]),
         {:ok, nonce} <- uint(params["nonce"]),
         {:ok, expiry} <- uint(params["signature_expiry_sec"]),
         {:ok, sub_id} <- uint(params["base_asset_sub_id"]),
         {:ok, asset} <- address(params["base_asset_address"]),
         {:ok, owner} <- address(params["owner"]),
         {:ok, signer} <- address(params["signer"]),
         {:ok, amount} <- units(params["amount"], false),
         {:ok, price} <- units(params["limit_price"], false),
         {:ok, fee} <- units(params["max_fee"], true),
         side when side in ["buy", "sell"] <- params["direction"],
         instrument when is_binary(instrument) and byte_size(instrument) > 0 <- params["instrument_name"] do
      data =
        encode(
          [asset, sub_id, price, amount, fee, subaccount, side == "buy"],
          ~w(address uint256 int256 int256 uint256 uint256 bool)
        )

      order = [@action_typehash, subaccount, nonce, trade, Crypto.keccak256(data), expiry, owner, signer]

      domain = %{
        "name" => "Matching",
        "version" => "1.0",
        "chainId" => chain,
        "verifyingContract" => trade_address(matching)
      }

      message = %{
        "subaccountId" => to_string(subaccount),
        "nonce" => to_string(nonce),
        "module" => trade_address(trade),
        "data" => hex(data),
        "expiry" => to_string(expiry),
        "owner" => hex(owner),
        "signer" => hex(signer)
      }

      body = %{
        "instrument_name" => instrument,
        "direction" => side,
        "order_type" => "limit",
        "time_in_force" => "gtc",
        "subaccount_id" => subaccount,
        "nonce" => nonce,
        "signature_expiry_sec" => expiry,
        "signer" => hex(signer),
        "amount" => decimal(amount),
        "limit_price" => decimal(price),
        "max_fee" => decimal(fee)
      }

      {:ok,
       %{
         typed_data: %{
           "domain" => domain,
           "types" => %{"EIP712Domain" => fields(@domain_fields), "Action" => fields(@action_fields)},
           "primaryType" => "Action",
           "message" => message
         },
         body: body,
         digest: hex(Derive.hash_order_message(order, testnet: environment == :testnet))
       }}
    else
      _ -> {:error, :invalid_order}
    end
  end

  def prepare(_, _), do: {:error, :invalid_order}

  defp fields(fields), do: Enum.map(fields, fn {name, type} -> %{"name" => name, "type" => type} end)
  defp trade_address(value), do: String.downcase(value)
  defp hex(value), do: "0x" <> Base.encode16(value, case: :lower)

  defp decimal(value),
    do: value |> Decimal.new() |> Decimal.div(Decimal.new("1e18")) |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp encode(values, types),
    do: TypeEncoder.encode_raw(values, Enum.map(types, &%{type: FunctionSelector.decode_type(&1)}))

  defp uint(value) when is_integer(value) and value >= 0 and value < :erlang.bsl(1, 256), do: {:ok, value}

  defp uint(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> uint(number)
      _ -> :error
    end
  end

  defp uint(_), do: :error

  defp address("0x" <> value) when byte_size(value) == 40 do
    Base.decode16(value, case: :mixed)
  end

  defp address(_), do: :error

  defp units(value, zero?) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{coef: coef} = number, ""} when is_integer(coef) -> scaled(number, zero?)
      _ -> :error
    end
  end

  defp units(_, _), do: :error

  defp scaled(number, zero?) do
    scaled = Decimal.mult(number, Decimal.new("1e18"))
    valid_sign = Decimal.positive?(number) or (zero? and Decimal.equal?(number, 0))

    if valid_sign and Decimal.integer?(scaled) and Decimal.compare(scaled, Decimal.new(:erlang.bsl(1, 255))) == :lt,
      do: {:ok, Decimal.to_integer(scaled)},
      else: :error
  end
end
