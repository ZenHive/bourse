defmodule Bourse.IntegrationHelper do
  @moduledoc """
  Integration test helpers for Phase 4b generators (Tasks 39/40/41/42).

  Provides four primitives:

    * `require_credentials!/2` — flunks with actionable env-var instructions
      when testnet credentials are missing, returns `%Bourse.Credentials{}` on success.
    * `build_exchange/2` — constructs `%Bourse.Exchange{}` with optional
      credentials + sandbox resolution.
    * `assert_public_response/3` — validates public endpoint responses,
      treats rate-limit/network errors as inconclusive.
    * `assert_private_response/3` — same for private endpoints, additionally
      treats auth/permission errors as inconclusive and accepts opt-gated
      exchange errors (`:allow_not_found`, `:allow_no_position`,
      `:allow_invalid_order`). The optional `:venue` is forwarded to struct
      validators for provider-specific response semantics.

  ## Two-stage response detection

  Responses are validated either as parsed unified structs (Phase 5) or raw
  `%{status, body}` HTTP envelopes. When Phase 5 parsers land, the same tests
  activate struct-level validation automatically via Task 42.

  ## Usage

      defmodule Bourse.BybitIntegrationTest do
        use ExUnit.Case, async: false
        import Bourse.IntegrationHelper

        @moduletag :integration

        test "public fetch_ticker" do
          exchange = build_exchange(:bybit, sandbox: false)
          result = Bourse.fetch_ticker(exchange, "BTC/USDT")
          assert_public_response(:fetch_ticker, result)
        end

        test "private fetch_balance" do
          creds = require_credentials!(:bybit)
          exchange = build_exchange(:bybit, credentials: creds, sandbox: true)
          result = Bourse.fetch_balance(exchange)
          assert_private_response(:fetch_balance, result)
        end
      end
  """

  import ExUnit.Assertions

  alias Bourse.Credentials
  alias Bourse.Error, as: CError
  alias Bourse.Exchange
  alias Bourse.Testnet

  require Logger

  @type method :: atom()
  @type result :: {:ok, map() | struct()} | {:error, term()}

  # :cloudflare_challenge covers CF anti-bot pages — exchange is reachable but
  # requires a browser/approved client. Inconclusive on both public and private
  # paths. :access_restricted stays OUT of @inconclusive_public so HTML responses
  # without CF markers (wrong URL/prefix, landing pages) flunk as T80 URL bugs.
  # On the private path :access_restricted remains inconclusive — a valid-creds
  # call landing on a geo/IP block isn't a code bug.
  @inconclusive_public [
    :rate_limit_exceeded,
    :network_error,
    :exchange_not_available,
    :cloudflare_challenge
  ]
  @inconclusive_private_auth [
    :authentication_error,
    :permission_denied,
    :access_restricted,
    :cloudflare_challenge
  ]

  # With `allow_4xx: true`, normalized errors in this set mean our request was
  # malformed (wrong endpoint, bad param wiring) — always flunk.
  @request_malformation [
    :bad_request,
    :invalid_parameters,
    :not_supported
  ]

  # With `allow_4xx: true`, these mean a well-formed request the exchange declined
  # (probe symbol missing, no funds, order absent) — inconclusive, not a pipeline bug.
  @well_formed_declined [
    :bad_symbol,
    :insufficient_funds,
    :order_not_found,
    :invalid_order,
    :operation_failed,
    :market_closed
  ]

  # ============================================================================
  # Credential Gate
  # ============================================================================

  @doc """
  Returns registered testnet credentials for `exchange`, or flunks with
  setup instructions.

  ## Options

    * `:sandbox_key` — sandbox slot (default `:default`, e.g. `:futures`, `:coinm`)
    * `:passphrase` — if `true`, mention `{EXCHANGE}_PASSPHRASE` in the flunk message
    * `:url` — override signup URL shown in the flunk message
  """
  @spec require_credentials!(atom(), keyword()) :: Credentials.t()
  def require_credentials!(exchange, opts \\ []) when is_atom(exchange) do
    sandbox_key = Keyword.get(opts, :sandbox_key, :default)

    case Testnet.creds(exchange, sandbox_key) do
      %Credentials{} = creds ->
        creds

      nil ->
        flunk(missing_credentials_message(exchange, sandbox_key, opts))
    end
  end

  @doc """
  Returns the human-readable "missing testnet credentials" message that
  `require_credentials!/2` flunks with. Exposed so generators (e.g. the per-
  exchange `setup_all` gates in `RawEndpointProbe` /
  `UnifiedMethodIntegrationProbe`) can `raise` it from outside an `ExUnit.Case`
  context where `flunk/1` isn't available.
  """
  @spec missing_credentials_message(atom(), atom(), keyword()) :: String.t()
  def missing_credentials_message(exchange, sandbox_key, opts \\ []) do
    prefix = exchange |> Atom.to_string() |> String.upcase()
    sandbox_infix = sandbox_infix(sandbox_key)
    passphrase? = Keyword.get(opts, :passphrase, false)

    url_line =
      case Keyword.get(opts, :url) do
        nil -> ""
        url -> "\nGet credentials at: #{url}"
      end

    base = """
      export #{prefix}#{sandbox_infix}_TESTNET_API_KEY="your_key"
      export #{prefix}#{sandbox_infix}_TESTNET_API_SECRET="your_secret"
    """

    passphrase_line =
      if passphrase?, do: ~s(  export #{prefix}_PASSPHRASE="your_passphrase"\n), else: ""

    """
    Missing testnet credentials for #{exchange} (sandbox: #{inspect(sandbox_key)}).

    Set these environment variables and re-run:
    #{String.trim_trailing(base <> passphrase_line)}#{url_line}
    """
  end

  defp sandbox_infix(:default), do: ""
  defp sandbox_infix(key) when is_atom(key), do: "_" <> (key |> Atom.to_string() |> String.upcase())

  # ============================================================================
  # Exchange Builder
  # ============================================================================

  @doc """
  Builds an `%Bourse.Exchange{}` for integration tests.

  ## Options

    * `:credentials` — `%Bourse.Credentials{}` struct to attach
    * `:sandbox` — force sandbox URL resolution (default `false`)
    * `:hostname` — override hostname in the spec
    * `:options` — exchange-specific options map
  """
  @spec build_exchange(atom(), keyword()) :: Exchange.t()
  def build_exchange(exchange, opts \\ []) when is_atom(exchange) do
    # Apply credentials first (including creds.sandbox), then let explicit
    # :sandbox/:hostname/:options opts override.
    exchange_opts =
      []
      |> maybe_put_credentials(Keyword.get(opts, :credentials))
      |> put_if(:sandbox, Keyword.get(opts, :sandbox))
      |> put_if(:hostname, Keyword.get(opts, :hostname))
      |> put_if(:options, Keyword.get(opts, :options))

    Exchange.new!(exchange, exchange_opts)
  end

  defp maybe_put_credentials(opts, nil), do: opts

  defp maybe_put_credentials(opts, %Credentials{} = creds) do
    opts
    |> Keyword.put(:credentials, creds)
    |> put_if(:sandbox, creds.sandbox || nil)
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  # ============================================================================
  # Response Assertions
  # ============================================================================

  @doc """
  Asserts a public endpoint response is well-formed.

  Rate-limit and transient network errors are logged as inconclusive and do
  NOT flunk (infrastructure issue, not a code bug). Unexpected errors flunk.

  ## Options

    * `:allow_4xx` — when `true`, normalized errors that mean "well-formed request,
      exchange declined" (`:bad_symbol`, `:insufficient_funds`, …) log inconclusive;
      request-malformation classes (`:bad_request`, `:invalid_parameters`, …) still
      flunk. Keys on normalized error class, not raw HTTP status. Defaults to `false`.
      Used by Task 83 raw-endpoint probes.
  """
  @spec assert_public_response(method(), result(), keyword()) :: :ok
  def assert_public_response(method, result, opts \\ []) do
    case result do
      {:ok, body} ->
        validate_body!(method, body, opts)
        :ok

      {:error, %CError{} = err} ->
        handle_public_error(method, err, opts)

      {:error, reason} ->
        flunk("#{method} failed: #{inspect(reason)}")

      other ->
        flunk("#{method} returned unexpected value: #{inspect(other)}")
    end
  end

  defp handle_public_error(method, %CError{type: type} = err, opts) do
    cond do
      type in @inconclusive_public ->
        log_inconclusive(method, err)
        :ok

      allow_4xx_declined?(type, err, opts) ->
        log_inconclusive(method, err)
        :ok

      true ->
        flunk(error_flunk_message(method, err, opts))
    end
  end

  @doc """
  Asserts a private endpoint response is well-formed.

  In addition to public-endpoint inconclusive classes, treats
  `:authentication_error`, `:permission_denied`, and `:access_restricted` as
  inconclusive (likely testnet/geo issue). Opt flags allow specific exchange
  errors: `:allow_not_found`, `:allow_no_position`, `:allow_invalid_order`.

  ## Options

    * `:allow_4xx` — when `true`, well-formed-but-declined normalized errors
      log inconclusive; request-malformation classes still flunk. Same semantics
      as the public helper; used by Task 83 raw-endpoint probes.
    * `:venue` — exchange id forwarded to struct validators. This keeps
      provider-specific signed balance/position semantics narrowly scoped.
  """
  @spec assert_private_response(method(), result(), keyword()) :: :ok
  def assert_private_response(method, result, opts \\ []) do
    case result do
      {:ok, body} ->
        validate_body!(method, body, opts)
        :ok

      {:error, %CError{} = err} ->
        handle_private_error(method, err, opts)

      {:error, reason} ->
        flunk("#{method} failed: #{inspect(reason)}")

      other ->
        flunk("#{method} returned unexpected value: #{inspect(other)}")
    end
  end

  defp handle_private_error(method, %CError{type: type} = err, opts) do
    cond do
      type in @inconclusive_public or type in @inconclusive_private_auth ->
        log_inconclusive(method, err)
        :ok

      allowed_error?(type, err, opts) ->
        log_inconclusive(method, err)
        :ok

      allow_4xx_declined?(type, err, opts) ->
        log_inconclusive(method, err)
        :ok

      true ->
        flunk(error_flunk_message(method, err, opts))
    end
  end

  defp allowed_error?(:order_not_found, _err, opts), do: Keyword.get(opts, :allow_not_found, false)

  defp allowed_error?(:invalid_order, _err, opts), do: Keyword.get(opts, :allow_invalid_order, false)

  defp allowed_error?(:exchange_error, err, opts), do: Keyword.get(opts, :allow_no_position, false) and no_position?(err)

  defp allowed_error?(_type, _err, _opts), do: false

  # `allow_4xx: true` inconclusive only for well-formed-but-declined classes — not
  # blanket 400..499. Request-malformation types always fall through to flunk.
  defp allow_4xx_declined?(type, _err, opts) do
    Keyword.get(opts, :allow_4xx, false) and
      type not in @request_malformation and
      type in @well_formed_declined
  end

  # ============================================================================
  # Body Validation (two-stage detection)
  # ============================================================================

  # Struct path — parsed unified types (Task 42 validators).
  defp validate_body!(method, %_{} = struct, opts) do
    validate_struct(method, struct, opts)
  end

  defp validate_body!(method, [%_{} | _] = list, opts) do
    validate_struct(method, list, opts)
  end

  # Raw HTTP envelope — probes normally get `{:error, %CError{}}` for 4xx; this
  # arm covers legacy/direct callers. Without a normalized class we cannot
  # distinguish malformation from decline, so 4xx always flunks.
  defp validate_body!(method, %{status: status, body: body}, _opts) do
    assert status >= 200 and status < 300,
           "#{method} returned non-acceptable status #{status}: #{inspect(body)}"

    validate_shape!(method, unwrap(body))
  end

  # Fallback — treat bare map/list as body.
  defp validate_body!(method, body, _opts), do: validate_shape!(method, unwrap(body))

  # Unwrap one level of common envelopes: %{"result" => ...}, %{"data" => ...}, %{"response" => ...}
  defp unwrap(%{} = map) do
    Enum.find_value(["result", "data", "response"], map, fn key ->
      case Map.get(map, key) do
        nil -> nil
        inner when is_map(inner) or is_list(inner) -> inner
        _ -> nil
      end
    end)
  end

  defp unwrap(other), do: other

  # Method-specific shape assertions (raw path).
  defp validate_shape!(:fetch_ticker, body) when is_map(body) do
    assert has_price_field?(body),
           "fetch_ticker: no price-like field in keys #{inspect(Map.keys(body))}"
  end

  defp validate_shape!(:fetch_ticker, [first | _] = body) when is_list(body) do
    assert is_map(first) and has_price_field?(first),
           "fetch_ticker: list element missing price-like field: #{inspect(first)}"
  end

  defp validate_shape!(:fetch_ticker, body) do
    flunk("fetch_ticker: expected map or non-empty list of maps, got #{inspect_type(body)}")
  end

  defp validate_shape!(:fetch_tickers, body) do
    assert is_map(body) or is_list(body),
           "fetch_tickers: expected map or list, got #{inspect_type(body)}"
  end

  defp validate_shape!(:fetch_order_book, body) do
    assert is_map(body), "fetch_order_book: expected map, got #{inspect_type(body)}"

    assert has_list_at?(body, ["bids", "b", "bid"]) and has_list_at?(body, ["asks", "a", "ask"]),
           "fetch_order_book: missing bids/asks lists in keys #{inspect(Map.keys(body))}"
  end

  defp validate_shape!(:fetch_trades, body) do
    assert is_list(body) or is_map(body),
           "fetch_trades: expected list or map, got #{inspect_type(body)}"
  end

  defp validate_shape!(:fetch_ohlcv, body) do
    assert is_list(body) or is_map(body),
           "fetch_ohlcv: expected list or map, got #{inspect_type(body)}"
  end

  defp validate_shape!(:fetch_markets, body) do
    assert is_list(body) or is_map(body),
           "fetch_markets: expected list or map, got #{inspect_type(body)}"
  end

  defp validate_shape!(:fetch_currencies, body) do
    assert is_map(body) or is_list(body),
           "fetch_currencies: expected map or list, got #{inspect_type(body)}"
  end

  defp validate_shape!(:fetch_balance, body) do
    assert is_map(body), "fetch_balance: expected map, got #{inspect_type(body)}"
  end

  defp validate_shape!(_method, body) do
    refute is_nil(body), "empty response body"
  end

  defp validate_struct(method, data, opts) do
    Bourse.StructValidators.validate_for_method!(method, data, opts)
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp has_price_field?(map) do
    map
    |> Map.keys()
    |> Enum.any?(&price_key?/1)
  end

  defp price_key?(key) when is_binary(key) do
    lower = String.downcase(key)
    String.contains?(lower, "price") or lower in ["last", "bid", "ask", "close"]
  end

  defp price_key?(key) when is_atom(key), do: key |> Atom.to_string() |> price_key?()
  defp price_key?(_), do: false

  defp has_list_at?(map, keys) do
    Enum.any?(keys, fn key -> is_list(Map.get(map, key)) end)
  end

  defp no_position?(%CError{message: msg}) when is_binary(msg) do
    lower = String.downcase(msg)
    String.contains?(lower, "no position") or String.contains?(lower, "position not found")
  end

  defp no_position?(_), do: false

  defp inspect_type(value) when is_list(value), do: "list(#{length(value)})"
  defp inspect_type(value) when is_map(value), do: "map(#{map_size(value)})"
  defp inspect_type(value), do: inspect(value)

  defp log_inconclusive(method, %CError{type: type, message: msg}) do
    Logger.warning("""
    ⚠️  INCONCLUSIVE: #{method} returned #{type}: #{inspect(msg)}
    Treating as infrastructure issue, not a code bug.
    """)
  end

  defp error_flunk_message(method, %CError{type: type, code: code, message: msg, raw: raw}, _opts) do
    raw_line = if raw, do: "  raw: #{inspect(raw)}\n", else: ""

    """
    #{method} failed with Bourse error:
      type: #{inspect(type)}
      code: #{inspect(code)}
      message: #{inspect(msg)}
    """ <> raw_line
  end
end
