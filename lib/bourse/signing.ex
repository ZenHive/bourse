defmodule Bourse.Signing do
  @moduledoc """
  Signing pattern library for exchange authentication.

  Provides a unified interface for signing API requests across the in-scope
  exchange registry. Authored HMAC recipes cover the common exchange families,
  with first-party modules for venue-specific signers:

  | Pattern | In-scope use | Description |
  |---------|-----------|-------------|
  | `:hmac_sha256_query` | Binance family | Sign query string |
  | `:hmac_sha256_headers` | Bybit-style | Sign body/headers |
  | `:hmac_sha256_iso_passphrase` | OKX-style | ISO timestamp + passphrase |
  | `:deribit` | Deribit | Custom Authorization header format |
  | `:hyperliquid` | Hyperliquid | EIP-712 / action signing |
  | `:derive` | Derive | EIP-712 order/message signing |
  | `:lighter` | Lighter | Isolated official zk-Schnorr signer |
  | `:api_key_secret_headers` | Alpaca-style | API key and secret headers |

  ## Usage

      signed = Bourse.Signing.sign(
        :hmac_sha256_headers,
        %Bourse.Signing.Request{method: :get, path: "/v5/account/wallet-balance"},
        credentials,
        signing_config
      )

  Pattern selection is authored in each supported runtime spec. Consumers
  cannot register reference-only exchanges or inject long-tail signers.
  """

  alias Bourse.Credentials
  alias Bourse.Signing.ApiKeySecretHeaders
  alias Bourse.Signing.Deribit
  alias Bourse.Signing.Derive
  alias Bourse.Signing.HmacRecipe
  alias Bourse.Signing.Hyperliquid
  alias Bourse.Signing.Lighter
  alias Bourse.Signing.Request
  alias Bourse.Signing.SignedRequest

  @type method :: Request.method()

  @type request :: Request.t()

  @type signed_request :: SignedRequest.t()

  @type pattern ::
          :hmac_sha256_query
          | :hmac_sha256_headers
          | :hmac_sha256_iso_passphrase
          | :deribit
          | :hyperliquid
          | :derive
          | :lighter
          | :api_key_secret_headers

  @type config :: %{
          optional(:api_key_header) => String.t(),
          optional(:secret_header) => String.t(),
          optional(:timestamp_header) => String.t(),
          optional(:signature_header) => String.t(),
          optional(:passphrase_header) => String.t(),
          optional(:recv_window_header) => String.t(),
          optional(:recv_window) => non_neg_integer(),
          optional(:signature_encoding) => :hex | :base64 | :url,
          optional(:sign_recipe) => map(),
          optional(:sign_recipe_section) => String.t(),
          optional(atom()) => term()
        }

  # --- Dispatcher (function-head routing) ---

  @hmac_recipe_patterns [
    :hmac_sha256_query,
    :hmac_sha256_headers,
    :hmac_sha256_iso_passphrase
  ]

  @spec normalize_request(request() | map()) :: Request.t()
  defp normalize_request(%Request{} = request), do: request

  defp normalize_request(%{} = request) do
    %Request{
      method: Map.fetch!(request, :method),
      path: Map.fetch!(request, :path),
      body: Map.get(request, :body),
      params: Map.get(request, :params, %{})
    }
  end

  defp hmac_recipe_sign(pattern, request, credentials, config) do
    exchange = Map.get(config, :exchange)
    timed_sign(&HmacRecipe.sign/3, request, credentials, config, pattern, exchange)
  end

  # Telemetry wrapper for sign duration (single event; signing is fast sync op).
  defp timed_sign(fun, request, credentials, config, pattern, exchange) when is_function(fun, 3) do
    request = normalize_request(request)
    start_time = System.monotonic_time()

    try do
      res = fun.(request, credentials, config)
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        Bourse.Telemetry.signing_sign(),
        %{duration: duration},
        %{exchange: exchange, pattern: pattern}
      )

      res
    rescue
      # reach:disable-next-line bare_rescue — intentional: emit signing telemetry then reraise the original exception
      e ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          Bourse.Telemetry.signing_sign(),
          %{duration: duration},
          %{exchange: exchange, pattern: pattern}
        )

        reraise e, __STACKTRACE__
    end
  end

  @doc """
  Signs a request using the specified pattern and configuration.

  ## Parameters

  - `pattern` - The signing pattern atom (e.g., `:hmac_sha256_headers`)
  - `request` - `Bourse.Signing.Request` or equivalent map (`:method`, `:path`, `:body`, `:params`)
  - `credentials` - `Bourse.Credentials` struct with API key and secret
  - `config` - Pattern-specific configuration from the exchange spec

  ## Returns

  A `Bourse.Signing.SignedRequest` with `:url`, `:method`, `:headers`, and `:body`.
  """
  @spec sign(pattern(), request(), Credentials.t(), config()) ::
          signed_request()
          | {:error, {:unsupported_signing, term()} | {:lighter_signing, term()}}
  def sign(:hmac_sha256_query, request, credentials, %{sign_recipe: recipe} = config) when is_map(recipe) do
    hmac_recipe_sign(:hmac_sha256_query, request, credentials, config)
  end

  def sign(:hmac_sha256_headers, request, credentials, %{sign_recipe: recipe} = config) when is_map(recipe) do
    hmac_recipe_sign(:hmac_sha256_headers, request, credentials, config)
  end

  def sign(:hmac_sha256_iso_passphrase, request, credentials, %{sign_recipe: recipe} = config) when is_map(recipe) do
    hmac_recipe_sign(:hmac_sha256_iso_passphrase, request, credentials, config)
  end

  def sign(pattern, _request, _credentials, config) when pattern in @hmac_recipe_patterns do
    raise ArgumentError,
          "HMAC pattern #{inspect(pattern)} requires config.sign_recipe (a map); got #{inspect(Map.get(config, :sign_recipe))}"
  end

  def sign(:api_key_secret_headers, request, credentials, config) do
    exchange = Map.get(config, :exchange)

    timed_sign(
      &ApiKeySecretHeaders.sign/3,
      request,
      credentials,
      config,
      :api_key_secret_headers,
      exchange
    )
  end

  def sign(:deribit, request, credentials, config) do
    exchange = Map.get(config, :exchange)
    timed_sign(&Deribit.sign/3, request, credentials, config, :deribit, exchange)
  end

  def sign(:hyperliquid, request, credentials, config) do
    exchange = Map.get(config, :exchange)
    timed_sign(&Hyperliquid.sign/3, request, credentials, config, :hyperliquid, exchange)
  end

  def sign(:derive, request, credentials, config) do
    exchange = Map.get(config, :exchange)
    timed_sign(&Derive.sign/3, request, credentials, config, :derive, exchange)
  end

  def sign(:lighter, request, credentials, config) do
    exchange = Map.get(config, :exchange)
    timed_sign(&Lighter.sign/3, request, credentials, config, :lighter, exchange)
  end

  # --- Introspection ---

  @doc """
  Returns the list of supported signing patterns.
  """
  @spec patterns() :: [pattern()]
  def patterns do
    [
      :hmac_sha256_query,
      :hmac_sha256_headers,
      :hmac_sha256_iso_passphrase,
      :deribit,
      :hyperliquid,
      :derive,
      :lighter,
      :api_key_secret_headers
    ]
  end

  @doc """
  Checks if a pattern is supported.
  """
  @spec pattern?(atom()) :: boolean()
  def pattern?(pattern), do: pattern in patterns()

  @doc """
  Returns the signing module for a given pattern.
  """
  @spec module_for_pattern(pattern()) :: module() | nil
  def module_for_pattern(:hmac_sha256_query), do: HmacRecipe
  def module_for_pattern(:hmac_sha256_headers), do: HmacRecipe
  def module_for_pattern(:hmac_sha256_iso_passphrase), do: HmacRecipe
  def module_for_pattern(:api_key_secret_headers), do: ApiKeySecretHeaders
  def module_for_pattern(:deribit), do: Deribit
  def module_for_pattern(:hyperliquid), do: Hyperliquid
  def module_for_pattern(:derive), do: Derive
  def module_for_pattern(:lighter), do: Lighter
  def module_for_pattern(_), do: nil

  # --- Shared Crypto Helpers ---
  # Used by signing pattern modules for building signatures.

  @doc "Current UTC time in milliseconds."
  @spec timestamp_ms() :: non_neg_integer()
  def timestamp_ms, do: System.system_time(:millisecond)

  @doc "Current UTC time in seconds."
  @spec timestamp_seconds() :: non_neg_integer()
  def timestamp_seconds, do: System.system_time(:second)

  @doc "Current UTC time as ISO 8601 string, truncated to millisecond precision."
  @spec timestamp_iso8601() :: String.t()
  def timestamp_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  # Deterministic-override helpers.
  # Production callers never set `:timestamp_ms_override` / `:nonce_override` in
  # config, so behavior is unchanged. Signature-vector tests inject them to
  # reproduce a frozen provider request.

  @doc """
  Returns a preformatted `config[:timestamp]` first, then
  `config[:timestamp_ms_override]`, otherwise current wall time in milliseconds.
  Used by pattern modules so dispatch can provide the v4 sign recipe timestamp
  and signature-vector tests can inject a frozen provider timestamp.
  """
  @spec timestamp_ms_from_config(map()) :: non_neg_integer() | String.t()
  def timestamp_ms_from_config(config) do
    case Map.get(config, :timestamp) do
      ts when is_binary(ts) ->
        ts

      _ ->
        case Map.get(config, :timestamp_ms_override) do
          nil -> timestamp_ms()
          ms when is_integer(ms) -> ms
        end
    end
  end

  @doc "Like `timestamp_ms_from_config/1` but in seconds."
  @spec timestamp_seconds_from_config(map()) :: non_neg_integer() | String.t()
  def timestamp_seconds_from_config(config) do
    case Map.get(config, :timestamp) do
      ts when is_binary(ts) ->
        ts

      _ ->
        case Map.get(config, :timestamp_ms_override) do
          nil -> timestamp_seconds()
          ms when is_integer(ms) -> div(ms, 1000)
        end
    end
  end

  @doc "Like `timestamp_ms_from_config/1` but rendered as ISO 8601 UTC."
  @spec timestamp_iso8601_from_config(map()) :: String.t()
  def timestamp_iso8601_from_config(config) do
    case Map.get(config, :timestamp) do
      ts when is_binary(ts) ->
        ts

      _ ->
        case Map.get(config, :timestamp_ms_override) do
          nil ->
            timestamp_iso8601()

          ms when is_integer(ms) ->
            ms
            |> DateTime.from_unix!(:millisecond)
            |> DateTime.truncate(:millisecond)
            |> DateTime.to_iso8601()
        end
    end
  end

  @doc """
  Returns `config[:nonce_override]` when set, otherwise invokes `fallback`.
  Fallback is a zero-arity function so callers control nonce semantics
  (e.g. `:erlang.unique_integer` vs `System.system_time(:microsecond)`).
  """
  @spec nonce_from_config(map(), (-> integer())) :: integer()
  def nonce_from_config(config, fallback) when is_function(fallback, 0) do
    case Map.get(config, :nonce_override) do
      nil -> fallback.()
      n when is_integer(n) -> n
    end
  end

  @doc "HMAC-SHA256 of `data` with `secret`."
  @spec hmac_sha256(iodata(), iodata()) :: binary()
  def hmac_sha256(data, secret) do
    :crypto.mac(:hmac, :sha256, secret, data)
  end

  @doc "HMAC-SHA384 of `data` with `secret`."
  @spec hmac_sha384(iodata(), iodata()) :: binary()
  def hmac_sha384(data, secret) do
    :crypto.mac(:hmac, :sha384, secret, data)
  end

  @doc "HMAC-SHA512 of `data` with `secret`."
  @spec hmac_sha512(iodata(), iodata()) :: binary()
  def hmac_sha512(data, secret) do
    :crypto.mac(:hmac, :sha512, secret, data)
  end

  @doc "SHA-256 hash of `data`."
  @spec sha256(iodata()) :: binary()
  def sha256(data) do
    :crypto.hash(:sha256, data)
  end

  @doc "SHA-512 hash of `data`."
  @spec sha512(iodata()) :: binary()
  def sha512(data) do
    :crypto.hash(:sha512, data)
  end

  @doc "Lowercase hex-encodes a binary."
  @spec encode_hex(binary()) :: String.t()
  def encode_hex(binary) do
    Base.encode16(binary, case: :lower)
  end

  @doc "Base64-encodes a binary."
  @spec encode_base64(binary()) :: String.t()
  def encode_base64(binary) do
    Base.encode64(binary)
  end

  @doc "Decodes a Base64-encoded string. Raises on invalid input."
  @spec decode_base64(String.t()) :: binary()
  def decode_base64(encoded) do
    Base.decode64!(encoded)
  end

  @doc """
  URL-encodes params as a sorted query string.

  Uses RFC 3986 percent-encoding via `URI.encode/2` with `URI.char_unreserved?/1`
  — **spaces become `%20`**, never the `application/x-www-form-urlencoded` `+`
  that Elixir's `URI.encode_query/1` emits. Venue authority for the default:
  Huobi/HTX spot signing docs require URL-encoded query params with uppercase
  hex and show the space as `%20` (not `+`) —
  https://huobiapi.github.io/docs/spot/v1/en/#authentication (Signature
  Method). Hex digits from `URI.encode/2` are
  uppercase, matching the same Huobi rule. No first-class venue has been
  observed to require www-form `+` for the signed canonical query — if one
  does, register a per-venue carve rather than reverting this default (see
  `docs/authored-specs.md` C21).

  List-valued scalar params use empty-bracket keys
  (`%{"ids" => ["a", "b"]}` → `"ids%5B%5D=a&ids%5B%5D=b"`). That is the form
  Deribit's JSON-RPC-over-GET accepts live (OpenAPI lists `style=form,
  explode=true`, but the live parser only materializes a list for `key[]=…`;
  Bracket-index `ids[0]=…` is rejected with `value required`, and bare repeated
  keys with `value must be a list`. Nested list/map items raise
  `ArgumentError` naming the param — never `URI.encode_query`'s opaque list crash.

  Recipe venues that need plain repeated keys use
  `urlencodeWithArrayRepeat` via `encode_query_pairs/2`.
  """
  @spec urlencode(map() | keyword() | [{term(), term()}] | nil) :: String.t()
  def urlencode(nil), do: ""
  def urlencode(params) when params == %{} or params == [], do: ""

  def urlencode(params) when is_map(params) do
    params
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> encode_query_pairs()
  end

  def urlencode(params) when is_list(params) do
    encode_query_pairs(params)
  end

  @doc """
  Encodes an ordered list of `{key, value}` pairs as a query string.

  Percent-encodes keys and values the same way as `urlencode/1` (space → `%20`,
  not `+`). See that function's moduledoc for the venue-doc rationale.

  ## Options

  - `:array_style` — `:brackets` (default, `key[]=v`) or `:repeat` (`key=v` repeated)
  """
  @spec encode_query_pairs([{term(), term()}]) :: String.t()
  @spec encode_query_pairs([{term(), term()}], keyword()) :: String.t()
  def encode_query_pairs(pairs, opts \\ []) when is_list(pairs) do
    style = Keyword.get(opts, :array_style, :brackets)

    pairs
    |> expand_array_params(style)
    |> Enum.map_join("&", &encode_query_pair/1)
  end

  @doc "URL-encodes params as a sorted query string without percent-encoding values."
  @spec urlencode_raw(map() | nil) :: String.t()
  def urlencode_raw(nil), do: ""
  def urlencode_raw(params) when params == %{}, do: ""

  def urlencode_raw(params) do
    params
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.flat_map(&expand_raw_pair/1)
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp expand_array_params(pairs, style) do
    Enum.flat_map(pairs, fn
      {key, values} when is_list(values) -> expand_list_param(key, values, style)
      pair -> [pair]
    end)
  end

  defp expand_list_param(key, values, style) do
    out_key =
      case style do
        :brackets -> "#{key}[]"
        :repeat -> key
      end

    Enum.map(values, fn
      value when is_map(value) or is_list(value) ->
        raise ArgumentError,
              "unsupported nested query param #{inspect(to_string(key))}: " <>
                "list items must be scalars (got #{query_value_kind(value)}). " <>
                "Use a JSON body or pre-encode the value; GET query encoding cannot carry nested structures safely."

      value ->
        {out_key, value}
    end)
  end

  defp encode_query_pair({key, value}) do
    encode_query_component(key) <> "=" <> encode_query_component(value)
  end

  # Match URI.encode_query/1 coercion for scalars; diverge only on space → %20.
  defp encode_query_component(nil), do: ""

  defp encode_query_component(value) when is_binary(value) do
    URI.encode(value, &URI.char_unreserved?/1)
  end

  defp encode_query_component(value) do
    value
    |> to_string()
    |> URI.encode(&URI.char_unreserved?/1)
  end

  defp expand_raw_pair({key, values}) when is_list(values), do: expand_list_param(key, values, :brackets)

  defp expand_raw_pair(pair), do: [pair]

  defp query_value_kind(value) when is_map(value), do: "map"
  defp query_value_kind(value) when is_list(value), do: "list"
end
