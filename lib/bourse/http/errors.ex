defmodule Bourse.HTTP.Errors do
  @moduledoc """
  Classifies HTTP and body-level exchange responses into `Bourse.Error` structs.

  Extracted from `Bourse.HTTP` so the transport layer can stay focused on request
  execution while error taxonomy (status maps, body sentinels, HTML/geo-block
  detection) lives in one place. Behavior-preserving delegation only — the
  public HTTP API is unchanged.
  """

  alias Bourse.Error
  alias Bourse.Exchange

  @html_preview_length 200

  @typedoc "HTTP response headers as returned by Req"
  @type response_headers :: %{optional(String.t()) => [String.t()]}

  @typedoc "Normalized success response map"
  @type response :: %{status: integer(), headers: response_headers(), body: term()}

  @doc """
  Classifies an HTTP response into `{:ok, response}` or `{:error, Error.t()}`.

  Handles 2xx body-level errors, non-2xx status normalization, HTML/geo-block
  and Cloudflare challenge detection. Empty 2xx bodies are successful responses.
  """
  @spec classify_response(atom(), integer(), response_headers(), term(), Exchange.t()) ::
          {:ok, response()} | {:error, Error.t()}
  def classify_response(method, status, headers, body, exchange) when status >= 200 and status < 300 do
    case detect_html_response(body, headers) do
      {:html, context} -> {:error, classify_html_response(status, context, exchange.id)}
      :not_html -> handle_success_body(method, status, headers, body, exchange)
    end
  end

  def classify_response(_method, status, headers, body, exchange) do
    case detect_html_response(body, headers) do
      {:html, context} ->
        {:error, classify_html_response(status, context, exchange.id)}

      :not_html ->
        # Decode JSON on error statuses too — some venues return application/json
        # bodies as binary (text/plain) and non-2xx previously skipped decoding,
        # leaving code: nil and the raw JSON string as message (task 255 / OKX 51000).
        decoded_body = ensure_json_decoded(body)
        {:error, normalize_error(status, decoded_body, exchange)}
    end
  end

  # ===========================================================================
  # Success-body handling
  # ===========================================================================

  # Empty 2xx bodies are success. OKX and others legitimately
  # answer HTTP 200 with an empty body on some private POSTs; treating them as
  # network_error was wrong (task 255).
  defp handle_success_body(_method, status, headers, body, exchange) do
    decoded_body = ensure_json_decoded(body)

    case check_body_error(decoded_body, exchange) do
      nil -> {:ok, %{status: status, headers: headers, body: decoded_body}}
      error -> {:error, error}
    end
  end

  # ===========================================================================
  # HTML Response Detection
  # ===========================================================================

  defp detect_html_response(body, headers) when is_binary(body) do
    content_type = get_content_type(headers)

    cond do
      String.contains?(content_type, "text/html") -> {:html, extract_html_context(body)}
      html_body?(body) -> {:html, extract_html_context(body)}
      true -> :not_html
    end
  end

  defp detect_html_response(_body, _headers), do: :not_html

  # ===========================================================================
  # JSON Decoding Fallback
  # ===========================================================================

  # Some exchanges return JSON with Content-Type: text/plain
  defp ensure_json_decoded(body) when is_map(body) or is_list(body), do: body

  defp ensure_json_decoded(body) when is_binary(body) do
    trimmed = String.trim_leading(body)

    if String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") do
      case Jason.decode(body) do
        {:ok, decoded} -> decoded
        {:error, _} -> body
      end
    else
      body
    end
  end

  defp ensure_json_decoded(body), do: body

  # ===========================================================================
  # Body-Level Error Detection
  #
  # Many exchanges return HTTP 200 with error information in the body.
  # Sentinel-aware spec checks run first, then we fall back to the historical
  # exact-code probe for exchanges that still use simple top-level error codes.
  # ===========================================================================

  defp check_body_error(body, exchange) when is_map(body) do
    case detect_body_error(body, exchange) do
      {:error, code} ->
        message = extract_message(body)

        error_type =
          Map.get(exchange.error_codes, to_string(code)) ||
            match_broad_error(message, exchange.broad_error_patterns)

        # Retain the full body (incl. OKX batch data[].sCode/sMsg) on body-level errors.
        build_typed_error(error_type, message, code, exchange.id, body)

      :ok ->
        nil
    end
  end

  defp check_body_error(_body, _exchange), do: nil

  defp detect_body_error(body, exchange) do
    cond do
      jsonrpc_error?(body) ->
        {:error, nested_error_code(body) || "jsonrpc_error"}

      jsonrpc_success?(body) ->
        :ok

      true ->
        case evaluate_status_sentinels(body, exchange) do
          :success -> :ok
          {:error, code} -> {:error, code}
          :unknown -> detect_error_from_code_fields(body, exchange)
        end
    end
  end

  # JSON-RPC: error member present signals failure (even with result).
  defp jsonrpc_error?(%{"jsonrpc" => _, "error" => e}) when not is_nil(e), do: true
  defp jsonrpc_error?(_), do: false

  # JSON-RPC success: "result" present and no "error" member (deribit etc).
  # Failure is signalled by an "error" object; result-without-error is success.
  defp jsonrpc_success?(%{"jsonrpc" => _, "result" => _} = b), do: not Map.has_key?(b, "error") or is_nil(b["error"])
  defp jsonrpc_success?(_), do: false

  defp detect_error_from_code_fields(body, exchange) do
    code = extract_error_code(body, exchange.error_code_fields)
    if not is_nil(code) and error_code?(code), do: {:error, code}, else: :ok
  end

  # Code is an error when it's a non-zero, non-"OK" string or integer.
  # 200 is a success code for some venues (e.g. lighter uses code:200 for OK).
  defp error_code?(200), do: false
  defp error_code?("200"), do: false
  defp error_code?(code) when is_integer(code), do: code != 0
  defp error_code?(code) when is_binary(code), do: code != "0" and code != "OK"
  defp error_code?(_), do: false

  # Sentinel-bearing checks let us suppress false positives from exchanges whose
  # success values are not "0"/"OK" (e.g. KuCoin "200000", Bithumb "0000").
  # We keep scanning on error candidates so a later exact-code field can win.
  defp evaluate_status_sentinels(body, exchange) do
    exchange.error_body_checks
    |> Enum.filter(&(:status_sentinel in &1.roles))
    |> Enum.reduce_while(:unknown, &reduce_sentinel_check(&1, &2, body, exchange))
  end

  defp reduce_sentinel_check(check, best, body, exchange) do
    case extract_check_value(body, check) do
      nil -> {:cont, best}
      value -> accumulate_sentinel_result(value, check, best, exchange.error_codes)
    end
  end

  defp accumulate_sentinel_result(value, check, best, error_codes) do
    case evaluate_sentinel_value(value, check, error_codes) do
      :success -> {:halt, :success}
      {:error, _code} = candidate -> {:cont, prefer_error_candidate(candidate, best, error_codes)}
      :unknown -> {:cont, best}
    end
  end

  defp evaluate_sentinel_value(value, check, error_codes) do
    case comparable_value(value) do
      nil -> :unknown
      comparable -> classify_sentinel(value, comparable, check, error_codes)
    end
  end

  defp classify_sentinel(value, comparable, check, error_codes) do
    ctx = %{
      value: value,
      comparable: comparable,
      eq_vals: sentinel_values(check, "==="),
      neq_vals: sentinel_values(check, "!=="),
      has_code_role: :error_code in check.roles,
      known_error?: not is_nil(lookup_error_type(comparable, error_codes))
    }

    classify_by_success(ctx)
  end

  # Success first: an inequality match or a role-gated equality match with no known error code wins.
  defp classify_by_success(%{neq_vals: [_ | _] = vals, comparable: c} = ctx) when is_binary(c) do
    if c in vals, do: :success, else: classify_by_eq_success(ctx)
  end

  defp classify_by_success(ctx), do: classify_by_eq_success(ctx)

  defp classify_by_eq_success(%{eq_vals: [_ | _] = vals, comparable: c, has_code_role: true, known_error?: false} = ctx) do
    if c in vals, do: :success, else: classify_by_error(ctx)
  end

  # Sentinel-only entries have no role inversion: a === match IS the error
  # indicator. (Code-bearing entries above invert — there the eq_val is a
  # success code that suppresses the default `error_code?` heuristic.)
  defp classify_by_eq_success(%{eq_vals: [_ | _] = vals, comparable: c, has_code_role: false, value: value} = ctx) do
    if c in vals, do: {:error, value}, else: classify_by_error(ctx)
  end

  defp classify_by_eq_success(ctx), do: classify_by_error(ctx)

  # No success match: any configured sentinel means the value is an error.
  defp classify_by_error(%{neq_vals: [_ | _], value: value}), do: {:error, value}
  defp classify_by_error(%{eq_vals: [_ | _], has_code_role: true, value: value}), do: {:error, value}
  defp classify_by_error(_ctx), do: :unknown

  defp sentinel_values(check, operator) do
    check.sentinel_values
    |> Enum.filter(&(&1.operator == operator))
    |> Enum.map(& &1.value)
  end

  defp prefer_error_candidate(candidate, :unknown, _error_codes), do: candidate

  defp prefer_error_candidate({:error, new_code} = candidate, {:error, current_code}, error_codes) do
    if is_nil(lookup_error_type(current_code, error_codes)) and
         not is_nil(lookup_error_type(new_code, error_codes)) do
      candidate
    else
      {:error, current_code}
    end
  end

  defp comparable_value(value) when is_binary(value), do: value
  defp comparable_value(value) when is_integer(value), do: Integer.to_string(value)
  defp comparable_value(value) when is_atom(value), do: Atom.to_string(value)
  defp comparable_value(_), do: nil

  # Tries nested error.code (map only — scalar "error" strings must not crash Access)
  # then exchange-configured error code field names in priority order.
  defp extract_error_code(body, fields) do
    nested_error_code(body) || Enum.find_value(fields, &extract_field_value(body, &1))
  end

  # Gateway envelopes use a scalar top-level "error" (e.g. "Not Found"). Digging
  # with get_in(body, ["error", "code"]) raises FunctionClauseError in Access.get/3.
  defp nested_error_code(%{"error" => error}) when is_map(error), do: Map.get(error, "code")
  defp nested_error_code(_body), do: nil

  defp extract_check_value(body, %{field: field, field2: field2}) do
    case extract_field_value(body, field) do
      nil -> extract_field_value(body, field2)
      value -> value
    end
  end

  defp extract_field_value(body, field) when is_map(body) and is_binary(field) do
    Map.get(body, field)
  end

  defp extract_field_value(_body, _field), do: nil

  # ===========================================================================
  # HTTP Status Error Normalization
  # ===========================================================================

  defp normalize_error(429, body, exchange) do
    retry_after = extract_retry_after(body)

    [message: extract_message(body), retry_after: retry_after, exchange: exchange.id, raw: body]
    |> Error.rate_limit_exceeded()
    |> with_http_status(429)
  end

  # The auth status short-circuits type classification, but the venue's own error
  # code still travels in the body (OKX answers HTTP 401 with code "50120"). Keep
  # it on the struct — dropping it left callers with code: nil and forced them to
  # dig through `raw`, the same defect task 255 fixed for other non-2xx statuses.
  defp normalize_error(status, body, exchange) when status in [401, 403] do
    [
      message: extract_message(body),
      code: extract_error_code(body, exchange.error_code_fields),
      exchange: exchange.id,
      raw: body
    ]
    |> Error.authentication_error()
    |> with_http_status(status)
  end

  defp normalize_error(status, body, exchange) when is_map(body) do
    code =
      case evaluate_status_sentinels(body, exchange) do
        {:error, sentinel_code} -> sentinel_code
        _ -> extract_error_code(body, exchange.error_code_fields)
      end

    message = extract_message(body)

    # Try: handler predicate → exact error code → broad message substring → HTTP status mapping.
    # Phase 13 errors.status_map is preferred over the legacy describe.httpExceptions.
    error_type =
      match_error_handler(status, body, exchange.error_handler_checks) ||
        lookup_error_type(code, exchange.error_codes) ||
        match_broad_error(message, exchange.broad_error_patterns) ||
        Map.get(exchange.status_map, to_string(status)) ||
        Map.get(exchange.http_exceptions, to_string(status))

    error_type
    |> build_typed_error(message, code || status, exchange.id, body)
    |> with_http_status(status)
  end

  # Non-JSON error bodies (e.g. plain "Method Not Allowed") retain text as message + raw.
  defp normalize_error(status, body, exchange) do
    body
    |> extract_message()
    |> Error.exchange_error(exchange: exchange.id, raw: body)
    |> with_http_status(status)
  end

  defp with_http_status(%Error{} = err, status), do: %{err | http_status: status}

  # ===========================================================================
  # Error Building Helpers
  # ===========================================================================

  defp lookup_error_type(nil, _error_codes), do: nil

  defp lookup_error_type(code, error_codes) do
    Map.get(error_codes, code) || Map.get(error_codes, to_string(code))
  end

  defp match_error_handler(status, body, checks) when is_list(checks) do
    body_text = body_search_text(body)

    Enum.find_value(checks, fn check ->
      if status_guard_matches?(status, check.status_guard) and body_contains_matches?(body_text, check.body_contains) do
        check.error_type
      end
    end)
  end

  defp match_error_handler(_status, _body, _checks), do: nil

  defp status_guard_matches?(status, {:gte, min_status}), do: status >= min_status
  defp status_guard_matches?(status, {:in, statuses}), do: status in statuses
  defp status_guard_matches?(_status, _guard), do: false

  defp body_contains_matches?(body_text, values) when is_binary(body_text) and is_list(values) do
    Enum.any?(values, &String.contains?(body_text, &1))
  end

  defp body_contains_matches?(_body_text, _values), do: false

  defp body_search_text(body) when is_map(body) do
    extract_message(body) <> " " <> inspect(body)
  end

  # Matches error message against broad exception patterns (substring matching).
  # Broad patterns are keyed by message substrings, e.g. "Insufficient balance!" => :insufficient_funds.
  defp match_broad_error(message, broad_patterns) when is_binary(message) and map_size(broad_patterns) > 0 do
    Enum.find_value(broad_patterns, fn {pattern, error_type} ->
      if String.contains?(message, pattern), do: error_type
    end)
  end

  defp match_broad_error(_message, _broad_patterns), do: nil

  @known_error_types MapSet.new([
                       :rate_limit_exceeded,
                       :authentication_error,
                       :invalid_nonce,
                       :insufficient_funds,
                       :invalid_order,
                       :order_not_found,
                       :bad_request,
                       :bad_symbol,
                       :permission_denied,
                       :exchange_not_available,
                       :operation_failed,
                       :not_supported,
                       :access_restricted,
                       :cloudflare_challenge,
                       :network_error
                     ])

  # Dispatches to the matching Error factory function, or falls back to exchange_error.
  # `raw` keeps the full response body so batch per-item detail is not dropped.
  defp build_typed_error(type, message, code, exchange_id, raw) do
    opts = [message: message, code: code, exchange: exchange_id, raw: raw]

    if type in @known_error_types do
      apply(Error, type, [opts])
    else
      Error.exchange_error(message, opts)
    end
  end

  # ===========================================================================
  # Message Extraction
  # ===========================================================================

  # Safely extracts error message from response body, handling various formats
  defp extract_message(body) when is_map(body) do
    case body["message"] || body["msg"] || body["retMsg"] || body["error"] || body["response"] ||
           body["status"] do
      nil -> "Unknown error"
      msg when is_binary(msg) -> msg
      msg -> inspect(msg)
    end
  end

  defp extract_message(body) when is_binary(body), do: body
  defp extract_message(_), do: "Unknown error"

  # ===========================================================================
  # Retry-After Extraction
  # ===========================================================================

  # Extracts retry-after from response body (some exchanges include it there)
  # Also extract from Retry-After header when headers are available
  defp extract_retry_after(body) when is_map(body) do
    case body["retry_after"] || body["retryAfter"] do
      seconds when is_integer(seconds) -> seconds * 1000
      _ -> nil
    end
  end

  defp extract_retry_after(_), do: nil

  # ===========================================================================
  # HTML Detection Helpers
  # ===========================================================================

  defp html_body?(body) do
    trimmed = String.trim_leading(body)

    String.starts_with?(trimmed, "<!DOCTYPE") or
      String.starts_with?(trimmed, "<html") or
      String.starts_with?(trimmed, "<HTML") or
      String.starts_with?(trimmed, "<!doctype")
  end

  defp extract_html_context(body) do
    %{
      page_title: extract_html_title(body),
      body_preview: String.slice(body, 0, @html_preview_length)
    }
  end

  defp extract_html_title(html) do
    case Regex.run(~r/<title[^>]*>([^<]+)<\/title>/i, html) do
      [_, title] -> String.trim(title)
      _ -> nil
    end
  end

  defp get_content_type(headers) when is_map(headers) do
    case Map.get(headers, "content-type") do
      [value | _] -> String.downcase(value)
      _ -> ""
    end
  end

  # Conservative Cloudflare-challenge markers. Anything NOT matching these stays
  # classified as :access_restricted so genuine URL/prefix bugs keep flunking in
  # integration probes. Extend this list as new CF variants surface.
  @cloudflare_title_patterns [~r/just a moment/i, ~r/attention required/i]
  @cloudflare_body_markers ["cf-chl-bypass", "challenge-platform", "cf-browser-verification"]

  defp classify_html_response(status, context, exchange_id) do
    page_title = context[:page_title]
    preview = context[:body_preview]
    raw = %{status: status, page_title: page_title, body_preview: preview}

    cond do
      cloudflare_challenge?(page_title, preview) ->
        Error.cloudflare_challenge(
          message: cloudflare_message(page_title),
          code: status,
          exchange: exchange_id,
          raw: raw,
          hints: [
            "Cloudflare challenge detected — exchange is reachable but requires browser/approved client",
            "Running from an approved IP or using a CF-friendly HTTP client path may help"
          ]
        )

      # Some venues reject bad credentials at the edge proxy with an HTML body
      # and no JSON error envelope (Alpaca's nginx 401). The status carries the
      # semantics: 401 is a credential rejection, not a geo/IP block.
      status == 401 ->
        Error.authentication_error(
          message: authentication_error_message(page_title),
          code: status,
          exchange: exchange_id,
          raw: raw,
          hints: [
            "Check API key/secret — the venue rejected the request before its JSON API layer",
            "The HTML body preview is in raw.body_preview"
          ]
        )

      true ->
        Error.access_restricted(
          message: access_restricted_message(page_title),
          code: status,
          exchange: exchange_id,
          raw: raw,
          hints: [
            "Verify the API URL is correct",
            "Could be geographic/IP blocking - try VPN if curl works"
          ]
        )
    end
  end

  defp cloudflare_challenge?(page_title, preview) do
    title_match?(page_title) or body_match?(preview)
  end

  defp title_match?(nil), do: false

  defp title_match?(title) when is_binary(title) do
    Enum.any?(@cloudflare_title_patterns, &Regex.match?(&1, title))
  end

  defp body_match?(nil), do: false

  defp body_match?(preview) when is_binary(preview) do
    Enum.any?(@cloudflare_body_markers, &String.contains?(preview, &1))
  end

  defp cloudflare_message(nil), do: "Cloudflare challenge page received instead of JSON API response"

  defp cloudflare_message(title), do: "Cloudflare challenge page '#{title}' received instead of JSON API response"

  defp access_restricted_message(nil), do: "Received HTML instead of JSON API response"

  defp access_restricted_message(title), do: "Received HTML page '#{title}' instead of JSON API response"

  defp authentication_error_message(nil), do: "HTTP 401 with HTML body — credentials rejected before the JSON API layer"

  defp authentication_error_message(title) do
    "HTTP 401 with HTML page '#{title}' — credentials rejected before the JSON API layer"
  end
end
