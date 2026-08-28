defmodule Bourse.Unified.RequestShape.Derive do
  @moduledoc false
  # Derive request mechanics the generic authored-entry machinery cannot express.
  #
  # Private methods require a numeric `subaccount_id` on the wire (venue docs:
  # https://docs.derive.xyz/reference/post_private-get-positions). Resolve it
  # from per-call params or
  # `exchange.options["subaccount_id"]` (not `deriveWalletAddress`, which is the
  # smart-contract wallet for X-LyraWallet headers). Mirror that ergonomics here:
  # inject the construction-time option with put_new so an explicit per-call param
  # still wins, and leave the generic identifier_reference raise when neither is set.

  alias Bourse.Exchange
  alias Bourse.Market
  alias Bourse.Signing.Derive, as: DeriveSigning
  alias Bourse.Unified.RequestShape

  @action_typehash "4d7a9f27c403ff9c0f19bce61d76d82f9aa29f8d6d4b0c5474607d9770d1af17"
  @sandbox_trade_module "0x87F2863866D85E3192a35A73b388BD625D83f2be"
  @production_trade_module "0xB8D20c2B7a1Ad2EE33Bc50eF10876eD3035b5e7b"
  @signature_validity_seconds 7_776_000

  @doc "Builds a Derive request shape without a clock override."
  @spec build(map(), String.t(), Exchange.t()) :: map()
  def build(params, js_name, %Exchange{} = exchange), do: build(params, js_name, exchange, [])

  @doc "Builds a Derive request shape, optionally with a deterministic clock."
  @spec build(map(), String.t(), Exchange.t(), keyword()) :: map()
  def build(params, "createOrder", %Exchange{} = exchange, opts) when is_map(params) and is_list(opts) do
    params
    |> maybe_put_subaccount_id("createOrder", exchange)
    |> put_label()
    |> build_create_order(exchange, opts)
  end

  # Derive edit is create-plus-order_id_to_cancel (POST /private/replace). Reuse the
  # signed order envelope rather than a second signer; see docs.derive.xyz replace.
  def build(params, "editOrder", %Exchange{} = exchange, opts) when is_map(params) and is_list(opts) do
    order_id = Map.fetch!(params, "id")

    params
    |> maybe_put_subaccount_id("editOrder", exchange)
    |> put_label()
    |> build_create_order(exchange, opts)
    |> Map.put("order_id_to_cancel", order_id)
  end

  def build(params, "cancelOrder", %Exchange{} = exchange, _opts) when is_map(params) do
    params = maybe_put_subaccount_id(params, "cancelOrder", exchange)
    market = find_market!(exchange, Map.fetch!(params, "instrument_name"))
    %{params | "instrument_name" => market_field(market, :id)}
  end

  def build(params, js_name, %Exchange{} = exchange, _opts) when is_map(params) and is_binary(js_name),
    do: maybe_put_subaccount_id(params, js_name, exchange)

  # Shared signed order envelope for createOrder and editOrder (edit = create +
  # order_id_to_cancel). Kept private so the wire shape stays an internal detail
  # of build/4 rather than a second public API surface.
  defp build_create_order(params, exchange, opts) do
    requested = Map.fetch!(params, "instrument_name")
    market = find_market!(exchange, requested)
    info = market_info!(market, requested)
    nonce = Keyword.get(opts, :timestamp_ms_override, System.system_time(:millisecond))
    expiry = signature_expiry(params, nonce)
    amount = number_string(Map.fetch!(params, "amount"))
    price = number_string(Map.fetch!(params, "price"))
    max_fee = number_string(Map.fetch!(params, "max_fee"))
    side = buy_or_sell!(Map.fetch!(params, "side"))
    # Derive wants a numeric subaccount_id, and the wire value must be the one that
    # was signed — coerce once and reuse for both the trade hash and the body.
    subaccount_id = integer!(Map.fetch!(params, "subaccount_id"))
    signer = DeriveSigning.signer_address(exchange.credentials.secret)
    wallet = exchange.credentials.api_key

    trade_hash =
      DeriveSigning.trade_module_data_hash(
        Map.fetch!(info, "base_asset_address"),
        integer!(Map.fetch!(info, "base_asset_sub_id")),
        price,
        amount,
        max_fee,
        subaccount_id,
        side == "buy"
      )

    order = [
      @action_typehash,
      subaccount_id,
      nonce,
      if(exchange.sandbox, do: @sandbox_trade_module, else: @production_trade_module),
      trade_hash,
      expiry,
      wallet,
      signer
    ]

    %{
      "instrument_name" => market_field(market, :id),
      "direction" => side,
      "order_type" => params |> Map.fetch!("type") |> String.downcase(),
      "nonce" => nonce,
      "amount" => amount,
      "limit_price" => price,
      "max_fee" => max_fee,
      "subaccount_id" => subaccount_id,
      "signature_expiry_sec" => expiry,
      "referral_code" => Map.get(exchange.options, "id", "0x0ad42b8e602c2d3d475ae52d678cf63d84ab2749"),
      "signer" => signer,
      "signature" => DeriveSigning.sign_order(order, private_key: exchange.credentials.secret, testnet: exchange.sandbox)
    }
    |> copy_optional(params, "reduce_only")
    |> copy_optional(params, "time_in_force")
    |> copy_optional(params, "label")
  end

  defp find_market!(%Exchange{markets: markets}, symbol) when is_list(markets) do
    Enum.find_value(markets, &matching_market(&1, symbol)) ||
      raise ArgumentError, "Derive order build requires a loaded market for #{symbol}"
  end

  defp find_market!(_exchange, symbol),
    do: raise(ArgumentError, "Derive order build requires loaded markets for #{symbol}")

  # `Exchange.markets` is documented as `%Bourse.Market{}` structs; no surviving
  # producer builds raw string-keyed market maps (that path was the deleted
  # offline replay cache). The plain-map branch below is defensive only.
  defp matching_market(market, symbol) when is_map(market) do
    id = market_field(market, :id)

    cond do
      id == symbol -> market
      market_field(market, :symbol) == symbol -> market
      true -> nil
    end
  end

  defp matching_market(_market, _symbol), do: nil

  # The trade-module hash is built from the instrument's on-chain asset identity,
  # so an info-less market cannot produce a signable order — name that precondition
  # rather than signing a hash over missing fields.
  defp market_info!(market, symbol) do
    case market_field(market, :info) do
      info when is_map(info) ->
        info

      _ ->
        raise ArgumentError,
              "Derive order build needs the venue `info` (base_asset_address/base_asset_sub_id) " <>
                "for #{symbol} to build the trade-module hash; the loaded market carries none. " <>
                "Reload markets with Bourse.load_markets/1."
    end
  end

  defp market_field(%Market{} = market, field), do: Map.get(market, field)

  defp market_field(market, field) when is_map(market), do: Map.get(market, field, Map.get(market, Atom.to_string(field)))

  defp copy_optional(request, params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(request, key, value)
      :error -> request
    end
  end

  # Bourse unified clientOrderId maps to Derive's `label` on both order and replace.
  # Explicit `label` wins when both are set; the unified key never reaches the wire.
  defp put_label(params) do
    client_order_id? = Map.has_key?(params, "clientOrderId")
    client_order_id = Map.get(params, "clientOrderId")
    params = Map.delete(params, "clientOrderId")

    if client_order_id?, do: Map.put_new(params, "label", client_order_id), else: params
  end

  defp number_string(value) when is_binary(value), do: value
  defp number_string(value) when is_integer(value), do: Integer.to_string(value)
  defp number_string(value) when is_float(value), do: Float.to_string(value)
  defp integer!(value) when is_integer(value), do: value
  defp integer!(value) when is_binary(value), do: String.to_integer(value)

  defp buy_or_sell!(side) when is_binary(side) do
    case String.downcase(side) do
      normalized when normalized in ["buy", "sell"] -> normalized
      _ -> RequestShape.refuse_uninterpretable_side!(side)
    end
  end

  defp buy_or_sell!(side), do: RequestShape.refuse_uninterpretable_side!(side)

  defp signature_expiry(%{"signature_expiry_sec" => value}, _nonce) when is_integer(value), do: value

  defp signature_expiry(%{"signature_expiry_sec" => value}, nonce) when is_binary(value) do
    case Integer.parse(value) do
      {expiry, ""} -> expiry
      _ -> div(nonce, 1_000) + @signature_validity_seconds
    end
  end

  defp signature_expiry(_params, nonce), do: div(nonce, 1_000) + @signature_validity_seconds

  defp maybe_put_subaccount_id(params, js_name, %Exchange{request_param_shape: shape} = exchange) when is_map(shape) do
    case Map.get(shape, js_name) do
      %{"subaccount_id" => _} -> put_subaccount_default(params, subaccount_default(exchange))
      _ -> params
    end
  end

  defp maybe_put_subaccount_id(params, _js_name, _exchange), do: params

  # Accept atom-keyed `subaccount_id` for construction convenience
  # (`options: %{subaccount_id: 144422}`).
  defp subaccount_default(%Exchange{options: options}) when is_map(options) do
    case Map.get(options, "subaccount_id", Map.get(options, :subaccount_id)) do
      id when is_integer(id) and id > 0 -> id
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp subaccount_default(_exchange), do: nil

  # An explicit per-call `subaccount_id` wins, but only when it is actually usable
  # on the wire; a blank/zero/garbage value falls back to the construction default.
  defp put_subaccount_default(params, nil), do: params

  defp put_subaccount_default(params, id) do
    if usable_subaccount_id?(Map.get(params, "subaccount_id")),
      do: params,
      else: Map.put(params, "subaccount_id", id)
  end

  defp usable_subaccount_id?(current) when is_integer(current), do: current > 0
  defp usable_subaccount_id?(current) when is_binary(current), do: match?({id, ""} when id > 0, Integer.parse(current))
  defp usable_subaccount_id?(_current), do: false
end
