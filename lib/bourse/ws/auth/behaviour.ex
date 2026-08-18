defmodule Bourse.WS.Auth.Behaviour do
  @moduledoc """
  Behaviour for WebSocket authentication pattern implementations.

  All WS auth patterns implement callbacks for building auth messages
  and handling auth responses. Patterns reuse `Bourse.Signing` crypto
  primitives (`hmac_sha256/2`, `hmac_sha384/2`, `hmac_sha512/2`,
  `encode_hex/1`, `encode_base64/1`, `timestamp_ms/0`, etc.).

  ## Auth Flow

  1. Caller invokes `Bourse.WS.Auth.pre_auth/4` (REST round-trip when needed)
  2. Caller invokes `Bourse.WS.Auth.build_auth_message/4`
  3. Caller sends the returned frame via `ZenWebsocket.Client.send_message/2`
  4. Caller feeds the response back through `Bourse.WS.Auth.handle_auth_response/3`

  ## Pattern Types

  - **Direct HMAC** — sign payload, send auth message (bybit, okx, bitfinex, …)
  - **Pre-auth** — REST call first, then WS (binance `listen_key`, kraken `rest_token`)
  - **Inline** — auth included in each subscribe message (coinbase)

  ## Implementing a Pattern

      defmodule Bourse.WS.Auth.DirectHmacExpiry do
        @behaviour Bourse.WS.Auth.Behaviour

        @impl true
        def pre_auth(_credentials, _config, _opts), do: {:ok, %{}}

        @impl true
        def build_auth_message(credentials, config, opts) do
          {:ok, %{"op" => "auth", "args" => [api_key, expires, signature]}}
        end

        @impl true
        def handle_auth_response(response, _state) do
          if response["success"], do: :ok, else: {:error, :auth_failed}
        end
      end

  """

  alias Bourse.Credentials

  @type auth_config :: map()
  @type auth_message :: map()
  @type auth_response :: map() | [map()]
  @type auth_state :: map()
  @type opts :: keyword()

  @type pre_auth_result :: {:ok, map()} | {:error, term()}
  @type build_result :: {:ok, auth_message()} | :no_message | {:error, term()}
  @type handle_result :: :ok | {:ok, map()} | {:error, term()}

  @doc """
  Performs pre-authentication (REST call for token/listen key).

  Returns `{:ok, data}` with pre-auth data the caller needs to drive the
  REST call and embed its result in the WS URL or subscribe frames.
  Patterns that don't need pre-auth return `{:ok, %{}}`.
  """
  @callback pre_auth(
              credentials :: Credentials.t(),
              config :: auth_config(),
              opts :: opts()
            ) :: pre_auth_result()

  @doc """
  Builds the WebSocket authentication frame.

  Returns `{:ok, message}` where `message` is a JSON-encodable map,
  `:no_message` when the pattern doesn't send a standalone auth frame
  (e.g. `listen_key`, `rest_token`, `inline_subscribe`), or `{:error, reason}`.
  """
  @callback build_auth_message(
              credentials :: Credentials.t(),
              config :: auth_config(),
              opts :: opts()
            ) :: build_result()

  @doc """
  Handles the authentication response frame.

  Returns `:ok` on success, `{:ok, auth_meta}` with metadata such as
  `%{ttl_ms: 900_000}` for expiry scheduling (see `Bourse.WS.Auth.Expiry`),
  or `{:error, reason}` on failure.
  """
  @callback handle_auth_response(
              response :: auth_response(),
              state :: auth_state()
            ) :: handle_result()

  @doc """
  Optional: build auth data to include in subscribe frames.

  For inline patterns (coinbase) and token patterns (kraken), auth data is
  attached to each private subscribe. Default is no inline auth.
  """
  @callback build_subscribe_auth(
              credentials :: Credentials.t(),
              config :: auth_config(),
              channel :: String.t() | nil,
              symbols :: list(String.t()) | nil
            ) :: map() | nil

  @optional_callbacks [build_subscribe_auth: 4]
end
