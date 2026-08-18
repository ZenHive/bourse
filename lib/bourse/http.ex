defmodule Bourse.HTTP do
  @moduledoc """
  HTTP client for exchange API requests.

  Wraps Req with circuit breaker integration, error normalization, and
  telemetry. All exchange HTTP communication goes through this module.

  Error classification lives in `Bourse.HTTP.Errors`; rate-limit descriptor
  shaping and header→state updates live in `Bourse.RateLimiter.Shaping`.

  ## Why Manual Query Encoding?

  Uses `URI.encode_query/1` instead of Req's `:params` step because:

  1. **Signing requires raw params** — signing patterns need params before URL encoding
  2. **Sorted encoding** — some exchanges require alphabetically sorted params
  3. **Consistency** — both public and private requests use the same encoding

  ## Features

  - **Circuit breaker** — per-exchange, trips on 500+ and transport errors
  - **Error normalization** — HTTP/exchange errors to `Bourse.Error` structs
  - **Body-level error detection** — many exchanges return HTTP 200 with error in body
  - **HTML response detection** — geo-blocks and Cloudflare return HTML instead of JSON
  - **Safe retry** — only GET/HEAD, never POST/PUT/DELETE
  - **Telemetry** — emits `[:bourse, :request, :start | :stop | :exception]`

  ## Signed Retry Boundary

  `signed_request/5` keeps Req's retry policy and backoff, but attaches a
  request step that obtains a fresh signature before every repeated attempt.
  Req therefore never replays frozen timestamp, nonce, or deadline material.

  `signed_request/4` accepts an already-signed request for compatibility and
  is always single-attempt. A caller-supplied `:retry` option cannot re-enable
  retries for that frozen request.

  ## Usage

      {:ok, exchange} = Bourse.Exchange.new("bybit")

      # Public endpoint
      {:ok, response} = Bourse.HTTP.request(exchange, :get, "/v5/market/tickers",
        params: %{"category" => "spot", "symbol" => "BTCUSDT"}
      )

  """

  alias Bourse.CircuitBreaker
  alias Bourse.Defaults
  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.HTTP.Errors
  alias Bourse.RateLimiter.Shaping
  alias Bourse.Signing

  @base_client_key {__MODULE__, :base_client}

  @typedoc "HTTP response with status, headers, and decoded body"
  @type response_headers :: %{optional(String.t()) => [String.t()]}
  @type response :: %{status: integer(), headers: response_headers(), body: term()}

  @doc """
  Makes an HTTP request to an exchange API.

  ## Parameters

  - `exchange` - Exchange configuration struct
  - `method` - HTTP method (`:get`, `:post`, `:put`, `:delete`)
  - `path` - API endpoint path (e.g., "/v5/market/tickers")

  ## Options

  - `:params` - Query parameters or request body (default: `%{}`)
  - `:headers` - Additional request headers (default: `[]`)
  - `:timeout` - Request timeout in milliseconds (default: from `Bourse.Defaults`)
  - `:base_url` - Override base URL (default: uses exchange.base_urls)
  - `:body_encoding` - Endpoint body convention from the exchange spec

  Any additional options are passed through to Req (useful for `:plug` in tests).

  ## Returns

  - `{:ok, response}` - Successful response with `:status`, `:headers`, `:body`
  - `{:error, %Bourse.Error{}}` - Normalized error
  """
  @spec request(Exchange.t(), atom(), String.t(), keyword()) ::
          {:ok, response()} | {:error, Error.t()}
  def request(%Exchange{} = exchange, method, path, opts \\ []) do
    params = Keyword.get(opts, :params, %{})
    headers = sandbox_headers(exchange) ++ Keyword.get(opts, :headers, [])
    timeout = Keyword.get(opts, :timeout, Defaults.request_timeout_ms())
    custom_base_url = Keyword.get(opts, :base_url)
    body_encoding = Keyword.get(opts, :body_encoding)
    endpoint_weight = Keyword.get(opts, :endpoint_weight, 1)
    endpoint_rate_limit = Keyword.get(opts, :endpoint_rate_limit, endpoint_weight)

    extra_opts =
      Keyword.drop(opts, [
        :params,
        :headers,
        :timeout,
        :base_url,
        :body_encoding,
        :endpoint_weight,
        :endpoint_rate_limit
      ])

    with :ok <- check_circuit_breaker(exchange),
         :ok <- Shaping.maybe_rate_limit(Shaping.rate_key(exchange), exchange, endpoint_rate_limit) do
      base_url = custom_base_url || default_base_url(exchange)

      request_opts = %{
        base_url: base_url,
        error_scope: Exchange.error_scope(exchange, base_url),
        timeout: timeout,
        retry: Defaults.retry_policy(),
        body_encoding: body_encoding,
        extra_opts: extra_opts
      }

      do_request(exchange, method, path, params, headers, request_opts)
    end
  end

  # ===========================================================================
  # Request Execution
  # ===========================================================================

  defp do_request(exchange, method, path, params, headers, request_opts) do
    %{
      base_url: base_url,
      error_scope: error_scope,
      timeout: timeout,
      retry: retry,
      body_encoding: body_encoding,
      extra_opts: extra_opts
    } = request_opts

    req_opts = build_request(method, path, params, headers, base_url, body_encoding)
    req_opts = Keyword.merge(req_opts, [receive_timeout: timeout, retry: retry] ++ retry_delay_opt())
    req_opts = Keyword.merge(req_opts, extra_opts)

    execute_request(exchange, method, path, req_opts, error_scope)
  end

  # Configured backoff, or `[]` to leave Req's exponential default in place
  # (which honors a `retry-after` header on 429/503; a set value bypasses it).
  #
  # Always concatenated BEFORE `extra_opts`, never merged over it: Req resolves
  # a duplicated scalar option last-wins, so this order gives a per-call
  # `:retry_delay` precedence. Do not "clarify" this with `Keyword.merge/2` in
  # the signed path — `:headers` appears in both lists and Req composes
  # duplicates additively, so a merge would drop the signed auth headers.
  defp retry_delay_opt do
    case Defaults.retry_delay() do
      nil -> []
      delay -> [retry_delay: delay]
    end
  end

  # Shared execution pipeline: telemetry, Req call, circuit breaker, response handling.
  # Used by both unsigned (do_request) and signed (signed_request) code paths.
  defp execute_request(exchange, method, path, req_opts, error_scope, request_step \\ nil) do
    exchange_id = exchange.id
    start_time = System.monotonic_time()

    emit_start(exchange_id, method, path)

    # Rescue wraps *transport only*. Classifier runs outside so a bug in
    # Errors.classify_response cannot be mislabeled as network_error (task 255).
    transport =
      try do
        base_client = get_base_client()
        run_request(base_client, req_opts, request_step)
      rescue
        # reach:disable-next-line bare_rescue — transport boundary only
        e ->
          emit_exception(exchange_id, method, path, :exception, e, start_time)
          CircuitBreaker.record_failure(exchange_id)
          {:transport_exception, e}
      end

    case transport do
      {:transport_exception, e} ->
        {:error, Error.network_error(message: "Exception: #{Exception.message(e)}", exchange: exchange_id)}

      {:ok, %Req.Response{status: status, headers: resp_headers, body: body}} ->
        emit_stop(exchange_id, method, path, status, start_time)
        Shaping.maybe_update_state(exchange, resp_headers)
        # Record the circuit breaker against the *normalized* outcome so the melt
        # decision flows from the Phase 13 retry classification (server_busy /
        # network buckets melt; rate_limit / auth / non_retryable do not), not a
        # raw status threshold. Transport-level 5xx still melt via http_status.
        scoped_exchange = Exchange.with_error_scope(exchange, error_scope)
        outcome = Errors.classify_response(method, status, resp_headers, body, scoped_exchange)
        CircuitBreaker.record_result(exchange_id, outcome)
        outcome

      {:error, %Req.TransportError{reason: reason}} ->
        emit_exception(exchange_id, method, path, :transport, reason, start_time)
        outcome = {:error, Error.network_error(message: "Transport error: #{inspect(reason)}", exchange: exchange_id)}
        CircuitBreaker.record_result(exchange_id, outcome)
        outcome

      {:error, %Error{} = error} ->
        emit_exception(exchange_id, method, path, :request, error, start_time)
        outcome = {:error, error}
        CircuitBreaker.record_result(exchange_id, outcome)
        outcome

      {:error, reason} ->
        emit_exception(exchange_id, method, path, :request, reason, start_time)
        outcome = {:error, Error.network_error(message: "Request failed: #{inspect(reason)}", exchange: exchange_id)}
        CircuitBreaker.record_result(exchange_id, outcome)
        outcome
    end
  end

  # Req 0.7 deprecates function adapters (removal planned for 0.8). An injected
  # transport fun (capture layers, test transports) moves into the request's
  # private map and dispatches through the Bourse.HTTP.FnAdapter module adapter.
  # The adapter is set after merging the remaining options so the fun keeps
  # winning over a `:plug` option (which sets the adapter slot itself in 0.7).
  defp run_request(base_client, req_opts, request_step) do
    request =
      case Keyword.pop(req_opts, :adapter) do
        {fun, remaining_opts} when is_function(fun, 1) ->
          base_client
          |> Req.merge(remaining_opts)
          |> Req.Request.put_private(:bourse_adapter_fun, fun)
          |> Map.put(:adapter, Bourse.HTTP.FnAdapter)

        _ ->
          Req.merge(base_client, req_opts)
      end

    request
    |> maybe_append_request_step(request_step)
    |> Req.request()
  end

  defp maybe_append_request_step(request, nil), do: request

  defp maybe_append_request_step(request, step) when is_function(step, 1) do
    Req.Request.append_request_steps(request, bourse_signed_retry: step)
  end

  # ===========================================================================
  # Signed Request Execution
  # ===========================================================================

  @doc """
  Executes an already-signed request exactly once.

  This compatibility entry point forces `retry: false`, including when `opts`
  contains another retry policy, because it cannot refresh time-bound signing
  material. Dispatch uses `signed_request/5` instead.
  """
  @spec signed_request(Exchange.t(), Signing.signed_request(), String.t(), keyword()) ::
          {:ok, response()} | {:error, Error.t()}
  def signed_request(%Exchange{} = exchange, signed, base_url, opts \\ []) do
    opts = opts |> Keyword.delete(:retry) |> Keyword.put(:retry, false)
    do_signed_request(exchange, signed, base_url, nil, opts)
  end

  @doc """
  Executes a signed request and refreshes its signature before every retry.

  `resigner` reproduces the complete signed URL, headers, and body from the
  original unsigned request. Req still controls whether and when to retry; the
  Bourse request step replaces the time-bound signing material before the
  repeated attempt reaches the adapter.
  """
  @spec signed_request(
          Exchange.t(),
          Signing.signed_request(),
          String.t(),
          (-> Signing.signed_request() | {:error, Error.t()}),
          keyword()
        ) :: {:ok, response()} | {:error, Error.t()}
  def signed_request(%Exchange{} = exchange, signed, base_url, resigner, opts) when is_function(resigner, 0) do
    request_step = &refresh_signed_request(&1, base_url, resigner)
    do_signed_request(exchange, signed, base_url, request_step, opts)
  end

  defp do_signed_request(exchange, signed, base_url, request_step, opts) do
    timeout = Keyword.get(opts, :timeout, Defaults.request_timeout_ms())
    endpoint_weight = Keyword.get(opts, :endpoint_weight, 1)
    endpoint_rate_limit = Keyword.get(opts, :endpoint_rate_limit, endpoint_weight)
    extra_opts = Keyword.drop(opts, [:timeout, :endpoint_weight, :endpoint_rate_limit])

    with :ok <- check_circuit_breaker(exchange),
         :ok <- Shaping.maybe_rate_limit(Shaping.rate_key(exchange), exchange, endpoint_rate_limit) do
      url = base_url <> signed.url
      body_opts = if signed.body, do: [body: signed.body], else: []

      req_opts =
        [method: signed.method, url: url, headers: sandbox_headers(exchange) ++ signed.headers] ++
          body_opts ++
          [receive_timeout: timeout, retry: Defaults.retry_policy()] ++
          retry_delay_opt() ++
          extra_opts

      [telemetry_path | _] = String.split(signed.url, "?", parts: 2)
      error_scope = Exchange.error_scope(exchange, base_url)
      execute_request(exchange, signed.method, telemetry_path, req_opts, error_scope, request_step)
    end
  end

  defp refresh_signed_request(request, base_url, resigner) do
    if Req.Request.get_private(request, :bourse_signed_attempt_started, false) do
      case resigner.() do
        {:error, %Error{} = error} -> {request, error}
        signed -> merge_signed_request(request, signed, base_url)
      end
    else
      Req.Request.put_private(request, :bourse_signed_attempt_started, true)
    end
  end

  defp merge_signed_request(request, signed, base_url) do
    Req.merge(request,
      method: signed.method,
      url: base_url <> signed.url,
      headers: signed.headers,
      body: signed.body
    )
  end

  # ===========================================================================
  # Request Building
  # ===========================================================================

  # Builds Req options with manual query encoding for unsigned (public) requests.
  # Uses Signing.urlencode/1 so list-valued params (and nesting errors) match the
  # signed path — never bare URI.encode_query, which crashes on lists.
  defp build_request(method, path, params, extra_headers, base_url, body_encoding) do
    case method do
      m when m in [:get, :head, :delete] ->
        query_string = if params == %{}, do: "", else: "?" <> Signing.urlencode(params)
        url = base_url <> path <> query_string
        [method: method, url: url, headers: extra_headers]

      m when m in [:post, :put, :patch] ->
        url = base_url <> path
        headers = [{"content-type", "application/json"}] ++ extra_headers
        body = if params == %{} and body_encoding != "json", do: nil, else: Jason.encode!(params)
        body_opts = if body, do: [body: body], else: []
        [method: m, url: url, headers: headers] ++ body_opts
    end
  end

  defp sandbox_headers(%Exchange{sandbox: true, sandbox_headers: headers}) when is_map(headers) do
    Map.to_list(headers)
  end

  defp sandbox_headers(%Exchange{}), do: []

  # ===========================================================================
  # Base URL Resolution
  # ===========================================================================

  # Picks the default base URL from exchange.base_urls.
  # Handles 3 URL structures from specs:
  #   Flat:   %{"public" => "https://api.bybit.com"}
  #   Nested: %{"public" => %{"spot" => "https://api.gateio.ws/api/v4", ...}}
  #   Keyed:  %{"spot" => %{"public" => "https://api.mexc.com", ...}}
  defp default_base_url(exchange) do
    urls = exchange.base_urls

    # This picks the first URL found via recursive scan — good enough for connectivity, not for routing.
    cond do
      is_binary(urls["public"]) -> urls["public"]
      is_binary(urls["rest"]) -> urls["rest"]
      is_map(urls["public"]) -> find_flat_url(urls["public"])
      is_map(urls["spot"]) -> find_flat_url(urls["spot"])
      true -> find_flat_url(urls)
    end ||
      ""
  end

  defp find_flat_url(urls) when is_map(urls) do
    Enum.find_value(urls, fn
      {_key, value} when is_binary(value) -> value
      _ -> nil
    end)
  end

  # ===========================================================================
  # Base Client Caching
  # ===========================================================================

  defp get_base_client do
    case :persistent_term.get(@base_client_key, nil) do
      nil ->
        client = build_base_client()
        :persistent_term.put(@base_client_key, client)
        client

      client ->
        client
    end
  end

  defp build_base_client do
    Req.new(
      decode_body: true,
      compressed: true,
      retry: false
    )
  end

  # ===========================================================================
  # Telemetry
  # ===========================================================================

  defp emit_start(exchange_id, method, path) do
    :telemetry.execute(
      Bourse.Telemetry.request_start(),
      %{system_time: System.system_time()},
      %{exchange: exchange_id, method: method, path: path}
    )
  end

  defp emit_stop(exchange_id, method, path, status, start_time) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      Bourse.Telemetry.request_stop(),
      %{duration: duration},
      %{exchange: exchange_id, method: method, path: path, status: status}
    )
  end

  defp emit_exception(exchange_id, method, path, kind, reason, start_time) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      Bourse.Telemetry.request_exception(),
      %{duration: duration},
      %{exchange: exchange_id, method: method, path: path, kind: kind, reason: reason}
    )
  end

  # ===========================================================================
  # Circuit Breaker
  # ===========================================================================

  # Wraps CircuitBreaker.check/1 to return {:error, _} for use in `with` chains
  defp check_circuit_breaker(%Exchange{id: exchange_id}) do
    case CircuitBreaker.check(exchange_id) do
      :ok -> :ok
      :blown -> {:error, Error.circuit_open(exchange: exchange_id)}
    end
  end
end
