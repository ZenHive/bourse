defmodule Bourse.WS.ListenKey do
  @moduledoc """
  Performs the REST round-trip the `:listen_key` auth pattern needs.

  `Bourse.WS.Auth.ListenKey` resolves *which* endpoint issues and refreshes a
  key; this module calls them through `Bourse.Dispatch` and returns the key
  itself. The split keeps the pattern module network-free.

  ## Why this runs before the socket opens

  A listen key is not sent as a frame — it is embedded in the WebSocket URL.
  USD-M uses `?listenKey=...&events=...`; COIN-M keeps its path segment. There
  is no post-connect handshake to fall back on, so `Bourse.WS.connect/3` calls
  `open/3` first and connects to the URL the key produces.

  The failure this prevents is silent. A connection opened with a wrong,
  expired or absent key is *accepted* by the venue and then simply never
  delivers: verified against `demo-fstream.binance.com` 2026-08-06, where a
  real key produced an `ORDER_TRADE_UPDATE` for an order placed on the same
  account and a syntactically-valid bogus key produced nothing at all, both
  sockets reporting `:connected` throughout.

  ## Keepalive

  Binance expires an idle key 60 minutes after issue. `keepalive/3` sends the
  authored refresh endpoint (`PUT`); `Bourse.WS.Adapter` schedules it from the
  `keepalive_ms` the pattern resolves.
  """

  alias Bourse.Dispatch
  alias Bourse.Exchange
  alias Bourse.WS.Auth.ListenKey, as: Pattern

  @type session :: %{
          listen_key: String.t(),
          market_type: atom(),
          keepalive_endpoint: atom() | nil,
          keepalive_ms: pos_integer()
        }

  @doc """
  Issues a listen key for the exchange's private stream.

  Returns `{:ok, session}` carrying the key plus what a caller needs to keep it
  alive. Errors are the venue's own — an unresolvable market type, an endpoint
  the generated module does not carry, a transport or business failure from the
  issuing call, or a response without a `listenKey` field.
  """
  @spec open(Exchange.t(), map(), keyword()) :: {:ok, session()} | {:error, term()}
  def open(%Exchange{} = exchange, auth_config, opts \\ []) do
    with {:ok, credentials} <- fetch_credentials(exchange),
         {:ok, resolved} <- Pattern.pre_auth(credentials, auth_config, opts),
         {:ok, endpoint} <- endpoint_config(exchange, resolved.endpoint),
         {:ok, body} <- call(exchange, endpoint, request_opts(opts)),
         {:ok, listen_key} <- extract_key(body) do
      {:ok,
       %{
         listen_key: listen_key,
         market_type: resolved.market_type,
         keepalive_endpoint: resolved.keepalive_endpoint,
         keepalive_ms: resolved.keepalive_ms
       }}
    end
  end

  @doc """
  Refreshes an issued key so the venue does not expire it.

  Binance's refresh endpoint takes no key parameter — it extends whatever key
  the credentials own — so the session is passed only to name the endpoint.
  Returns `{:error, :no_keepalive_endpoint}` when the venue authors none, which
  is a configuration gap rather than a venue failure.
  """
  @spec keepalive(Exchange.t(), session(), keyword()) :: :ok | {:error, term()}
  def keepalive(exchange, session, opts \\ [])

  def keepalive(%Exchange{}, %{keepalive_endpoint: nil}, _opts), do: {:error, :no_keepalive_endpoint}

  def keepalive(%Exchange{} = exchange, %{keepalive_endpoint: name}, opts) do
    with {:ok, endpoint} <- endpoint_config(exchange, name),
         {:ok, _body} <- call(exchange, endpoint, request_opts(opts)) do
      :ok
    end
  end

  # `:market_type` selects the endpoint and is consumed here; everything else a
  # caller passes is for the request itself — a timeout, a base URL override.
  defp request_opts(opts), do: Keyword.drop(opts, [:market_type, :request_id])

  defp fetch_credentials(%Exchange{credentials: nil}), do: {:error, :no_credentials}
  defp fetch_credentials(%Exchange{credentials: credentials}), do: {:ok, credentials}

  defp endpoint_config(%Exchange{module: nil}, _name), do: {:error, :unsupported_exchange}

  defp endpoint_config(%Exchange{module: module}, name) do
    case Enum.find(module.__endpoints__(), &(&1.name == name)) do
      nil -> {:error, {:unknown_listen_key_endpoint, name}}
      endpoint -> {:ok, endpoint}
    end
  end

  defp call(exchange, endpoint, opts) do
    case Dispatch.call(exchange, endpoint, %{}, opts) do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, _} = error -> error
    end
  end

  defp extract_key(%{"listenKey" => key}) when is_binary(key) and key != "", do: {:ok, key}
  defp extract_key(body), do: {:error, {:no_listen_key_in_response, body}}
end
