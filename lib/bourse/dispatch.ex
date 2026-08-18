defmodule Bourse.Dispatch do
  @moduledoc """
  Shared request dispatcher for generated exchange endpoint functions.

  All generated endpoint functions delegate to `call/4`, which handles:

  1. **Path interpolation** — replaces `{param}` templates with values from params
  2. **Base URL resolution** — a caller-supplied `:base_url` opt wins; otherwise
     navigates `exchange.base_urls` using endpoint sections
  3. **Signing** — authenticates private endpoint requests via `Bourse.Signing.sign/4`
  4. **HTTP delegation** — calls `Bourse.HTTP.request/4` or `Bourse.HTTP.signed_request/5`

  ## Future phases

  - **Phase 5**: Response parsing (field mapping to unified structs)
  - **Task 17**: Symbol denormalization (unified → exchange-specific format)
  """

  alias Bourse.Error
  alias Bourse.Exchange
  alias Bourse.HTTP
  alias Bourse.ResponseTransformer
  alias Bourse.Signing
  alias Bourse.Signing.Request
  alias Bourse.Signing.SignedRequest
  alias Bourse.Timestamp

  require Logger

  @dispatch_control_opts [:timestamp_ms_override, :nonce_override]
  @content_type_header "content-type"

  @typedoc "Compile-time endpoint configuration from spec"
  @type endpoint_config :: %{
          required(:name) => atom(),
          required(:method) => atom(),
          required(:path) => String.t(),
          required(:sections) => [String.t()],
          required(:weight) => number(),
          optional(:url_prefix) => String.t(),
          optional(:authenticated) => boolean(),
          optional(:rate_limit) => map(),
          optional(:response_transformer) => ResponseTransformer.transformer()
        }

  @doc """
  Dispatches a request to an exchange endpoint.

  Resolves the base URL from the endpoint's sections, interpolates path
  templates, and delegates to `Bourse.HTTP.request/4`.

  A caller-supplied `:base_url` opt takes precedence over `resolve_base_url/2`
  on both the public and the signed path — the override reaches the wire. For
  host-signing venues, the signing config receives the host parsed from that
  effective base URL so the signature covers the same host the request uses.

  ## Parameters

  - `exchange` — `%Bourse.Exchange{}` runtime configuration
  - `endpoint_config` — compile-time endpoint map with `:name`, `:method`, `:path`, `:sections`, `:weight`
  - `params` — request parameters (query for GET/HEAD/DELETE, body for POST/PUT/PATCH)
  - `opts` — passed through to `Bourse.HTTP.request/4` (`:base_url`, `:timeout`, `:headers`, etc.)

  ## Examples

      config = %{name: :public_get_v5_market_tickers, method: :get,
        path: "v5/market/tickers", sections: ["public"], weight: 5}

      Bourse.Dispatch.call(exchange, config, %{"category" => "spot"})

  """
  @spec call(Exchange.t(), endpoint_config(), map() | [map()], keyword()) ::
          {:ok, HTTP.response()} | {:error, Error.t()}
  def call(%Exchange{} = exchange, %{} = endpoint_config, params \\ %{}, opts \\ []) do
    validate_raw_endpoint_params!(params)
    endpoint_config = apply_request_contract(exchange, endpoint_config)
    %{method: method, path: path_template, sections: sections} = endpoint_config

    {path, remaining_params} = interpolate_path(path_template, params, Map.get(endpoint_config, :path_params))

    with {:ok, base_url} <- effective_base_url(opts, sections, exchange) do
      url_prefix = Map.get(endpoint_config, :url_prefix, "/")
      weight = Map.get(endpoint_config, :weight, 1)
      rate_limit = Map.get(endpoint_config, :rate_limit, weight)
      http_opts = Keyword.drop(opts, @dispatch_control_opts)

      result =
        if Map.get(endpoint_config, :authenticated, false) do
          request_context = %{
            method: method,
            path: url_prefix <> path,
            params: remaining_params,
            base_url: base_url,
            opts: http_opts,
            weight: weight,
            rate_limit: rate_limit,
            endpoint_config: endpoint_config,
            original_opts: opts
          }

          sign_and_request(exchange, request_context)
        else
          http_opts =
            Keyword.merge(http_opts,
              base_url: base_url,
              params: remaining_params,
              body_encoding: Map.get(endpoint_config, :body_encoding),
              endpoint_weight: weight,
              endpoint_rate_limit: rate_limit
            )

          HTTP.request(exchange, method, url_prefix <> path, http_opts)
        end

      maybe_transform_response(result, Map.get(endpoint_config, :response_transformer))
    end
  end

  # `[]` is an empty list body (a valid `[map()]`), not misuse — `Keyword.keyword?/1`
  # says `true` for it, so it must be excluded before the keyword check.
  defp validate_raw_endpoint_params!([]), do: :ok

  defp validate_raw_endpoint_params!(params) when is_list(params) do
    if Keyword.keyword?(params) do
      raise ArgumentError,
            "expected raw endpoint arguments: (exchange, params_map, opts); " <>
              "received a keyword list in the params position"
    end

    :ok
  end

  defp validate_raw_endpoint_params!(_params), do: :ok

  # ---------------------------------------------------------------------------
  # Response Shape Normalization
  #
  # Applied between the HTTP response and the parser. When an endpoint config
  # carries a `:response_transformer`, the raw response body is reshaped into the
  # form the unified parsers expect (e.g. BitMEX's flat order list → order book).
  # Envelope key extraction is primarily spec-derived via
  # `normalization.response_envelopes`; this seam covers wire-shape transforms
  # that an envelope key path cannot express. See `Bourse.ResponseTransformer`.
  # ---------------------------------------------------------------------------

  # No transformer configured (or an error tuple) — pass through untouched.
  defp maybe_transform_response({:ok, %{body: body} = response}, transformer) when not is_nil(transformer) do
    {:ok, %{response | body: ResponseTransformer.transform(body, transformer)}}
  end

  defp maybe_transform_response(result, _transformer), do: result

  # Caller `:base_url` wins. Otherwise section navigation must resolve a host
  # for *this* section — never fall through to an unrelated sibling host.
  defp effective_base_url(opts, sections, %Exchange{} = exchange) do
    case Keyword.get(opts, :base_url) do
      url when is_binary(url) and url != "" ->
        {:ok, url}

      _ ->
        case resolve_base_url(sections, exchange.base_urls) do
          url when is_binary(url) and url != "" ->
            {:ok, url}

          _unresolved ->
            {:error, unresolved_base_url_error(exchange, sections)}
        end
    end
  end

  defp unresolved_base_url_error(%Exchange{id: id, sandbox: sandbox}, sections) do
    env = if sandbox, do: "sandbox", else: "mainnet"

    section_label =
      case sections do
        [] -> "(empty)"
        list when is_list(list) -> Enum.join(list, "/")
      end

    Error.not_supported(
      exchange: id,
      message: "No base URL for section #{section_label} on #{id} (#{env})"
    )
  end

  # ---------------------------------------------------------------------------
  # Signing Integration
  #
  # Private endpoints are signed via Bourse.Signing.sign/4 before HTTP execution.
  # Visibility is spec-driven via `structure.authenticated_sections` (schema 1.7.1+),
  # materialized onto each endpoint config as `:authenticated` at build time.
  # Signing pattern/config come from explicit fields in the owned runtime spec.
  # ---------------------------------------------------------------------------

  # Validates credentials and signing pattern, signs the request, delegates to HTTP.
  defp sign_and_request(exchange, request_context) do
    %{
      method: method,
      path: path,
      params: params,
      base_url: base_url,
      opts: opts,
      weight: weight,
      rate_limit: rate_limit,
      endpoint_config: endpoint_config,
      original_opts: original_opts
    } = request_context

    with {:ok, credentials} <- require_credentials(exchange),
         {:ok, {pattern, config}} <- require_signing_pattern(exchange) do
      {signing_params, body} = prepare_signed_payload(method, params, endpoint_config)

      base_signing_config =
        config
        |> effective_signing_config(base_url, exchange.sandbox)
        |> Map.put(:exchange_options, exchange.options)
        |> Map.put_new(:exchange, exchange.id)

      signing_request = %Request{
        method: method,
        path: path,
        body: body,
        params: signing_params
      }

      signer = fn ->
        config = Map.merge(base_signing_config, signing_overrides(endpoint_config, original_opts))
        sign_request(pattern, signing_request, credentials, config, endpoint_config, exchange.id)
      end

      case signer.() do
        {:error, %Error{}} = error ->
          error

        signed ->
          opts =
            opts
            |> Keyword.put(:endpoint_weight, weight)
            |> Keyword.put(:endpoint_rate_limit, rate_limit)

          HTTP.signed_request(exchange, signed, base_url, signer, opts)
      end
    end
  end

  defp sign_request(pattern, request, credentials, config, endpoint_config, exchange_id) do
    case Signing.sign(pattern, request, credentials, config) do
      {:error, {:unsupported_signing, signer_exchange_id}} ->
        unsupported_signing_error(signer_exchange_id || exchange_id)

      {:error, reason} ->
        {:error,
         Error.authentication_error(
           exchange: exchange_id,
           message: "Request signing failed: #{signing_failure_reason(reason)}"
         )}

      signed ->
        apply_content_type_contract(signed, endpoint_config)
    end
  end

  # Signer failures carry fixed atom pairs, never key material, so naming them
  # tells an operator whether to build the helper, fix credentials, or retry.
  defp signing_failure_reason({:lighter_signing, :helper_unavailable}) do
    "lighter_signing/helper_unavailable; run mix ccxt.build_lighter_signer"
  end

  defp signing_failure_reason({family, reason}) when is_atom(family) and is_atom(reason) do
    "#{family}/#{reason}"
  end

  defp effective_signing_config(config, base_url, sandbox) when is_binary(base_url) do
    config = config |> Map.put(:testnet, sandbox) |> Map.put(:base_url, base_url)

    case URI.parse(base_url).host do
      host when is_binary(host) -> Map.put(config, :hostname, String.downcase(host))
      _no_host -> config
    end
  end

  defp unsupported_signing_error(exchange_id) do
    {:error,
     Error.authentication_error(
       message: "Unsupported signing pattern",
       exchange: exchange_id
     )}
  end

  defp require_credentials(%Exchange{credentials: nil, id: id}) do
    {:error,
     Error.authentication_error(
       message: "Credentials required for private endpoint",
       exchange: id
     )}
  end

  defp require_credentials(%Exchange{credentials: credentials}), do: {:ok, credentials}

  defp require_signing_pattern(%Exchange{signing_pattern: nil, id: id}) do
    {:error,
     Error.authentication_error(
       message: "No signing pattern configured for exchange",
       exchange: id
     )}
  end

  # signing_config should always be a map via Exchange.new/2 and the generator macro,
  # but manual struct construction can leave it nil. Consider raising here instead of defaulting.
  defp require_signing_pattern(%Exchange{signing_pattern: pattern, signing_config: config}) do
    {:ok, {pattern, config || %{}}}
  end

  # ---------------------------------------------------------------------------
  # Path Interpolation
  #
  # Replaces `{param}` placeholders in endpoint paths with values from the
  # params map. Consumed params are removed to avoid duplication as query/body.
  # Common pattern across supported venues (e.g., "orders/{id}", "{settle}/candlesticks").
  # ---------------------------------------------------------------------------

  @doc "Replaces `{param}` placeholders in path with values from params, returning remaining params."
  @spec interpolate_path(String.t(), map() | [map()]) :: {String.t(), map() | [map()]}
  def interpolate_path(path, params), do: interpolate_path(path, params, nil)

  @doc "Replaces the specified `{param}` placeholders in path with values from params."
  @spec interpolate_path(String.t(), map() | [map()], [String.t() | map()] | nil) ::
          {String.t(), map() | [map()]}
  # Root JSON-array bodies (OKX cancel-batch-orders / cancel-algos) have no path params.
  def interpolate_path(path, params, _path_params) when is_list(params), do: {path, params}

  def interpolate_path(path, params, _path_params) when map_size(params) == 0, do: {path, params}

  def interpolate_path(path, params, path_params) when is_list(path_params) do
    Enum.reduce(path_params, {path, params}, fn param, {current_path, current_params} ->
      interpolate_named_path_param(current_path, current_params, path_param_name(param))
    end)
  end

  def interpolate_path(path, params, _path_params) do
    # Fast path: no templates
    if String.contains?(path, "{") do
      do_interpolate(path, params, %{}, %{}, path)
    else
      {path, params}
    end
  end

  # Path-param entries arrive in two shapes: plain name strings (legacy), or
  # authored-spec request-contract descriptor maps `%{"name" => n, "source" => _}`
  # where the value is resolved from the params map under `n`. Normalize both to
  # the placeholder/lookup name so interpolation never sees a raw map.
  defp path_param_name(%{"name" => name, "source" => "params"}) when is_binary(name), do: name
  defp path_param_name(name) when is_binary(name), do: name

  # Invariant (verified 1668/1668 across the catalog, 2026-06-22): every authored
  # path_param descriptor sources from "params". A different source would make the
  # value resolve from the wrong place — fail loud the day it changes rather than
  # silently emit a wrong-source request. See CLAUDE.md § Dispatch.
  defp path_param_name(%{"name" => name, "source" => source}) do
    raise ArgumentError,
          "unsupported path_param source #{inspect(source)} for #{inspect(name)} — " <>
            "interpolate_path only resolves source: \"params\" (see CLAUDE.md § Dispatch)"
  end

  defp interpolate_named_path_param(path, params, param_name) do
    placeholder = "{#{param_name}}"

    if String.contains?(path, placeholder) do
      case lookup_param(params, param_name) do
        :not_found ->
          Logger.warning(
            "Bourse.Dispatch: path param '#{param_name}' missing for path '#{path}' — " <>
              "placeholder '#{placeholder}' preserved; exchange will likely return a descriptive error"
          )

          {path, params}

        nil ->
          raise ArgumentError,
                "path param '#{param_name}' is nil — pass a value or omit the key"

        value ->
          {String.replace(path, placeholder, to_string(value), global: false),
           remove_consumed(params, %{param_name => true})}
      end
    else
      {path, params}
    end
  end

  # Scans for {param} placeholders, replaces with param values, tracks consumed keys.
  # Missing path params are preserved as-is so the exchange returns a descriptive error.
  # Explicit nil values raise ArgumentError — nil is a caller bug, not "missing".
  # `original_path` is threaded through recursion so warnings always reference the full
  # input template, not a recursed suffix after `is_map_key(skipped, ...)` splits.
  # Note: Duplicate placeholders in one path (e.g., "{id}/copy/{id}") would leave the
  # second un-interpolated after the first consumes the param. No known spec does this.
  defp do_interpolate(path, params, consumed, skipped, original_path) do
    case Regex.run(~r/\{([\w-]+)\}/, path) do
      [_placeholder, param_name] when is_map_key(skipped, param_name) ->
        [before, rest] = String.split(path, "{#{param_name}}", parts: 2)
        {interpolated_rest, remaining} = do_interpolate(rest, params, consumed, skipped, original_path)
        {before <> "{#{param_name}}" <> interpolated_rest, remaining}

      [placeholder, param_name] ->
        case lookup_param(params, param_name) do
          :not_found ->
            Logger.warning(
              "Bourse.Dispatch: path param '#{param_name}' missing for path '#{original_path}' — " <>
                "placeholder '#{placeholder}' preserved; exchange will likely return a descriptive error"
            )

            # reach:disable-next-line suboptimal — skipped is is_map_key-tested in a guard; no MapSet in guards
            do_interpolate(path, params, consumed, Map.put(skipped, param_name, true), original_path)

          nil ->
            raise ArgumentError,
                  "path param '#{param_name}' is nil — pass a value or omit the key"

          value ->
            new_path = String.replace(path, placeholder, to_string(value), global: false)

            # reach:disable-next-line suboptimal — consumed is is_map_key-tested; map kept for guard use
            do_interpolate(new_path, params, Map.put(consumed, param_name, true), skipped, original_path)
        end

      nil ->
        remaining = remove_consumed(params, consumed)
        {path, remaining}
    end
  end

  # Looks up a param by string key, falling back to atom key.
  # Returns :not_found when the param is absent from the map.
  defp lookup_param(params, name) do
    case Map.fetch(params, name) do
      {:ok, value} ->
        value

      :error ->
        atom_key = String.to_existing_atom(name)

        case Map.fetch(params, atom_key) do
          {:ok, value} -> value
          :error -> :not_found
        end
    end
  rescue
    ArgumentError -> :not_found
  end

  # Removes consumed path params from the params map (handles both string and atom keys)
  defp remove_consumed(params, consumed) when map_size(consumed) == 0, do: params

  defp remove_consumed(params, consumed) do
    Map.reject(params, fn {key, _value} ->
      key_str = if is_atom(key), do: Atom.to_string(key), else: key
      is_map_key(consumed, key_str)
    end)
  end

  # ---------------------------------------------------------------------------
  # Base URL Resolution
  #
  # Navigates exchange.base_urls using the endpoint's sections list.
  # Handles four URL patterns across supported venues:
  #
  #   Flat:     %{"public" => "https://api.bybit.com"} — direct key lookup
  #   Distinct: %{"sapi" => "https://api.binance.com/sapi/v1"} — section IS the key
  #   Nested:   %{"public" => %{"delivery" => "https://..."}} — walk sections
  #   Mixed:    %{"spot" => "https://..."} — early-stop when string found
  #
  # Nested maps under a *matched* section still pick any string URL within that
  # section (Gate/MEXC). Cross-map fallback is only allowed when the entire map
  # collapses to a single unique URL (OKX/Deribit `rest`, flat same-host maps).
  # When multiple distinct hosts exist, a missing section returns nil so
  # `call/4` fails loudly instead of riding an arbitrary sibling host.
  # ---------------------------------------------------------------------------

  @doc """
  Navigates `base_urls` using endpoint sections to find the appropriate base URL.

  Returns a URL string when the section path resolves. If navigation misses, falls
  back only when the map has exactly one unique string URL (shared-host venues).
  When multiple distinct hosts exist and the section is absent, returns `nil`.
  """
  @spec resolve_base_url([String.t()], map()) :: String.t() | nil
  def resolve_base_url(sections, base_urls) do
    navigate_sections(sections, base_urls) || single_unique_url(base_urls)
  end

  # Walks sections into the URL map. Stops when a string (URL) is found.
  defp navigate_sections([], _urls), do: nil

  defp navigate_sections([section | rest], urls) when is_map(urls) do
    case Map.get(urls, section) do
      url when is_binary(url) -> url
      nested when is_map(nested) and rest != [] -> navigate_sections(rest, nested)
      # Matched section is a nested map with no further path: pick any URL *under
      # this section only* (nested Gate/MEXC shapes). Not a cross-section fallback.
      nested when is_map(nested) -> find_any_url(nested)
      nil -> navigate_sections(rest, urls)
    end
  end

  defp navigate_sections(_sections, _urls), do: nil

  # Within a matched nested section: first string URL under that map (recursive).
  defp find_any_url(urls) when is_map(urls) do
    Enum.find_value(urls, fn
      {_key, value} when is_binary(value) -> value
      {_key, value} when is_map(value) -> find_any_url(value)
      _ -> nil
    end)
  end

  # Safe only when every leaf URL is the same host string — then "wrong section"
  # cannot mean wrong host. Multiple distinct hosts make section routing load-bearing.
  defp single_unique_url(urls) when is_map(urls) do
    case collect_unique_urls(urls) do
      [only] -> only
      _many_or_none -> nil
    end
  end

  defp single_unique_url(_), do: nil

  defp collect_unique_urls(urls) when is_map(urls) do
    urls
    |> Enum.flat_map(fn
      {_key, value} when is_binary(value) -> [value]
      {_key, value} when is_map(value) -> collect_unique_urls(value)
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp apply_request_contract(%Exchange{request_contracts: request_contracts}, endpoint_config) do
    request_contracts
    |> Map.get(request_contract_key(endpoint_config), %{})
    |> Map.merge(endpoint_config, fn _key, spec_value, config_value ->
      if is_nil(spec_value), do: config_value, else: spec_value
    end)
  end

  defp request_contract_key(endpoint_config) do
    {endpoint_config.sections, endpoint_config.method, endpoint_config.path}
  end

  defp prepare_signed_payload(method, params, endpoint_config) do
    case Map.get(endpoint_config, :body_encoding) do
      "json" when method in [:post, :put, :patch] ->
        {%{}, Jason.encode!(params)}

      _ ->
        {params, nil}
    end
  end

  defp signing_overrides(endpoint_config, opts) do
    timestamp_ms_override = resolve_override(Keyword.get(opts, :timestamp_ms_override))
    nonce_override = resolve_override(Keyword.get(opts, :nonce_override))

    endpoint_config
    |> timestamp_config(timestamp_ms_override)
    |> maybe_put_override(:sign_recipe_section, sign_recipe_section(endpoint_config))
    |> maybe_put_override(:timestamp_ms_override, timestamp_ms_override)
    |> maybe_put_override(:nonce_override, nonce_override)
  end

  defp timestamp_config(%{timestamp_recipe: %{} = recipe}, timestamp_ms_override) do
    timestamp_ms = timestamp_ms_override || Signing.timestamp_ms()
    %{timestamp: format_timestamp(timestamp_ms, recipe)}
  end

  defp timestamp_config(_endpoint_config, _timestamp_ms_override), do: %{}

  defp resolve_override(fun) when is_function(fun, 0), do: fun.()
  defp resolve_override(value), do: value

  defp sign_recipe_section(endpoint_config) do
    case Map.get(endpoint_config, :sections, []) do
      [] -> nil
      sections -> Enum.join(sections, ".")
    end
  end

  defp maybe_put_override(config, _key, nil), do: config
  defp maybe_put_override(config, key, value), do: Map.put(config, key, value)

  defp format_timestamp(timestamp_ms, %{"source" => "timestamp_ms", "format" => "iso8601"}) do
    Timestamp.iso8601_from_ms(timestamp_ms)
  end

  defp format_timestamp(timestamp_ms, %{"source" => "timestamp_ms", "format" => "iso8601_seconds"}) do
    Timestamp.iso8601_seconds_from_ms(timestamp_ms)
  end

  defp format_timestamp(timestamp_ms, %{"source" => "timestamp_ms", "format" => "seconds"}) do
    timestamp_ms |> div(1000) |> to_string()
  end

  defp format_timestamp(timestamp_ms, %{"source" => "timestamp_ms"}), do: to_string(timestamp_ms)
  defp format_timestamp(timestamp_ms, %{"source" => "timestamp_sec"}), do: timestamp_ms |> div(1000) |> to_string()

  @spec apply_content_type_contract(SignedRequest.t(), map()) :: SignedRequest.t()
  defp apply_content_type_contract(%SignedRequest{} = signed, endpoint_config) do
    cond do
      content_type = Map.get(endpoint_config, :content_type) ->
        %{signed | headers: put_header(signed.headers, @content_type_header, content_type)}

      Map.get(endpoint_config, :body_encoding) == "none" or Map.has_key?(endpoint_config, :content_type) ->
        %{signed | headers: remove_header(signed.headers, @content_type_header)}

      true ->
        signed
    end
  end

  defp put_header(headers, name, value) do
    [{name, value} | remove_header(headers, name)]
  end

  defp remove_header(headers, name) do
    normalized = String.downcase(name)

    Enum.reject(headers, fn {header, _value} ->
      String.downcase(header) == normalized
    end)
  end
end
