defmodule Bourse.Signing.Lighter.Protocol do
  @moduledoc """
  Versioned framed protocol for the isolated Lighter signing helper.

  Frames carry typed values only. The helper never returns native error text,
  so failures cannot reflect key material into the BEAM or logs.
  """

  @version 1
  @success 0
  @failure 1
  @max_u8 0xFF
  @max_i16 0x7FFF
  @max_u16 0xFFFF
  @max_i32 0x7FFFFFFF
  @max_u32 0xFFFFFFFF
  @min_i64 -0x8000000000000000
  @max_i64 0x7FFFFFFFFFFFFFFF

  @operations %{
    init: 1,
    auth_token: 2,
    create_order: 3,
    cancel_order: 4,
    cancel_all_orders: 5,
    modify_order: 6,
    update_leverage: 7,
    update_margin: 8,
    transfer: 9,
    change_pub_key: 10
  }

  @errors %{
    1 => :protocol_error,
    2 => :not_initialized,
    3 => :already_initialized,
    4 => :invalid_argument,
    5 => :client_initialization_failed,
    6 => :signing_failed,
    7 => :response_too_large
  }

  @type operation ::
          :auth_token
          | :create_order
          | :cancel_order
          | :cancel_all_orders
          | :modify_order
          | :update_leverage
          | :update_margin
          | :transfer
          | :change_pub_key
  @type protocol_error ::
          :protocol_error
          | :not_initialized
          | :already_initialized
          | :invalid_argument
          | :client_initialization_failed
          | :signing_failed
          | :response_too_large
  @type signed_transaction :: %{
          tx_type: non_neg_integer(),
          tx_info: String.t(),
          tx_hash: String.t(),
          message_to_sign: String.t()
        }

  @doc "Encodes the one-time helper initialization request."
  @spec encode_init(non_neg_integer(), String.t(), String.t(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, :invalid_argument}
  def encode_init(request_id, url, private_key, chain_id, api_key_index, account_index) do
    with :ok <- valid_uint(request_id, @max_u32),
         :ok <- valid_string(url),
         :ok <- valid_string(private_key),
         :ok <- valid_uint(chain_id, @max_i32),
         :ok <- valid_uint(api_key_index, @max_u8),
         :ok <- valid_int(account_index, 1, @max_i64) do
      {:ok,
       <<@version, @operations.init, request_id::32, byte_size(url)::16, url::binary, byte_size(private_key)::16,
         private_key::binary, chain_id::32, api_key_index, account_index::signed-64>>}
    end
  end

  @doc "Encodes a whitelisted signing operation."
  @spec encode_request(non_neg_integer(), operation(), map()) ::
          {:ok, binary()} | {:error, :invalid_argument}
  def encode_request(request_id, operation, params) when is_map(params) do
    with :ok <- valid_uint(request_id, @max_u32),
         {:ok, payload} <- encode_payload(operation, params) do
      {:ok, <<@version, Map.fetch!(@operations, operation), request_id::32, payload::binary>>}
    end
  end

  @doc "Decodes one response and verifies its operation and request ID."
  @spec decode_response(binary(), :init | operation(), non_neg_integer()) ::
          :ok
          | {:ok, String.t() | signed_transaction()}
          | {:error, protocol_error()}
  def decode_response(response, operation, request_id) when is_map_key(@operations, operation) do
    expected_operation = Map.fetch!(@operations, operation)

    case response do
      <<@version, ^expected_operation, ^request_id::32, @success, 0, payload::binary>> ->
        decode_success(operation, payload)

      <<@version, ^expected_operation, ^request_id::32, @failure, 0, error_code>> ->
        {:error, Map.get(@errors, error_code, :protocol_error)}

      _other ->
        {:error, :protocol_error}
    end
  end

  def decode_response(_response, _operation, _request_id), do: {:error, :protocol_error}

  defp encode_payload(:auth_token, params) do
    with {:ok, deadline} <- integer(params, :deadline),
         :ok <- valid_uint(deadline, @max_i64) do
      {:ok, <<deadline::signed-64>>}
    end
  end

  defp encode_payload(:create_order, params) do
    fields = [
      {:market_index, :u16, @max_i16},
      {:client_order_index, :i64},
      {:base_amount, :i64},
      {:price, :u32, @max_u32},
      {:is_ask, :bool},
      {:order_type, :u8, @max_u8},
      {:time_in_force, :u8, @max_u8},
      {:reduce_only, :bool},
      {:trigger_price, :u32, @max_u32},
      {:order_expiry, :i64},
      {:integrator_account_index, :i64},
      {:integrator_taker_fee, :u32, @max_i32},
      {:integrator_maker_fee, :u32, @max_i32},
      {:self_trade_behavior, :u8, @max_u8},
      {:self_trade_equality, :u8, @max_u8},
      {:skip_nonce, :bool},
      {:nonce, :nonce}
    ]

    encode_fields(params, fields)
  end

  defp encode_payload(:cancel_order, params) do
    encode_fields(params, [
      {:market_index, :u16, @max_i16},
      {:order_index, :i64},
      {:skip_nonce, :bool},
      {:nonce, :nonce}
    ])
  end

  defp encode_payload(:cancel_all_orders, params) do
    encode_fields(params, [
      {:time_in_force, :u8, @max_u8},
      {:time, :i64},
      {:market_index, :u16, @max_i16},
      {:skip_nonce, :bool},
      {:nonce, :nonce}
    ])
  end

  defp encode_payload(:modify_order, params) do
    encode_fields(params, [
      {:market_index, :u16, @max_i16},
      {:index, :i64},
      {:base_amount, :i64},
      {:price, :u32_i64, @max_u32},
      {:trigger_price, :u32_i64, @max_u32},
      {:integrator_account_index, :i64},
      {:integrator_taker_fee, :u32, @max_i32},
      {:integrator_maker_fee, :u32, @max_i32},
      {:self_trade_behavior, :u8, @max_u8},
      {:self_trade_equality, :u8, @max_u8},
      {:skip_nonce, :bool},
      {:nonce, :nonce}
    ])
  end

  defp encode_payload(:update_leverage, params) do
    encode_fields(params, [
      {:market_index, :u16, @max_i16},
      {:initial_margin_fraction, :u32, @max_u16},
      {:margin_mode, :u8, @max_u8},
      {:skip_nonce, :bool},
      {:nonce, :nonce}
    ])
  end

  defp encode_payload(:update_margin, params) do
    encode_fields(params, [
      {:market_index, :u16, @max_i16},
      {:usdc_amount, :i64},
      {:direction, :u8, @max_u8},
      {:skip_nonce, :bool},
      {:nonce, :nonce}
    ])
  end

  defp encode_payload(:transfer, params) do
    with {:ok, encoded} <-
           encode_fields(params, [
             {:to_account_index, :i64},
             {:asset_index, :u16, @max_i16},
             {:from_route, :u8, 1},
             {:to_route, :u8, 1},
             {:amount, :i64},
             {:usdc_fee, :i64}
           ]),
         {:ok, memo} <- memo(params),
         {:ok, nonce_fields} <- encode_fields(params, [{:skip_nonce, :bool}, {:nonce, :nonce}]) do
      {:ok, <<encoded::binary, memo::binary, nonce_fields::binary>>}
    end
  end

  defp encode_payload(:change_pub_key, params) do
    with {:ok, pub_key} <- pub_key(params),
         {:ok, l1_signature} <- l1_signature(params),
         {:ok, nonce_fields} <- encode_fields(params, [{:skip_nonce, :bool}, {:nonce, :nonce}]) do
      {:ok,
       <<byte_size(pub_key)::16, pub_key::binary, byte_size(l1_signature)::16, l1_signature::binary,
         nonce_fields::binary>>}
    end
  end

  defp encode_payload(_operation, _params), do: {:error, :invalid_argument}

  defp encode_fields(params, fields) do
    Enum.reduce_while(fields, {:ok, <<>>}, fn field, {:ok, encoded} ->
      case encode_field(params, field) do
        {:ok, value} -> {:cont, {:ok, <<encoded::binary, value::binary>>}}
        error -> {:halt, error}
      end
    end)
  end

  defp encode_field(params, {name, :bool}) do
    case Map.fetch(params, name) do
      {:ok, true} -> {:ok, <<1>>}
      {:ok, false} -> {:ok, <<0>>}
      _ -> {:error, :invalid_argument}
    end
  end

  defp encode_field(params, {name, :nonce}) do
    with {:ok, value} <- integer(params, name),
         :ok <- valid_uint(value, @max_i64) do
      {:ok, <<value::signed-64>>}
    end
  end

  defp encode_field(params, {name, :i64}) do
    with {:ok, value} <- integer(params, name),
         :ok <- valid_int(value, @min_i64, @max_i64) do
      {:ok, <<value::signed-64>>}
    end
  end

  defp encode_field(params, {name, :u32_i64, maximum}) do
    with {:ok, value} <- integer(params, name),
         :ok <- valid_uint(value, maximum) do
      {:ok, <<value::signed-64>>}
    end
  end

  defp encode_field(params, {name, :u8, maximum}) do
    encode_unsigned(params, name, maximum, 8)
  end

  defp encode_field(params, {name, :u16, maximum}) do
    encode_unsigned(params, name, maximum, 16)
  end

  defp encode_field(params, {name, :u32, maximum}) do
    encode_unsigned(params, name, maximum, 32)
  end

  defp memo(params) do
    case Map.fetch(params, :memo) do
      {:ok, value} when is_binary(value) and byte_size(value) == 64 ->
        case Base.decode16(value, case: :mixed) do
          {:ok, <<_::binary-size(32)>>} -> {:ok, value}
          _ -> {:error, :invalid_argument}
        end

      _ ->
        {:error, :invalid_argument}
    end
  end

  defp pub_key(params) do
    case Map.fetch(params, :pub_key) do
      {:ok, value} when is_binary(value) ->
        hex = strip_0x(value)

        if byte_size(hex) == 80 and match?({:ok, <<_::binary-size(40)>>}, Base.decode16(hex, case: :mixed)) do
          {:ok, hex}
        else
          {:error, :invalid_argument}
        end

      _ ->
        {:error, :invalid_argument}
    end
  end

  defp l1_signature(params) do
    case Map.fetch(params, :l1_signature) do
      {:ok, "0x" <> hex = value} when byte_size(hex) == 130 ->
        case Base.decode16(hex, case: :mixed) do
          {:ok, <<_::binary-size(65)>>} -> {:ok, value}
          _ -> {:error, :invalid_argument}
        end

      {:ok, "0X" <> hex} when byte_size(hex) == 130 ->
        l1_signature(%{l1_signature: "0x" <> hex})

      _ ->
        {:error, :invalid_argument}
    end
  end

  defp strip_0x("0x" <> rest), do: rest
  defp strip_0x("0X" <> rest), do: rest
  defp strip_0x(value) when is_binary(value), do: value

  defp encode_unsigned(params, name, maximum, bits) do
    with {:ok, value} <- integer(params, name),
         :ok <- valid_uint(value, maximum) do
      {:ok, <<value::size(bits)>>}
    end
  end

  defp decode_success(:init, <<>>), do: :ok

  defp decode_success(:auth_token, <<length::16, token::binary-size(length)>>), do: {:ok, token}

  defp decode_success(operation, <<tx_type, payload::binary>>)
       when operation in [
              :create_order,
              :cancel_order,
              :cancel_all_orders,
              :modify_order,
              :update_leverage,
              :update_margin,
              :transfer,
              :change_pub_key
            ] do
    with {:ok, tx_info, rest} <- take_string(payload),
         {:ok, tx_hash, rest} <- take_string(rest),
         {:ok, message_to_sign, <<>>} <- take_string(rest) do
      {:ok,
       %{
         tx_type: tx_type,
         tx_info: tx_info,
         tx_hash: tx_hash,
         message_to_sign: message_to_sign
       }}
    else
      _ -> {:error, :protocol_error}
    end
  end

  defp decode_success(_operation, _payload), do: {:error, :protocol_error}

  defp take_string(<<length::32, value::binary-size(length), rest::binary>>), do: {:ok, value, rest}

  defp take_string(_payload), do: {:error, :protocol_error}

  defp integer(params, name) do
    case Map.fetch(params, name) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      _ -> {:error, :invalid_argument}
    end
  end

  defp valid_string(value) when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_u16, do: :ok

  defp valid_string(_value), do: {:error, :invalid_argument}

  defp valid_uint(value, maximum), do: valid_int(value, 0, maximum)

  defp valid_int(value, minimum, maximum) when is_integer(value) and value >= minimum and value <= maximum, do: :ok

  defp valid_int(_value, _minimum, _maximum), do: {:error, :invalid_argument}
end
