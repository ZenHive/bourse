defmodule Bourse.WS.AuthAck do
  @moduledoc """
  Recognises which inbound frame is a venue's answer to an auth attempt.

  The parallel of `Bourse.WS.SubscribeAck`, and it exists for the same reason:
  on the asynchronous venues the auth reply arrives in the caller's mailbox
  behind whatever else the socket is already delivering, so the waiter has to
  tell "this is the auth outcome" apart from "this is a data frame".

  The pattern modules' own `handle_auth_response/2` cannot answer that. Each
  ends in a catch-all that reads an unrecognised frame as
  `{:error, {:auth_failed, frame}}` — correct once you know the frame *is* the
  auth reply, and a false rejection for any heartbeat or tick that happens to
  land first. So recognition happens here and adjudication stays there:
  `classify/2` only decides whether the frame belongs to the handshake.
  """

  alias Bourse.WS.Auth

  @type classification :: :auth_response | :not_auth

  @doc """
  Says whether `frame` is the venue's response to `pattern`'s auth attempt.

  Returns `:auth_response` for a frame the pattern's classifier should judge,
  and `:not_auth` for anything else — leave those in the mailbox.
  """
  @spec classify(Auth.pattern(), map() | [map()]) :: classification()
  def classify(:action_key_secret, frames) when is_list(frames) do
    if Enum.any?(frames, &alpaca_auth_response?/1), do: :auth_response, else: :not_auth
  end

  def classify(:direct_hmac_expiry, %{"op" => "auth"}), do: :auth_response
  def classify(:iso_passphrase, %{"event" => "login"}), do: :auth_response
  def classify(:iso_passphrase, %{"event" => "error"}), do: :auth_response
  def classify(:sha384_nonce, %{"event" => "auth"}), do: :auth_response
  def classify(:sha512_newline, %{"event" => "api", "channel" => "spot.login"}), do: :auth_response

  # Deribit correlates its auth reply through the request id, so this path is
  # only reached when the reply arrives unmatched.
  def classify(:jsonrpc_linebreak, %{"result" => %{"access_token" => _}}), do: :auth_response
  def classify(:jsonrpc_linebreak, %{"error" => error}) when not is_nil(error), do: :auth_response

  # Binance's WS API answers every request with a `status`, and its private host
  # carries nothing else that does — user data arrives wrapped in `event`. Also
  # normally correlated by request id; this is the unmatched path.
  def classify(:ws_api_signature, %{"status" => _}), do: :auth_response

  def classify(_pattern, frame) when is_map(frame) or is_list(frame), do: :not_auth

  defp alpaca_auth_response?(%{"T" => "success", "msg" => "authenticated"}), do: true
  defp alpaca_auth_response?(%{"T" => "error"}), do: true
  defp alpaca_auth_response?(_frame), do: false
end
