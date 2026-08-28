defmodule Bourse.WS.AuthAckTest do
  @moduledoc """
  Pins the recognition table `Bourse.WS.AuthAck` maintains for every auth
  pattern `Bourse.WS.Auth` dispatches.

  A missing entry does not fail loudly at the venue — it makes the handshake
  wait out its window and report `:auth_ack_timeout` while the verdict sits
  unread in the mailbox. So the table is asserted whole, including the patterns
  no runtime venue currently uses.
  """

  use ExUnit.Case, async: true

  alias Bourse.WS.Auth
  alias Bourse.WS.AuthAck

  test "recognises each frame-based pattern's verdict frame" do
    assert :auth_response =
             AuthAck.classify(
               :action_key_secret,
               [%{"T" => "success", "msg" => "authenticated"}]
             )

    assert :auth_response =
             AuthAck.classify(:action_key_secret, [%{"T" => "error", "code" => 402}])

    assert :auth_response = AuthAck.classify(:direct_hmac_expiry, %{"op" => "auth", "success" => true})
    assert :auth_response = AuthAck.classify(:iso_passphrase, %{"event" => "login", "code" => "0"})
    assert :auth_response = AuthAck.classify(:iso_passphrase, %{"event" => "error", "code" => "60009"})
    assert :auth_response = AuthAck.classify(:sha384_nonce, %{"event" => "auth", "status" => "OK"})

    assert :auth_response =
             AuthAck.classify(:sha512_newline, %{"event" => "api", "channel" => "spot.login"})

    # Deribit normally correlates by request id; these are the shapes seen when
    # the reply arrives unmatched instead.
    assert :auth_response =
             AuthAck.classify(:jsonrpc_linebreak, %{"result" => %{"access_token" => "tok"}})

    assert :auth_response =
             AuthAck.classify(:jsonrpc_linebreak, %{"error" => %{"code" => 13_009}})

    assert :auth_response = AuthAck.classify(:eip191_jsonrpc_login, %{"result" => [144_422]})
    assert :auth_response = AuthAck.classify(:eip191_jsonrpc_login, %{"error" => %{"code" => 14_022}})

    assert :auth_response = AuthAck.classify(:ws_api_signature, %{"id" => "1", "status" => 200})
    assert :auth_response = AuthAck.classify(:ws_api_signature, %{"id" => "1", "status" => 401})
  end

  test "leaves everything else in the mailbox" do
    tick = %{"topic" => "tickers.BTCUSDT", "data" => %{"lastPrice" => "1"}}

    assert :not_auth = AuthAck.classify(:direct_hmac_expiry, tick)

    assert :not_auth =
             AuthAck.classify(:action_key_secret, [%{"T" => "success", "msg" => "connected"}])

    assert :not_auth = AuthAck.classify(:direct_hmac_expiry, %{"op" => "subscribe", "success" => true})
    assert :not_auth = AuthAck.classify(:iso_passphrase, %{"event" => "subscribe"})
    assert :not_auth = AuthAck.classify(:jsonrpc_linebreak, %{"result" => ["a.channel"]})
    assert :not_auth = AuthAck.classify(:jsonrpc_linebreak, %{"error" => nil})
    assert :not_auth = AuthAck.classify(:eip191_jsonrpc_login, %{"result" => %{"access_token" => "tok"}})
    assert :not_auth = AuthAck.classify(:eip191_jsonrpc_login, %{"error" => nil})

    # Binance's private WS-API host wraps user data in `event`; only its request
    # replies carry a `status`.
    assert :not_auth = AuthAck.classify(:ws_api_signature, %{"event" => %{"e" => "executionReport"}})

    # Patterns that authenticate without a verdict frame have no entry at all.
    assert :not_auth = AuthAck.classify(:listen_key, %{"result" => nil})
    assert :not_auth = AuthAck.classify(:rest_token, %{"event" => "auth"})
    assert :not_auth = AuthAck.classify(:inline_subscribe, %{"type" => "subscriptions"})
  end

  test "every dispatched pattern is accounted for, one way or the other" do
    # `Auth.patterns/0` is the contract this table shadows. A pattern added
    # there and forgotten here degrades to a timeout, so the omission is worth
    # catching at the seam rather than at a venue.
    frame_based = [
      :action_key_secret,
      :direct_hmac_expiry,
      :eip191_jsonrpc_login,
      :iso_passphrase,
      :jsonrpc_linebreak,
      :sha384_nonce,
      :sha512_newline,
      :ws_api_signature
    ]

    frameless = [:listen_key, :rest_token, :inline_subscribe]

    assert Enum.sort(Auth.patterns()) == Enum.sort(frame_based ++ frameless)

    for pattern <- frameless do
      assert :no_message =
               Auth.build_auth_message(
                 pattern,
                 Bourse.Credentials.new!(api_key: "k", secret: "s"),
                 %{},
                 []
               ),
             "#{pattern} is listed as frameless but builds an auth frame — it needs an AuthAck entry"
    end
  end
end
