defmodule Bourse.Signing.Hyperliquid do
  @moduledoc """
  First-party signing for Hyperliquid.

  Hyperliquid signs two kinds of payloads, both EIP-712 typed data sealed with a
  secp256k1 signature (`%{r, s, v}` with `v = 27 + recovery_id`):

  - **L1 actions** (`sign_l1_action/2`) — order / cancel / transfer actions.
    The action is MessagePack-serialised (`packb`), concatenated with the nonce,
    optional vault address and optional `expiresAfter`, hashed with Keccak-256
    into a `connectionId`, wrapped in an `Agent` phantom struct and signed under
    the `Exchange` domain (`chainId: 1337`).
  - **User-signed actions** (`sign_user_signed_action/3`) — USD transfers,
    withdrawals, approvals. Plain EIP-712 typed data under the
    `HyperliquidSignTransaction` domain (`chainId: 421614`), no msgpack.

  ## Credentials

  Hyperliquid authenticates with an EVM wallet, not an API key/secret pair. The
  EVM private key is carried in `credentials.secret`; the wallet address (when
  needed for vault threading) in `credentials.api_key`.

  ## L1 action packing

  `pack_l1_action!/1` writes the field order from Hyperliquid's exchange docs
  and official Python SDK. The supported L1 actions cover orders, cancellations,
  isolated-margin updates, TWAPs, sub-account transfers, and vault transfers.
  Unknown shapes raise instead of falling back to unordered map serialization.
  """

  @behaviour Bourse.Signing.Behaviour

  alias Bourse.Credentials
  alias Bourse.Signing
  alias Bourse.Signing.Crypto
  alias Bourse.Signing.EIP712

  @l1_domain %{
    "chainId" => 1337,
    "name" => "Exchange",
    "verifyingContract" => "0x0000000000000000000000000000000000000000",
    "version" => "1"
  }

  @user_domain_name "HyperliquidSignTransaction"
  @user_chain_id 421_614
  @zero_address "0x0000000000000000000000000000000000000000"

  @agent_types %{
    "Agent" => [
      %{"name" => "source", "type" => "string"},
      %{"name" => "connectionId", "type" => "bytes32"}
    ]
  }

  @doc """
  Computes the 32-byte Keccak-256 action hash (the EIP-712 `connectionId`).

  Computes `keccak256(packb(action) ‖ nonce ‖ vault ‖ expiresAfter)` as defined
  by Hyperliquid's signing contract.
  `vault_address` and `expires_after` are optional (`nil` to omit).
  """
  @spec action_hash(map(), String.t() | nil, non_neg_integer(), non_neg_integer() | nil) ::
          binary()
  def action_hash(action, vault_address, nonce, expires_after \\ nil) do
    data_hex =
      action
      |> pack_l1_action!()
      |> Crypto.encode_hex()

    data =
      data_hex
      |> Kernel.<>("00000" <> int_to_base16(nonce))
      |> append_vault(vault_address)
      |> append_expires(expires_after)

    Crypto.keccak256(Base.decode16!(data, case: :lower))
  end

  @doc false
  @spec pack_l1_action!(map()) :: binary()
  def pack_l1_action!(action) when is_map(action) do
    action
    |> pack_l1_action_iodata!()
    |> IO.iodata_to_binary()
  end

  @doc """
  Signs an L1 action, returning `%{r, s, v}` byte-equal to Bourse `signL1Action`.

  Options:
  - `:private_key` (required) — `0x`-prefixed EVM private key hex
  - `:vault_address` — vault / sub-account address (omitted when `nil`)
  - `:expires_after` — action expiry, ms (omitted when `nil`)
  - `:testnet` — `true` flips the phantom-agent `source` to `"b"` (default `false`)
  """
  @spec sign_l1_action(map(), non_neg_integer(), keyword()) :: Crypto.signature()
  def sign_l1_action(action, nonce, opts) do
    private_key = fetch_private_key(opts)
    vault_address = opts |> Keyword.get(:vault_address) |> normalize_vault()
    expires_after = Keyword.get(opts, :expires_after)
    testnet = Keyword.get(opts, :testnet, false)

    hash = action_hash(action, vault_address, nonce, expires_after)
    phantom = %{"source" => phantom_source(testnet), "connectionId" => hash}

    @l1_domain
    |> EIP712.encode(@agent_types, "Agent", phantom)
    |> Crypto.keccak256()
    |> Crypto.sign_hash(private_key)
  end

  @doc """
  Signs a user-signed action under the `HyperliquidSignTransaction` domain.

  `message_types` is the EIP-712 type map (e.g.
  `%{"HyperliquidTransaction:UsdSend" => [...]}`); `message` carries the typed
  values. Returns `%{r, s, v}` byte-equal to Bourse `signUserSignedAction`.

  Options: `:private_key` (required).
  """
  @spec sign_user_signed_action(map(), map(), keyword()) :: Crypto.signature()
  def sign_user_signed_action(message_types, message, opts) do
    private_key = fetch_private_key(opts)
    [primary_type] = Map.keys(message_types)

    user_domain()
    |> EIP712.encode(message_types, primary_type, message)
    |> Crypto.keccak256()
    |> Crypto.sign_hash(private_key)
  end

  # User-signed action types (EIP-712 HyperliquidSignTransaction domain).
  # Authority: Hyperliquid Python SDK `sign_user_signed_action` +
  # https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/exchange-endpoint
  @usd_class_transfer_types %{
    "HyperliquidTransaction:UsdClassTransfer" => [
      %{"name" => "hyperliquidChain", "type" => "string"},
      %{"name" => "amount", "type" => "string"},
      %{"name" => "toPerp", "type" => "bool"},
      %{"name" => "nonce", "type" => "uint64"}
    ]
  }

  @withdraw_types %{
    "HyperliquidTransaction:Withdraw" => [
      %{"name" => "hyperliquidChain", "type" => "string"},
      %{"name" => "destination", "type" => "string"},
      %{"name" => "amount", "type" => "string"},
      %{"name" => "time", "type" => "uint64"}
    ]
  }

  @doc """
  `Bourse.Signing.Behaviour` entry point.

  Expects the L1 or user-signed `action` and `nonce` in `request.params`
  (`:action`/`:nonce`, with optional `:vault_address`/`:expires_after`). Produces
  the Hyperliquid `POST /exchange` envelope —
  `%{"action", "nonce", "signature"}` (+ `vaultAddress`) — as the JSON request body.

  Unified callers receive a fully built `:action` from the internal Hyperliquid
  request-shape layer; raw callers may still hand-feed `:action` as an override.
  """
  @impl true
  @spec sign(Signing.request(), Credentials.t(), Signing.config()) :: Signing.signed_request()
  def sign(request, credentials, config) do
    params = request.params || %{}
    action = fetch!(params, :action)
    nonce = fetch!(params, :nonce)
    vault_address = param(params, :vault_address) || param(params, :vaultAddress)
    expires_after = param(params, :expires_after)
    testnet = Map.get(config, :testnet, credentials.sandbox)

    signature =
      case action_type!(action) do
        "usdClassTransfer" ->
          sign_usd_class_transfer(action, private_key: credentials.secret)

        "withdraw3" ->
          sign_withdraw(action, private_key: credentials.secret)

        _l1 ->
          sign_l1_action(action, nonce,
            private_key: credentials.secret,
            vault_address: vault_address,
            expires_after: expires_after,
            testnet: testnet
          )
      end

    envelope =
      maybe_put(
        %{"action" => action, "nonce" => nonce, "signature" => wire_signature(signature)},
        "vaultAddress",
        normalize_vault(vault_address)
      )

    %Bourse.Signing.SignedRequest{
      url: request.path,
      method: request.method,
      headers: [{"Content-Type", "application/json"}],
      body: Jason.encode!(envelope)
    }
  end

  defp sign_usd_class_transfer(action, opts) do
    message = %{
      "hyperliquidChain" => Map.fetch!(action, "hyperliquidChain"),
      "amount" => Map.fetch!(action, "amount"),
      "toPerp" => Map.fetch!(action, "toPerp"),
      "nonce" => Map.fetch!(action, "nonce")
    }

    sign_user_signed_action(@usd_class_transfer_types, message, opts)
  end

  defp sign_withdraw(action, opts) do
    message = Map.take(action, ["hyperliquidChain", "destination", "amount", "time"])
    sign_user_signed_action(@withdraw_types, message, opts)
  end

  defp action_type!(action) do
    case fetch_field(action, "type") do
      type when is_binary(type) -> type
      _ -> raise ArgumentError, "Hyperliquid action requires a string type"
    end
  end

  defp pack_l1_action_iodata!(action) do
    case action_type!(action) do
      "order" -> pack_order_action(action)
      "cancel" -> pack_cancel_action(action)
      "updateIsolatedMargin" -> pack_isolated_margin_action(action)
      "twapOrder" -> pack_twap_order_action(action)
      "scheduleCancel" -> pack_schedule_cancel_action(action)
      "subAccountTransfer" -> pack_sub_account_transfer_action(action)
      "vaultTransfer" -> pack_vault_transfer_action(action)
      type -> raise ArgumentError, "unsupported Hyperliquid L1 action type: #{inspect(type)}"
    end
  end

  # Hyperliquid's wire signature uses 0x-prefixed r/s (SDK + static fixtures);
  # `v` is a recovery int and travels unprefixed.
  defp wire_signature(signature) do
    Map.new(signature, fn
      {:v, v} -> {"v", v}
      {component, hex} -> {Atom.to_string(component), prefix_0x(hex)}
    end)
  end

  defp prefix_0x(hex) when is_binary(hex), do: "0x" <> hex

  # Field orders below are authored from Hyperliquid's exchange endpoint docs
  # and `hyperliquid-python-sdk`'s Exchange.order/bulk_cancel/sub_account_transfer.
  defp pack_order_action(action) do
    fields = [
      {"type", pack_scalar(fetch_field!(action, "type"))},
      {"orders", pack_list(fetch_field!(action, "orders"), &pack_order_row/1)},
      {"grouping", pack_scalar(fetch_field!(action, "grouping"))}
    ]

    optional = optional_field(action, "builder", &pack_builder/1)
    assert_known_fields!(action, ["type", "orders", "grouping", "builder"])
    pack_map(fields ++ optional)
  end

  defp pack_schedule_cancel_action(action) do
    fields = [
      {"type", pack_scalar(fetch_field!(action, "type"))},
      {"time", pack_scalar(fetch_field!(action, "time"))}
    ]

    assert_known_fields!(action, ["type", "time"])
    pack_map(fields)
  end

  defp pack_cancel_action(action) do
    assert_known_fields!(action, ["type", "cancels"])

    pack_map([
      {"type", pack_scalar(fetch_field!(action, "type"))},
      {"cancels", pack_list(fetch_field!(action, "cancels"), &pack_cancel_row/1)}
    ])
  end

  defp pack_sub_account_transfer_action(action) do
    assert_known_fields!(action, ["type", "subAccountUser", "isDeposit", "usd"])

    pack_map([
      {"type", pack_scalar(fetch_field!(action, "type"))},
      {"subAccountUser", pack_scalar(fetch_field!(action, "subAccountUser"))},
      {"isDeposit", pack_scalar(fetch_field!(action, "isDeposit"))},
      {"usd", pack_scalar(fetch_field!(action, "usd"))}
    ])
  end

  # Docs + Python SDK `vault_usd_transfer`: type, vaultAddress, isDeposit, usd.
  defp pack_vault_transfer_action(action) do
    assert_known_fields!(action, ["type", "vaultAddress", "isDeposit", "usd"])

    pack_map([
      {"type", pack_scalar(fetch_field!(action, "type"))},
      {"vaultAddress", pack_scalar(fetch_field!(action, "vaultAddress"))},
      {"isDeposit", pack_scalar(fetch_field!(action, "isDeposit"))},
      {"usd", pack_scalar(fetch_field!(action, "usd"))}
    ])
  end

  defp pack_isolated_margin_action(action) do
    assert_known_fields!(action, ["type", "asset", "isBuy", "ntli"])

    pack_map([
      {"type", pack_scalar(fetch_field!(action, "type"))},
      {"asset", pack_scalar(fetch_field!(action, "asset"))},
      {"isBuy", pack_scalar(fetch_field!(action, "isBuy"))},
      {"ntli", pack_scalar(fetch_field!(action, "ntli"))}
    ])
  end

  defp pack_twap_order_action(action) do
    assert_known_fields!(action, ["type", "twap"])

    pack_map([
      {"type", pack_scalar(fetch_field!(action, "type"))},
      {"twap", pack_twap_row(fetch_field!(action, "twap"))}
    ])
  end

  defp pack_twap_row(row) when is_map(row) do
    assert_known_fields!(row, ["a", "b", "s", "r", "m", "t"])

    pack_map([
      {"a", pack_scalar(fetch_field!(row, "a"))},
      {"b", pack_scalar(fetch_field!(row, "b"))},
      {"s", pack_scalar(fetch_field!(row, "s"))},
      {"r", pack_scalar(fetch_field!(row, "r"))},
      {"m", pack_scalar(fetch_field!(row, "m"))},
      {"t", pack_scalar(fetch_field!(row, "t"))}
    ])
  end

  defp pack_twap_row(row), do: raise(ArgumentError, "Hyperliquid TWAP row must be a map, got: #{inspect(row)}")

  defp pack_order_row(row) when is_map(row) do
    fields = [
      {"a", pack_scalar(fetch_field!(row, "a"))},
      {"b", pack_scalar(fetch_field!(row, "b"))},
      {"p", pack_scalar(fetch_field!(row, "p"))},
      {"s", pack_scalar(fetch_field!(row, "s"))},
      {"r", pack_scalar(fetch_field!(row, "r"))},
      {"t", pack_order_type(fetch_field!(row, "t"))}
    ]

    optional = optional_field(row, "c", &pack_scalar/1)
    assert_known_fields!(row, ["a", "b", "p", "s", "r", "t", "c"])
    pack_map(fields ++ optional)
  end

  defp pack_order_row(row), do: raise(ArgumentError, "Hyperliquid order row must be a map, got: #{inspect(row)}")

  defp pack_order_type(%{} = order_type) do
    case {fetch_field(order_type, "limit"), fetch_field(order_type, "trigger")} do
      {%{} = limit, nil} ->
        assert_known_fields!(order_type, ["limit"])
        assert_known_fields!(limit, ["tif"])
        pack_map([{"limit", pack_map([{"tif", pack_scalar(fetch_field!(limit, "tif"))}])}])

      {nil, %{} = trigger} ->
        assert_known_fields!(order_type, ["trigger"])
        assert_known_fields!(trigger, ["isMarket", "triggerPx", "tpsl"])

        pack_map([
          {"trigger",
           pack_map([
             {"isMarket", pack_scalar(fetch_field!(trigger, "isMarket"))},
             {"triggerPx", pack_scalar(fetch_field!(trigger, "triggerPx"))},
             {"tpsl", pack_scalar(fetch_field!(trigger, "tpsl"))}
           ])}
        ])

      _ ->
        raise ArgumentError, "Hyperliquid order type requires exactly one of limit or trigger"
    end
  end

  defp pack_order_type(value), do: raise(ArgumentError, "Hyperliquid order type must be a map, got: #{inspect(value)}")

  defp pack_builder(builder) when is_map(builder) do
    assert_known_fields!(builder, ["b", "f"])
    pack_map([{"b", pack_scalar(fetch_field!(builder, "b"))}, {"f", pack_scalar(fetch_field!(builder, "f"))}])
  end

  defp pack_builder(value), do: raise(ArgumentError, "Hyperliquid builder must be a map, got: #{inspect(value)}")

  defp pack_cancel_row(row) when is_map(row) do
    assert_known_fields!(row, ["a", "o"])
    pack_map([{"a", pack_scalar(fetch_field!(row, "a"))}, {"o", pack_scalar(fetch_field!(row, "o"))}])
  end

  defp pack_cancel_row(row), do: raise(ArgumentError, "Hyperliquid cancel row must be a map, got: #{inspect(row)}")

  defp pack_map(fields),
    do: [map_header(length(fields)), Enum.map(fields, fn {key, value} -> [pack_scalar(key), value] end)]

  defp pack_list(values, pack_value) when is_list(values),
    do: [array_header(length(values)), Enum.map(values, pack_value)]

  defp pack_list(value, _pack_value),
    do: raise(ArgumentError, "Hyperliquid action field must be a list, got: #{inspect(value)}")

  defp pack_scalar(value), do: Msgpax.pack!(value, iodata: false)

  # MessagePack map/array headers. Values are pre-encoded so their maps never
  # pass through Msgpax's map iterator.
  defp map_header(size), do: <<0x80 + size>>

  defp array_header(size) when size < 16, do: <<0x90 + size>>
  defp array_header(size), do: <<0xDC, size::16>>

  defp optional_field(action, key, packer) do
    case fetch_field(action, key) do
      nil -> []
      value -> [{key, packer.(value)}]
    end
  end

  defp fetch_field!(action, key) do
    case fetch_field(action, key) do
      nil -> raise ArgumentError, "Hyperliquid action requires #{key}"
      value -> value
    end
  end

  defp fetch_field(action, key), do: Map.get(action, key)

  defp assert_known_fields!(action, fields) do
    unknown =
      action
      |> Enum.map(fn {key, _value} -> to_string(key) end)
      |> Enum.reject(&(&1 in fields))

    if unknown != [], do: raise(ArgumentError, "unsupported Hyperliquid action fields: #{inspect(unknown)}")
  end

  # --- internals ---

  defp user_domain do
    %{
      "chainId" => @user_chain_id,
      "name" => @user_domain_name,
      "verifyingContract" => @zero_address,
      "version" => "1"
    }
  end

  defp phantom_source(true), do: "b"
  defp phantom_source(false), do: "a"

  defp append_vault(data, nil), do: data <> "00"
  defp append_vault(data, vault_address), do: data <> "01" <> vault_address

  defp append_expires(data, nil), do: data
  defp append_expires(data, expires_after), do: data <> "00" <> "00000" <> int_to_base16(expires_after)

  defp int_to_base16(int) when is_integer(int) and int >= 0 do
    int |> Integer.to_string(16) |> String.downcase()
  end

  # vault address is concatenated as raw hex (no 0x) into the action hash bytes.
  defp normalize_vault(nil), do: nil
  defp normalize_vault(address) when is_binary(address), do: Crypto.strip_0x(address)

  defp fetch_private_key(opts) do
    case Keyword.fetch(opts, :private_key) do
      {:ok, key} when is_binary(key) -> Crypto.decode_private_key(key)
      _ -> raise ArgumentError, "Hyperliquid signing requires a :private_key option"
    end
  end

  defp fetch!(params, key) do
    case fetch_param(params, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "Hyperliquid signing requires #{inspect(key)} in request params"
    end
  end

  defp param(params, key) do
    case fetch_param(params, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp fetch_param(params, key) do
    params
    |> Map.fetch(key)
    |> case do
      :error -> Map.fetch(params, Atom.to_string(key))
      value -> value
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
