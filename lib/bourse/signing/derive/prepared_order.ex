defmodule Bourse.Signing.Derive.PreparedOrder do
  @moduledoc """
  Keyless Derive v2 order preparation for customer-local EIP-712 authorization.

  `prepare/2` is pure: it takes no keys, reads no clock, allocates no nonce and
  performs no network call. It answers what a customer's own wallet needs to
  authorize one order — the EIP-712 typed data to display, the exact wire terms
  that must accompany the signature, and the 32-byte digest those two agree on —
  so the private key never has to reach this library.

  ## What is pinned here, and by what

  The `Action` typehash is *derived* from `@action_fields` at compile time
  rather than transcribed, so the struct a wallet displays and the struct that
  goes into the digest cannot drift apart. The test module pins that derived
  value against the constant the provider publishes, so editing the field list
  fails loudly instead of quietly changing what customers sign.

  `@deployments` carries the chain id and the Matching and Trade module
  addresses for both environments, read from `derivexyz/v2-matching`. The chain
  ids and Matching addresses are corroborated inside this repo: hashed as an
  EIP-712 domain they reproduce `Bourse.Signing.Derive`'s independently pinned
  `@domain_separator_prod` / `@domain_separator_sandbox`, and the test asserts
  exactly that. **The Trade module addresses have no such independent check** —
  they enter the digest as the `module` field, and the only thing grading them
  is a vector from the same provider SDK that supplied them, so a wrong address
  would be baked into the oracle too. That gap and the absent end-to-end
  submission proof are recorded in `docs/prod-verification-ledger.md`: this
  module prepares a signature, it does not establish that the venue accepts one.

  ## Scope

  GTC limit orders. `order_type` and `time_in_force` are refused rather than
  silently rewritten when they name anything else — neither field enters the
  signed blob, so a substitution here would leave a valid digest attached to
  terms the caller never asked for.

  The environment is a positional argument rather than a `sandbox:` option on
  purpose: an option carries a default, and the default chain for a signing
  boundary is the one that moves real money. Naming it at every call site is
  worth the small inconsistency with the rest of the library.
  """

  alias Bourse.Signing.Crypto
  alias Bourse.Signing.Derive

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

  # Derived, never transcribed: the digest and the displayed struct read one list.
  @action_type "Action(" <> Enum.map_join(@action_fields, ",", fn {name, type} -> type <> " " <> name end) <> ")"
  @action_typehash Crypto.keccak256(@action_type)

  @deployments %{
    mainnet: {957, "0xeB8d770ec18DB98Db922E9D83260A585b9F0DeAD", "0xB8D20c2B7a1Ad2EE33Bc50eF10876eD3035b5e7b"},
    testnet: {901, "0x3cc154e220c2197c5337b7Bd13363DD127Bc0C6E", "0x87F2863866D85E3192a35A73b388BD625D83f2be"}
  }

  @order_type "limit"
  @time_in_force "gtc"

  @typedoc "Everything a customer needs to authorize one order locally, and nothing that could sign it."
  @type prepared :: %{
          typed_data: %{required(String.t()) => term()},
          body: %{required(String.t()) => term()},
          digest: String.t()
        }

  @typedoc "Which field was refused, or which unsupported value was named."
  @type reason ::
          {:invalid_field, String.t()}
          | {:unsupported, String.t(), term()}
          | {:unknown_environment, term()}
          | :invalid_params

  @doc """
  Builds typed data and wire terms without keys, signatures, clocks, nonces, or network side effects.

  A refusal names the field it refused: a customer whose `max_fee` was rejected
  has to be able to tell that from a malformed `owner`, which one shared error
  atom cannot express.

  ## Examples

      iex> Bourse.Signing.Derive.PreparedOrder.prepare(%{}, :mainnet)
      {:error, {:invalid_field, "subaccount_id"}}

      iex> Bourse.Signing.Derive.PreparedOrder.prepare(%{}, :devnet)
      {:error, {:unknown_environment, :devnet}}
  """
  @spec prepare(map(), :mainnet | :testnet) :: {:ok, prepared()} | {:error, reason()}
  def prepare(params, environment) when is_map(params) do
    with {:ok, {chain, matching, trade}} <- deployment(environment),
         {:ok, subaccount} <- uint(params, "subaccount_id"),
         {:ok, nonce} <- uint(params, "nonce"),
         {:ok, expiry} <- uint(params, "signature_expiry_sec"),
         {:ok, sub_id} <- uint(params, "base_asset_sub_id"),
         {:ok, asset} <- address(params, "base_asset_address"),
         {:ok, owner} <- address(params, "owner"),
         {:ok, signer} <- address(params, "signer"),
         {:ok, amount} <- units(params, "amount", false),
         {:ok, price} <- units(params, "limit_price", false),
         {:ok, fee} <- units(params, "max_fee", true),
         {:ok, side} <- side(params),
         {:ok, instrument} <- instrument(params),
         :ok <- fixed(params, "order_type", @order_type),
         :ok <- fixed(params, "time_in_force", @time_in_force) do
      data = Derive.trade_module_data(asset, sub_id, price, amount, fee, subaccount, side == "buy")
      order = [@action_typehash, subaccount, nonce, trade, Crypto.keccak256(data), expiry, owner, signer]

      {:ok,
       %{
         typed_data: typed_data(chain, matching, trade, {subaccount, nonce, data, expiry, owner, signer}),
         body: body(instrument, side, {subaccount, nonce, expiry, signer, amount, price, fee}),
         digest: hex(Derive.hash_order_message(order, testnet: environment == :testnet))
       }}
    end
  end

  def prepare(_params, _environment), do: {:error, :invalid_params}

  @doc "The EIP-712 `Action` type string the typehash is derived from."
  @spec action_type() :: String.t()
  def action_type, do: @action_type

  defp typed_data(chain, matching, trade, {subaccount, nonce, data, expiry, owner, signer}) do
    %{
      "domain" => %{
        "name" => "Matching",
        "version" => "1.0",
        "chainId" => chain,
        "verifyingContract" => address_string(matching)
      },
      "types" => %{"EIP712Domain" => fields(@domain_fields), "Action" => fields(@action_fields)},
      "primaryType" => "Action",
      "message" => %{
        "subaccountId" => to_string(subaccount),
        "nonce" => to_string(nonce),
        "module" => address_string(trade),
        "data" => hex(data),
        "expiry" => to_string(expiry),
        "owner" => hex(owner),
        "signer" => hex(signer)
      }
    }
  end

  defp body(instrument, side, {subaccount, nonce, expiry, signer, amount, price, fee}) do
    %{
      "instrument_name" => instrument,
      "direction" => side,
      "order_type" => @order_type,
      "time_in_force" => @time_in_force,
      "subaccount_id" => subaccount,
      "nonce" => nonce,
      "signature_expiry_sec" => expiry,
      "signer" => hex(signer),
      "amount" => decimal(amount),
      "limit_price" => decimal(price),
      "max_fee" => decimal(fee)
    }
  end

  defp deployment(environment) do
    case @deployments[environment] do
      nil -> {:error, {:unknown_environment, environment}}
      deployment -> {:ok, deployment}
    end
  end

  defp fields(fields), do: Enum.map(fields, fn {name, type} -> %{"name" => name, "type" => type} end)
  defp address_string(value), do: String.downcase(value)
  defp hex(value), do: "0x" <> Base.encode16(value, case: :lower)

  # Exact by construction: the scaled integer becomes a coefficient carrying a
  # -18 exponent rather than going through a division, so the wire term and the
  # signed word stay the same number at every magnitude the tuple admits.
  defp decimal(value), do: 1 |> Decimal.new(value, -18) |> Decimal.normalize() |> Decimal.to_string(:normal)

  # An absent field takes the only supported value; a named one must be it.
  # Neither reaches the signed blob, so a silent rewrite here would leave a
  # valid digest attached to terms the caller never asked for.
  defp fixed(params, key, supported) do
    case Map.get(params, key, supported) do
      ^supported -> :ok
      other -> {:error, {:unsupported, key, other}}
    end
  end

  defp side(params) do
    case params["direction"] do
      side when side in ["buy", "sell"] -> {:ok, side}
      _other -> {:error, {:invalid_field, "direction"}}
    end
  end

  defp instrument(params) do
    case params["instrument_name"] do
      name when is_binary(name) and byte_size(name) > 0 -> {:ok, name}
      _other -> {:error, {:invalid_field, "instrument_name"}}
    end
  end

  defp uint(params, key), do: params |> Map.get(key) |> parse_uint() |> tag(key)

  defp parse_uint(value) when is_integer(value) and value >= 0 and value < :erlang.bsl(1, 256), do: {:ok, value}

  defp parse_uint(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> parse_uint(number)
      _other -> :error
    end
  end

  defp parse_uint(_value), do: :error

  defp address(params, key), do: params |> Map.get(key) |> parse_address() |> tag(key)

  defp parse_address("0x" <> value) when byte_size(value) == 40, do: Base.decode16(value, case: :mixed)
  defp parse_address(_value), do: :error

  defp units(params, key, zero?), do: params |> Map.get(key) |> parse_units(zero?) |> tag(key)

  defp parse_units(value, zero?) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{coef: coef} = number, ""} when is_integer(coef) -> scaled(number, zero?)
      _other -> :error
    end
  end

  defp parse_units(_value, _zero?), do: :error

  defp scaled(number, zero?) do
    scaled = Decimal.mult(number, Decimal.new("1e18"))
    valid_sign = Decimal.positive?(number) or (zero? and Decimal.equal?(number, 0))

    if valid_sign and Decimal.integer?(scaled) and Decimal.compare(scaled, Decimal.new(:erlang.bsl(1, 255))) == :lt,
      do: {:ok, Decimal.to_integer(scaled)},
      else: :error
  end

  defp tag({:ok, value}, _key), do: {:ok, value}
  defp tag(:error, key), do: {:error, {:invalid_field, key}}
end
