defmodule Bourse.WS.Auth do
  @moduledoc """
  WebSocket authentication pattern dispatcher.

  Parallel of `Bourse.Signing`: a function-head dispatcher that routes a
  pattern atom to the matching per-pattern module. Each pattern module
  implements the `Bourse.WS.Auth.Behaviour` callbacks.

  ## Supported Patterns

  | Pattern | Exchanges | Notes |
  |---------|-----------|-------|
  | `:action_key_secret` | alpaca market data | Plain `action: auth` key/secret frame |
  | `:direct_hmac_expiry` | bybit, bitmex, htx family | `GET/realtime{expires}` HMAC-SHA256 |
  | `:iso_passphrase` | okx family, kucoin family | Requires `credentials.password` |
  | `:jsonrpc_linebreak` | deribit | JSON-RPC `public/auth`, returns `{:ok, %{ttl_ms: _}}` |
  | `:eip191_jsonrpc_login` | derive | EIP-191 of the ms timestamp, JSON-RPC `public/login` |
  | `:sha384_nonce` | bitfinex | `AUTH{nonce}` HMAC-SHA384 |
  | `:sha512_newline` | gate, gateio | Gate `spot.login` HMAC-SHA512 |
  | `:listen_key` | binance USD-M / COIN-M | REST pre-auth, key travels in the WS URL |
  | `:ws_api_signature` | binance spot | Signed WS-API request that opens the user data stream |
  | `:rest_token` | kraken | REST pre-auth, token injected into subscribe frames |
  | `:inline_subscribe` | coinbaseexchange | Auth fields inlined in each subscribe frame |

  ## Usage

  Typical flow from the adapter layer (T94/T95):

      {:ok, pre_auth_data} = Bourse.WS.Auth.pre_auth(pattern, credentials, config, market_type: :spot)
      # caller performs any REST round-trip implied by pre_auth_data

      case Bourse.WS.Auth.build_auth_message(pattern, credentials, config) do
        {:ok, frame}   -> ZenWebsocket.Client.send_message(client, Jason.encode!(frame))
        :no_message    -> :ok   # listen_key / rest_token / inline_subscribe
        {:error, why}  -> {:error, why}
      end

      # After receiving the auth response frame:
      case Bourse.WS.Auth.handle_auth_response(pattern, response, state) do
        :ok                        -> :authenticated
        {:ok, %{ttl_ms: _}} = meta -> schedule_re_auth(meta)
        {:error, reason}           -> {:auth_failed, reason}
      end

  Per-exchange configuration (which pattern + which config options + which
  channels need inline token injection) lives in `Bourse.WS.Config` entries
  added by Task 94.
  """

  alias Bourse.Credentials
  alias Bourse.WS.Auth.ActionKeySecret
  alias Bourse.WS.Auth.DirectHmacExpiry
  alias Bourse.WS.Auth.Eip191JsonrpcLogin
  alias Bourse.WS.Auth.InlineSubscribe
  alias Bourse.WS.Auth.IsoPassphrase
  alias Bourse.WS.Auth.JsonrpcLinebreak
  alias Bourse.WS.Auth.ListenKey
  alias Bourse.WS.Auth.RestToken
  alias Bourse.WS.Auth.Sha384Nonce
  alias Bourse.WS.Auth.Sha512Newline
  alias Bourse.WS.Auth.WsApiSignature

  @type pattern ::
          :action_key_secret
          | :direct_hmac_expiry
          | :eip191_jsonrpc_login
          | :iso_passphrase
          | :jsonrpc_linebreak
          | :sha384_nonce
          | :sha512_newline
          | :listen_key
          | :rest_token
          | :inline_subscribe
          | :ws_api_signature

  @type config :: map()
  @type auth_message :: map()
  @type pre_auth_result :: {:ok, map()} | {:error, term()}
  @type build_result :: {:ok, auth_message()} | :no_message | {:error, term()}

  @patterns [
    :action_key_secret,
    :direct_hmac_expiry,
    :eip191_jsonrpc_login,
    :iso_passphrase,
    :jsonrpc_linebreak,
    :sha384_nonce,
    :sha512_newline,
    :listen_key,
    :rest_token,
    :inline_subscribe,
    :ws_api_signature
  ]

  @doc "Lists every supported auth pattern atom."
  @spec patterns() :: [pattern()]
  def patterns, do: @patterns

  @doc """
  Performs pattern-specific pre-auth. Patterns that don't require a REST
  round-trip return `{:ok, %{}}`.
  """
  @spec pre_auth(pattern(), Credentials.t(), config(), keyword()) :: pre_auth_result()
  def pre_auth(:action_key_secret, credentials, config, opts), do: ActionKeySecret.pre_auth(credentials, config, opts)

  def pre_auth(:listen_key, credentials, config, opts), do: ListenKey.pre_auth(credentials, config, opts)

  def pre_auth(:rest_token, credentials, config, opts), do: RestToken.pre_auth(credentials, config, opts)

  def pre_auth(:direct_hmac_expiry, credentials, config, opts), do: DirectHmacExpiry.pre_auth(credentials, config, opts)

  def pre_auth(:iso_passphrase, credentials, config, opts), do: IsoPassphrase.pre_auth(credentials, config, opts)

  def pre_auth(:eip191_jsonrpc_login, credentials, config, opts),
    do: Eip191JsonrpcLogin.pre_auth(credentials, config, opts)

  def pre_auth(:jsonrpc_linebreak, credentials, config, opts), do: JsonrpcLinebreak.pre_auth(credentials, config, opts)

  def pre_auth(:sha384_nonce, credentials, config, opts), do: Sha384Nonce.pre_auth(credentials, config, opts)

  def pre_auth(:sha512_newline, credentials, config, opts), do: Sha512Newline.pre_auth(credentials, config, opts)

  def pre_auth(:inline_subscribe, credentials, config, opts), do: InlineSubscribe.pre_auth(credentials, config, opts)

  def pre_auth(:ws_api_signature, credentials, config, opts), do: WsApiSignature.pre_auth(credentials, config, opts)

  def pre_auth(pattern, _credentials, _config, _opts), do: {:error, {:unknown_pattern, pattern}}

  @doc """
  Builds the auth frame for the pattern. Patterns without a standalone auth
  frame return `:no_message` — the caller should skip the send step.
  """
  @spec build_auth_message(pattern(), Credentials.t(), config(), keyword()) :: build_result()
  def build_auth_message(:action_key_secret, credentials, config, opts),
    do: ActionKeySecret.build_auth_message(credentials, config, opts)

  def build_auth_message(:direct_hmac_expiry, credentials, config, opts),
    do: DirectHmacExpiry.build_auth_message(credentials, config, opts)

  def build_auth_message(:iso_passphrase, credentials, config, opts),
    do: IsoPassphrase.build_auth_message(credentials, config, opts)

  def build_auth_message(:eip191_jsonrpc_login, credentials, config, opts),
    do: Eip191JsonrpcLogin.build_auth_message(credentials, config, opts)

  def build_auth_message(:jsonrpc_linebreak, credentials, config, opts),
    do: JsonrpcLinebreak.build_auth_message(credentials, config, opts)

  def build_auth_message(:sha384_nonce, credentials, config, opts),
    do: Sha384Nonce.build_auth_message(credentials, config, opts)

  def build_auth_message(:sha512_newline, credentials, config, opts),
    do: Sha512Newline.build_auth_message(credentials, config, opts)

  def build_auth_message(:listen_key, credentials, config, opts),
    do: ListenKey.build_auth_message(credentials, config, opts)

  def build_auth_message(:rest_token, credentials, config, opts),
    do: RestToken.build_auth_message(credentials, config, opts)

  def build_auth_message(:inline_subscribe, credentials, config, opts),
    do: InlineSubscribe.build_auth_message(credentials, config, opts)

  def build_auth_message(:ws_api_signature, credentials, config, opts),
    do: WsApiSignature.build_auth_message(credentials, config, opts)

  def build_auth_message(pattern, _credentials, _config, _opts), do: {:error, {:unknown_pattern, pattern}}

  @doc """
  Builds inline auth data to merge into subscribe frames.

  `:inline_subscribe` (coinbase) produces per-subscribe HMAC fields.
  `:rest_token` (kraken) injects `%{"token" => token}` — the caller must
  thread the REST-acquired token through `opts[:token]` since pattern
  modules are stateless.

  Returns `nil` for all other patterns.
  """
  @spec build_subscribe_auth(
          pattern(),
          Credentials.t(),
          config(),
          String.t() | nil,
          list(String.t()) | nil
        ) :: map() | nil
  def build_subscribe_auth(:inline_subscribe, credentials, config, channel, symbols),
    do: InlineSubscribe.build_subscribe_auth(credentials, config, channel, symbols)

  def build_subscribe_auth(:rest_token, _credentials, config, _channel, _symbols) do
    case Map.get(config, :token) do
      nil -> nil
      token when is_binary(token) -> %{"token" => token}
    end
  end

  def build_subscribe_auth(_pattern, _credentials, _config, _channel, _symbols), do: nil

  @doc "Dispatches an auth response to the pattern's classifier."
  @spec handle_auth_response(pattern(), map() | [map()], map()) ::
          :ok | {:ok, map()} | {:error, term()}
  def handle_auth_response(:action_key_secret, response, state), do: ActionKeySecret.handle_auth_response(response, state)

  def handle_auth_response(:direct_hmac_expiry, response, state),
    do: DirectHmacExpiry.handle_auth_response(response, state)

  def handle_auth_response(:iso_passphrase, response, state), do: IsoPassphrase.handle_auth_response(response, state)

  def handle_auth_response(:eip191_jsonrpc_login, response, state),
    do: Eip191JsonrpcLogin.handle_auth_response(response, state)

  def handle_auth_response(:jsonrpc_linebreak, response, state),
    do: JsonrpcLinebreak.handle_auth_response(response, state)

  def handle_auth_response(:sha384_nonce, response, state), do: Sha384Nonce.handle_auth_response(response, state)

  def handle_auth_response(:sha512_newline, response, state), do: Sha512Newline.handle_auth_response(response, state)

  def handle_auth_response(:listen_key, response, state), do: ListenKey.handle_auth_response(response, state)

  def handle_auth_response(:rest_token, response, state), do: RestToken.handle_auth_response(response, state)

  def handle_auth_response(:inline_subscribe, response, state), do: InlineSubscribe.handle_auth_response(response, state)

  def handle_auth_response(:ws_api_signature, response, state), do: WsApiSignature.handle_auth_response(response, state)

  def handle_auth_response(pattern, _response, _state), do: {:error, {:unknown_pattern, pattern}}

  @doc "Returns `true` for patterns that require a REST pre-auth round-trip."
  @spec requires_pre_auth?(pattern()) :: boolean()
  def requires_pre_auth?(:listen_key), do: true
  def requires_pre_auth?(:rest_token), do: true
  def requires_pre_auth?(_), do: false

  @doc "Returns `true` for patterns that attach auth to each subscribe frame."
  @spec inline_auth?(pattern()) :: boolean()
  def inline_auth?(:inline_subscribe), do: true
  def inline_auth?(:rest_token), do: true
  def inline_auth?(_), do: false

  @doc "Returns the implementing module for a pattern, or `nil` if unknown."
  @spec module_for_pattern(pattern()) :: module() | nil
  def module_for_pattern(:action_key_secret), do: ActionKeySecret
  def module_for_pattern(:direct_hmac_expiry), do: DirectHmacExpiry
  def module_for_pattern(:eip191_jsonrpc_login), do: Eip191JsonrpcLogin
  def module_for_pattern(:iso_passphrase), do: IsoPassphrase
  def module_for_pattern(:jsonrpc_linebreak), do: JsonrpcLinebreak
  def module_for_pattern(:sha384_nonce), do: Sha384Nonce
  def module_for_pattern(:sha512_newline), do: Sha512Newline
  def module_for_pattern(:listen_key), do: ListenKey
  def module_for_pattern(:rest_token), do: RestToken
  def module_for_pattern(:inline_subscribe), do: InlineSubscribe
  def module_for_pattern(:ws_api_signature), do: WsApiSignature
  def module_for_pattern(_), do: nil
end
