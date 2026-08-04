defmodule Bourse.Signing.Lighter.ProtocolTest do
  use ExUnit.Case, async: true

  alias Bourse.Signing.Lighter.Protocol

  @request_id 42

  test "encodes initialization without placing the key outside its framed field" do
    key = String.duplicate("ab", 40)

    assert {:ok,
            <<1, 1, @request_id::32, 20::16, "https://lighter.test", 80::16, ^key::binary-size(80), 304::32, 7,
              99::signed-64>>} =
             Protocol.encode_init(@request_id, "https://lighter.test", key, 304, 7, 99)
  end

  test "rejects invalid initialization values" do
    key = String.duplicate("ab", 40)

    assert {:error, :invalid_argument} = Protocol.encode_init(-1, "url", key, 304, 0, 1)
    assert {:error, :invalid_argument} = Protocol.encode_init(1, "", key, 304, 0, 1)
    assert {:error, :invalid_argument} = Protocol.encode_init(1, "url", "", 304, 0, 1)
    assert {:error, :invalid_argument} = Protocol.encode_init(1, "url", key, 0x80000000, 0, 1)
    assert {:error, :invalid_argument} = Protocol.encode_init(1, "url", key, 304, 256, 1)
    assert {:error, :invalid_argument} = Protocol.encode_init(1, "url", key, 304, 0, 0)
  end

  test "encodes every whitelisted transaction operation" do
    assert {:ok, <<1, 2, @request_id::32, 1_800_000_000::signed-64>>} =
             Protocol.encode_request(@request_id, :auth_token, %{deadline: 1_800_000_000})

    assert {:ok, <<1, 3, @request_id::32, _payload::binary>>} =
             Protocol.encode_request(@request_id, :create_order, create_order())

    assert {:ok, <<1, 4, @request_id::32, _payload::binary>>} =
             Protocol.encode_request(@request_id, :cancel_order, %{
               market_index: 1,
               order_index: 2,
               skip_nonce: false,
               nonce: 3
             })

    assert {:ok, <<1, 5, @request_id::32, _payload::binary>>} =
             Protocol.encode_request(@request_id, :cancel_all_orders, %{
               time_in_force: 0,
               time: 0,
               market_index: 1,
               skip_nonce: true,
               nonce: 4
             })

    assert {:ok, <<1, 6, @request_id::32, _payload::binary>>} =
             Protocol.encode_request(@request_id, :modify_order, %{
               market_index: 1,
               index: 2,
               base_amount: 3,
               price: 4,
               trigger_price: 0,
               integrator_account_index: 5,
               integrator_taker_fee: 6,
               integrator_maker_fee: 7,
               self_trade_behavior: 0,
               self_trade_equality: 0,
               skip_nonce: false,
               nonce: 8
             })

    assert {:ok, <<1, 7, @request_id::32, _payload::binary>>} =
             Protocol.encode_request(@request_id, :update_leverage, %{
               market_index: 1,
               initial_margin_fraction: 100,
               margin_mode: 0,
               skip_nonce: false,
               nonce: 9
             })

    assert {:ok, <<1, 8, @request_id::32, _payload::binary>>} =
             Protocol.encode_request(@request_id, :update_margin, %{
               market_index: 1,
               usdc_amount: -10,
               direction: 1,
               skip_nonce: false,
               nonce: 10
             })
  end

  test "rejects unknown, missing, and out-of-range operation values" do
    assert {:error, :invalid_argument} = Protocol.encode_request(@request_id, :withdraw, %{})
    assert {:error, :invalid_argument} = Protocol.encode_request(@request_id, :auth_token, %{})
    assert {:error, :invalid_argument} = Protocol.encode_request(@request_id, :auth_token, %{deadline: -1})

    assert {:error, :invalid_argument} =
             Protocol.encode_request(@request_id, :create_order, Map.delete(create_order(), :nonce))

    assert {:error, :invalid_argument} =
             Protocol.encode_request(@request_id, :create_order, %{create_order() | nonce: -1})

    assert {:error, :invalid_argument} =
             Protocol.encode_request(@request_id, :create_order, %{create_order() | is_ask: 1})

    assert {:error, :invalid_argument} =
             Protocol.encode_request(@request_id, :create_order, %{create_order() | market_index: 0x8000})

    assert {:error, :invalid_argument} =
             Protocol.encode_request(@request_id, :create_order, %{
               create_order()
               | client_order_index: 0x8000000000000000
             })

    assert {:error, :invalid_argument} =
             Protocol.encode_request(@request_id, :modify_order, %{
               market_index: 1,
               index: 2,
               base_amount: 3,
               price: -1,
               trigger_price: 0,
               integrator_account_index: 5,
               integrator_taker_fee: 6,
               integrator_maker_fee: 7,
               self_trade_behavior: 0,
               self_trade_equality: 0,
               skip_nonce: false,
               nonce: 8
             })

    assert {:error, :invalid_argument} =
             Protocol.encode_request(@request_id, :update_leverage, %{
               market_index: 1,
               initial_margin_fraction: 0x10000,
               margin_mode: 0,
               skip_nonce: false,
               nonce: 9
             })
  end

  test "decodes successful initialization, auth, and signed transactions strictly" do
    assert :ok = Protocol.decode_response(<<1, 1, @request_id::32, 0, 0>>, :init, @request_id)

    assert {:ok, "token"} =
             Protocol.decode_response(<<1, 2, @request_id::32, 0, 0, 5::16, "token">>, :auth_token, @request_id)

    payload = <<14, 2::32, "{}", 4::32, "hash", 7::32, "message">>

    assert {:ok, %{tx_type: 14, tx_info: "{}", tx_hash: "hash", message_to_sign: "message"}} =
             Protocol.decode_response(<<1, 3, @request_id::32, 0, 0, payload::binary>>, :create_order, @request_id)
  end

  test "maps helper errors and rejects malformed or mismatched responses" do
    Enum.each(1..7, fn code ->
      assert {:error, error} =
               Protocol.decode_response(<<1, 2, @request_id::32, 1, 0, code>>, :auth_token, @request_id)

      assert error
    end)

    assert {:error, :protocol_error} =
             Protocol.decode_response(<<1, 2, @request_id::32, 1, 0, 99>>, :auth_token, @request_id)

    assert {:error, :protocol_error} =
             Protocol.decode_response(<<2, 2, @request_id::32, 0, 0>>, :auth_token, @request_id)

    assert {:error, :protocol_error} =
             Protocol.decode_response(<<1, 3, @request_id::32, 0, 0>>, :auth_token, @request_id)

    assert {:error, :protocol_error} =
             Protocol.decode_response(<<1, 2, 43::32, 0, 0>>, :auth_token, @request_id)

    assert {:error, :protocol_error} =
             Protocol.decode_response(<<1, 3, @request_id::32, 0, 0, 14, 99::32>>, :create_order, @request_id)
  end

  defp create_order do
    %{
      market_index: 1,
      client_order_index: 2,
      base_amount: 3,
      price: 4,
      is_ask: false,
      order_type: 0,
      time_in_force: 0,
      reduce_only: false,
      trigger_price: 0,
      order_expiry: 0,
      integrator_account_index: 5,
      integrator_taker_fee: 6,
      integrator_maker_fee: 7,
      self_trade_behavior: 0,
      self_trade_equality: 0,
      skip_nonce: false,
      nonce: 8
    }
  end
end
