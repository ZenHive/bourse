defmodule Bourse.Signing.HmacRecipe do
  @moduledoc """
  Generic HMAC signer driven by v4 `auth.sign_recipe` data.

  The executor reads canonical string components, crypto operation, signature
  placement, auth headers, nonce/timestamp formats, and pre-sign transforms
  from the complete owned runtime spec. It executes authored data and does not
  classify venues or select a long-tail fallback signer.
  """

  @behaviour Bourse.Signing.Behaviour

  alias Bourse.Credentials
  alias Bourse.Defaults
  alias Bourse.Signing
  alias Bourse.Signing.SignedRequest
  alias Bourse.Timestamp

  require Logger

  @json_content_type {"Content-Type", "application/json"}
  @form_content_type {"Content-Type", "application/x-www-form-urlencoded"}
  @default_query_encoder "urlencode"
  @default_query_key_order "insertion"

  @impl true
  @spec sign(Signing.request(), Credentials.t(), Signing.config()) ::
          Signing.signed_request() | {:error, {:unsupported_signing, term()}}
  def sign(request, credentials, %{sign_recipe: recipe} = config) do
    method = request.method |> Atom.to_string() |> String.upcase()
    recipe = select_section_recipe(recipe, Map.get(config, :sign_recipe_section))
    effective = resolve_effective_recipe(recipe, method, request.path)

    case effective do
      {:unsupported, exchange, reason} ->
        # branch_family present but no branch resolved — abstain loudly so a new
        # distill spec shape surfaces at the first signing attempt rather than
        # producing a silently-wrong signature.
        Logger.warning(
          "HmacRecipe: branch_family present but unresolved (#{reason}) for " <>
            "#{inspect(exchange)} path=#{request.path} — refusing to sign"
        )

        {:error, {:unsupported_signing, exchange}}

      {:unsupported, exchange} ->
        {:error, {:unsupported_signing, exchange}}

      eff_recipe ->
        timestamp = timestamp(eff_recipe, config)
        nonce = nonce(eff_recipe, config)
        recv_window = recv_window_ms(config)
        body = body(request, eff_recipe)
        params = maybe_inject_query_auth_params(request.params, credentials, eff_recipe, timestamp, recv_window)
        components = canonical_components(eff_recipe, method, request.path)
        query = query_string(params, components)

        stages =
          execute_stages(eff_recipe, %{
            params: params,
            body: body,
            timestamp: timestamp,
            method: method,
            path: request.path
          })

        context = %{
          body: body,
          credentials: credentials,
          method: method,
          nonce: nonce,
          params: params,
          path: request.path,
          query: query,
          timestamp: timestamp,
          recv_window: recv_window,
          stages: stages,
          hostname: Map.get(config, :hostname, "")
        }

        payload = canonical_payload(components, context)
        secret = prepare_secret(credentials, eff_recipe)
        signature = sign_payload(payload, secret, eff_recipe)
        placement = placement(eff_recipe, method)
        url = signed_url(request, query, signature, placement)
        signed_body = signed_body(body, params, signature, request.path, placement)
        headers = headers(credentials, timestamp, nonce, signature, eff_recipe, placement, recv_window)

        %SignedRequest{
          url: url,
          method: request.method,
          headers: maybe_add_content_type(headers, signed_body, eff_recipe, request.path, placement),
          body: signed_body
        }
    end
  end

  # Authored recipes may be keyed by an exact dotted section or its top-level
  # family. Resolve those two deterministic representations before treating
  # the supplied value as one recipe.
  defp select_section_recipe(recipes, section) when is_map(recipes) and is_binary(section) do
    top_level = section |> String.split(".", parts: 2) |> hd()

    cond do
      recipe_candidate?(recipes) -> recipes
      is_map_key(recipes, section) -> Map.fetch!(recipes, section)
      is_map_key(recipes, top_level) -> Map.fetch!(recipes, top_level)
      true -> recipes
    end
  end

  defp select_section_recipe(recipe, _section), do: recipe

  defp active_recipe(recipe, method, path) do
    if recipe_candidate?(recipe) and canonical_components_available?(recipe, method, path) do
      recipe
    else
      recipe
      |> nested_recipe_candidates()
      |> Enum.filter(fn {_trail, candidate} -> canonical_components_available?(candidate, method, path) end)
      |> Enum.sort_by(fn {trail, _candidate} -> {path_match_score(trail, path), length(trail)} end, :desc)
      |> case do
        [{_trail, candidate} | _rest] -> candidate
        [] -> recipe
      end
    end
  end

  defp nested_recipe_candidates(recipe) do
    recipe
    |> do_nested_recipe_candidates([])
    |> Enum.reject(fn {trail, candidate} -> trail == [] or candidate == recipe end)
  end

  defp do_nested_recipe_candidates(value, trail) when is_map(value) do
    candidates =
      if recipe_candidate?(value) do
        [{trail, value}]
      else
        []
      end

    nested =
      value
      |> Enum.reject(fn {key, _value} ->
        key in ["auth_headers", "canonical_string", "pre_sign_transforms", "branch_family"]
      end)
      # reach:disable-next-line suboptimal — trail is a tiny bounded recipe path; prepend+reverse not worth it
      |> Enum.flat_map(fn {key, nested_value} -> do_nested_recipe_candidates(nested_value, trail ++ [key]) end)

    candidates ++ nested
  end

  defp do_nested_recipe_candidates(_value, _trail), do: []

  defp recipe_candidate?(value) when is_map(value) do
    Map.has_key?(value, "canonical_string") and
      (Map.has_key?(value, "crypto_op") or Map.has_key?(value, "signature_placement"))
  end

  defp recipe_candidate?(_value), do: false

  defp canonical_components_available?(recipe, method, path) do
    match?(
      components when is_list(components) and components != [],
      canonical_components_for(recipe, method, path)
    )
  end

  defp path_match_score(trail, path) do
    normalized_path = String.downcase(path || "")

    Enum.count(trail, fn key ->
      key
      |> to_string()
      |> String.downcase()
      |> String.replace_suffix("private", "")
      |> String.replace_suffix("_private", "")
      |> case do
        "" -> false
        token -> String.contains?(normalized_path, token)
      end
    end)
  end

  defp timestamp(recipe, config) do
    case Map.get(config, :timestamp) do
      ts when is_binary(ts) ->
        ts

      _ ->
        case get_in(recipe, ["timestamp", "format"]) do
          "iso8601" -> Signing.timestamp_iso8601_from_config(config)
          "iso8601_seconds" -> timestamp_iso8601_seconds_from_config(config)
          _ -> config |> Signing.timestamp_ms_from_config() |> to_string()
        end
    end
  end

  defp timestamp_iso8601_seconds_from_config(config) do
    case Map.get(config, :timestamp) do
      ts when is_binary(ts) ->
        ts

      _ ->
        config
        |> Signing.timestamp_ms_from_config()
        |> Timestamp.iso8601_seconds_from_ms()
    end
  end

  defp recv_window_ms(%{recv_window: window}) when is_integer(window) and window > 0, do: window
  defp recv_window_ms(_config), do: Defaults.recv_window_ms()

  defp nonce(recipe, config) do
    case get_in(recipe, ["nonce", "source"]) do
      nil ->
        nil

      _source ->
        config
        |> Signing.nonce_from_config(fn -> System.system_time(:microsecond) end)
        |> to_string()
    end
  end

  defp body(%{body: body}, _recipe) when is_binary(body), do: body

  defp body(%{method: method, params: params}, recipe) when method not in [:get, :delete] and params != %{} do
    if body_json?(recipe), do: Jason.encode!(params)
  end

  defp body(_request, _recipe), do: nil

  defp canonical_payload(components, context) do
    components
    |> dedupe_first_matching_body_component()
    |> Enum.map(&component_value(&1, context))
    |> :erlang.iolist_to_binary()
  end

  defp dedupe_first_matching_body_component(components) do
    {filtered, _} =
      Enum.reduce(components, {[], false}, fn component, {acc, body_seen?} ->
        if component["source"] == "body" and body_seen? do
          {acc, true}
        else
          {[component | acc], body_seen? or component["source"] == "body"}
        end
      end)

    Enum.reverse(filtered)
  end

  defp canonical_components(recipe, method, path) do
    case canonical_components_for(recipe, method, path) do
      list when is_list(list) and list != [] ->
        list

      _ ->
        # fallback: some recipes declare only for POST etc; tests use GET dummy paths
        unfiltered = get_unfiltered_components(recipe, method)

        if is_list(unfiltered) and unfiltered != [],
          do: unfiltered,
          else: raise(ArgumentError, "sign_recipe missing canonical_string components for #{method}")
    end
  end

  defp get_unfiltered_components(recipe, method) do
    cs =
      get_in(recipe, ["canonical_string"]) ||
        get_in(recipe, ["private", "canonical_string"]) || %{}

    block = cs[method] || cs["*"] || cs |> Map.values() |> List.first() || cs
    if is_map(block), do: Map.get(block, "components")
  end

  defp canonical_components_for(recipe, method, path) do
    cs =
      get_in(recipe, ["canonical_string"]) ||
        get_in(recipe, ["private", "canonical_string"]) || %{}

    block = cs[method] || cs["*"] || cs |> Map.values() |> List.first() || cs
    components = if is_map(block), do: Map.get(block, "components")

    if is_list(components), do: Enum.filter(components, &component_included?(&1, method, path))
  end

  defp component_included?(component, method, path) do
    method_allowed?(component, method) and
      path_predicate?("path_equals", component, path, &Kernel.==/2) and
      path_predicate?("unless_path_equals", component, path, fn candidate, expected -> candidate != expected end) and
      path_predicate?("path_contains", component, path, &String.contains?/2) and
      path_predicate?("unless_path_contains", component, path, fn haystack, needle ->
        not String.contains?(haystack, needle)
      end)
  end

  defp method_allowed?(%{"methods" => methods}, method) when is_list(methods) do
    method in methods
  end

  defp method_allowed?(_component, _method), do: true

  defp path_predicate?(key, component, path, matcher) do
    case Map.get(component, key) do
      nil -> true
      needle when is_binary(needle) -> matcher.(path, needle)
      _ -> true
    end
  end

  defp query_string(params, components) do
    case Enum.find(components, &(&1["source"] == "query")) do
      nil -> ""
      component -> encode_query(params, component)
    end
  end

  defp component_value(%{"source" => "timestamp"}, context) do
    context.timestamp
  end

  defp component_value(%{"source" => "method"}, context) do
    context.method
  end

  defp component_value(%{"source" => "path"}, context) do
    context.path
  end

  defp component_value(%{"source" => "query"} = component, context) do
    encode_query(context.params, component)
  end

  defp component_value(%{"source" => "body"}, context) do
    context.body || ""
  end

  defp component_value(%{"source" => "literal", "value" => value}, context) do
    if value == "?" and context.query == "", do: "", else: value
  end

  defp component_value(%{"source" => "api_key"}, context) do
    context.credentials.api_key
  end

  defp component_value(%{"source" => "passphrase"}, context) do
    context.credentials.password || ""
  end

  defp component_value(%{"source" => "nonce"}, context) do
    context.nonce || ""
  end

  defp component_value(%{"source" => "recv_window"}, context) do
    to_string(context.recv_window)
  end

  defp component_value(%{"source" => "hostname"}, context) do
    context[:hostname] || ""
  end

  defp component_value(%{"source" => "stage", "stage" => name}, context) do
    get_in(context, [:stages, name]) || ""
  end

  defp component_value(%{"source" => source}, _context) do
    raise ArgumentError, "unsupported sign_recipe canonical component source #{inspect(source)}"
  end

  defp encode_query(nil, _component), do: ""
  defp encode_query(params, _component) when params == %{} or params == [], do: ""

  defp encode_query(params, component) do
    pairs = query_pairs(params, component["key_order"] || @default_query_key_order)
    encoder = component["encoder"] || @default_query_encoder

    pairs
    |> encode_query_pairs(encoder)
    |> apply_replacements(component["replacements"])
  end

  defp query_pairs(params, "sorted") do
    Enum.sort_by(params, fn {key, _value} -> to_string(key) end)
  end

  defp query_pairs(params, _key_order), do: Enum.to_list(params)

  defp encode_query_pairs(pairs, "urlencodeWithArrayRepeat") do
    # Coinbase/binance-style: repeated bare keys (`ids=a&ids=b`).
    Signing.encode_query_pairs(pairs, array_style: :repeat)
  end

  defp encode_query_pairs(pairs, "urlencodeJsonArray") do
    pairs
    |> Enum.map(fn
      {key, values} when is_list(values) -> {key, encode_json_array!(key, values)}
      pair -> pair
    end)
    |> Signing.encode_query_pairs()
  end

  defp encode_query_pairs(pairs, "urlencodeCommaSeparatedArray") do
    pairs
    |> Enum.map(fn
      {key, values} when is_list(values) -> {key, encode_comma_separated_array!(key, values)}
      pair -> pair
    end)
    |> Signing.encode_query_pairs()
  end

  defp encode_query_pairs(pairs, "rawencode") do
    Enum.map_join(pairs, "&", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp encode_query_pairs(pairs, "urlencodeNested") do
    pairs
    |> Enum.map(fn
      {key, value} when is_map(value) or is_list(value) -> {key, Jason.encode!(value)}
      pair -> pair
    end)
    # Same percent-encoding as plain urlencode (space → %20); never URI.encode_query's +.
    |> Signing.encode_query_pairs()
  end

  # Plain urlencode (and any unknown encoder) must encode scalar arrays — the
  # bare URI.encode_query path crashes on lists (task 240). Default dialect is
  # empty-bracket keys (Deribit live evidence); use urlencodeWithArrayRepeat
  # for bare-key repeat.
  defp encode_query_pairs(pairs, _encoder), do: Signing.encode_query_pairs(pairs)

  defp encode_json_array!(key, values) do
    if Enum.any?(values, &(is_map(&1) or is_list(&1))) do
      raise ArgumentError, "unsupported nested query param #{inspect(to_string(key))}"
    end

    Jason.encode!(values)
  end

  defp encode_comma_separated_array!(key, values) do
    if Enum.any?(values, &(is_map(&1) or is_list(&1))) do
      raise ArgumentError, "unsupported nested query param #{inspect(to_string(key))}"
    end

    Enum.map_join(values, ",", &to_string/1)
  end

  defp apply_replacements(query, replacements) when is_list(replacements) do
    Enum.reduce(replacements, query, fn
      %{"from" => from, "to" => to}, acc -> String.replace(acc, from, to)
      _replacement, acc -> acc
    end)
  end

  defp apply_replacements(query, _replacements), do: query

  defp sign_payload(payload, secret, recipe) do
    payload
    |> digest(secret, get_in(recipe, ["crypto_op", "algo"]))
    |> encode_signature(recipe)
  end

  defp digest(payload, secret, "hmac_sha256"), do: Signing.hmac_sha256(payload, secret)
  defp digest(payload, secret, "hmac_sha384"), do: Signing.hmac_sha384(payload, secret)
  defp digest(payload, secret, "hmac_sha512"), do: Signing.hmac_sha512(payload, secret)

  defp digest(_payload, _secret, algo) do
    raise ArgumentError, "unsupported sign_recipe crypto_op algo #{inspect(algo)}"
  end

  defp encode_signature(signature, recipe) do
    case signature_encoding(recipe) do
      :base64 -> Signing.encode_base64(signature)
      :hex -> Signing.encode_hex(signature)
      :url -> signature |> Signing.encode_hex() |> URI.encode_www_form()
    end
  end

  defp signature_encoding(recipe) do
    recipe
    |> transforms()
    |> Enum.find(fn transform -> transform["target"] == "signature" end)
    |> case do
      %{"op" => "base64_encode"} -> :base64
      %{"op" => "hex_encode"} -> :hex
      %{"op" => "url_encode"} -> :url
      _ -> :hex
    end
  end

  # `signature_placement` may carry a `by_method` map overriding placement for a
  # given HTTP verb — bybit's legacy scheme signs the same canonical string for
  # GET and POST but places `sign` in the query for GET and in the request body
  # for legacy Bybit POST requests.
  defp placement(recipe, method) do
    base = Map.get(recipe, "signature_placement") || %{}
    override = get_in(base, ["by_method", method]) || %{}

    base
    |> Map.delete("by_method")
    |> Map.merge(override)
  end

  defp signed_url(request, query, signature, %{"location" => "query"} = placement) do
    append_query(request.path, append_query_signature(query, signature, placement))
  end

  defp signed_url(request, _query, _signature, %{"location" => "signed_params_body"}), do: request.path

  defp signed_url(request, query, _signature, _placement) do
    if request.method in [:get, :delete], do: append_query(request.path, query), else: request.path
  end

  # `signed_params_body`: the signed param set (caller params + injected auth
  # params) plus the signature travel in the body, and nothing is appended to
  # the URL. Bybit rejects the query form on legacy POST with
  # 10001 "Request parameter error: apiKey is missing" (verified live, testnet).
  defp signed_body(_body, params, signature, path, %{"location" => "signed_params_body"} = placement) do
    key = Map.get(placement, "key") || "signature"
    pairs = Enum.to_list(params) ++ [{key, signature}]

    case body_encoder(path, placement) do
      %{"op" => "urlencode"} -> encode_query_pairs(pairs, "urlencode")
      _json -> pairs |> Map.new() |> Jason.encode!()
    end
  end

  defp signed_body(body, _params, _signature, _path, _placement), do: body

  # Legacy POST body encoding is selected by path: form-encoded when the path
  # contains "spot", JSON otherwise. No spot/v3 POST private endpoint exists in
  # the vendored catalog, so the form branch is authored-but-unexercised.
  defp body_encoder(path, placement) do
    placement
    |> Map.get("encoders", [])
    |> List.wrap()
    |> Enum.find(fn encoder ->
      is_binary(encoder["path_contains"]) and String.contains?(path, encoder["path_contains"])
    end)
    |> Kernel.||(Map.get(placement, "default_encoder", %{"op" => "json_encode"}))
  end

  defp append_query(path, ""), do: path
  defp append_query(path, query), do: path <> "?" <> query

  defp append_query_signature(query, signature, placement) do
    key = Map.get(placement, "key") || "signature"
    signature_param = URI.encode_query(%{key => signature})

    if query == "", do: signature_param, else: query <> "&" <> signature_param
  end

  defp headers(credentials, timestamp, nonce, signature, recipe, placement, recv_window) do
    auth_headers =
      recipe
      |> Map.get("auth_headers", [])
      |> List.wrap()
      |> Enum.map(&auth_header(&1, credentials, timestamp, nonce, recv_window))
      |> Enum.reject(&is_nil/1)

    case Map.get(placement, "location") do
      "header" -> auth_headers ++ [{Map.get(placement, "key"), signature}]
      _ -> auth_headers
    end
  end

  defp auth_header(%{"name" => name, "source" => "api_key"}, credentials, _timestamp, _nonce, _recv_window) do
    {name, credentials.api_key}
  end

  defp auth_header(%{"name" => name, "source" => "passphrase"}, credentials, _timestamp, _nonce, _recv_window) do
    {name, credentials.password || ""}
  end

  defp auth_header(%{"name" => name, "source" => "timestamp"}, _credentials, timestamp, _nonce, _recv_window) do
    {name, timestamp}
  end

  defp auth_header(%{"name" => name, "source" => "nonce"}, _credentials, _timestamp, nonce, _recv_window) do
    {name, nonce || ""}
  end

  defp auth_header(%{"name" => name, "source" => "recv_window"}, _credentials, _timestamp, _nonce, recv_window) do
    {name, to_string(recv_window)}
  end

  defp auth_header(_header, _credentials, _timestamp, _nonce, _recv_window), do: nil

  defp maybe_add_content_type(headers, body, recipe, path, placement) do
    cond do
      not (is_binary(body) and body != "") -> headers
      Map.get(placement, "location") == "signed_params_body" -> headers ++ [body_content_type(path, placement)]
      body_json?(recipe) -> headers ++ [@json_content_type]
      true -> headers
    end
  end

  defp body_content_type(path, placement) do
    case body_encoder(path, placement) do
      %{"op" => "urlencode"} -> @form_content_type
      _json -> @json_content_type
    end
  end

  defp body_json?(recipe) do
    Enum.any?(transforms(recipe), fn transform ->
      transform["target"] == "body" and transform["op"] == "json_encode"
    end)
  end

  defp transforms(recipe), do: Map.get(recipe, "pre_sign_transforms") || []

  # --- 4.13.0 branch_family + effective recipe + stages + new components ---

  defp resolve_effective_recipe(recipe, method, path) when is_map(recipe) do
    case select_branch(recipe, path) do
      {:deferred, _b} ->
        # distill explicitly marked this branch deferred — a by-design abstain;
        # stay quiet (no log) since it's an expected, known-unsupported surface.
        {:unsupported, unsupported_exchange(recipe)}

      {:abstain, reason} ->
        # branch_family present but no branch resolved (no match without an
        # `otherwise` catch-all, or an unknown discriminator). We don't know how
        # to sign — abstain with a named reason rather than silently signing the
        # section's default canonical_string (silently-wrong-signature guard).
        {:unsupported, unsupported_exchange(recipe), reason}

      branch when is_map(branch) ->
        # A derived branch overrides canonical_string / auth_headers /
        # signature_placement, but shared signing fields (crypto_op,
        # nonce, …) live on the containing section, not the branch. Merge
        # the branch onto its section (branch keys win) so crypto_op et al.
        # survive branch selection.
        recipe
        |> branch_section()
        |> Map.delete("branch_family")
        |> Map.merge(branch)
        |> active_recipe(method, path)

      _ ->
        active_recipe(recipe, method, path)
    end
  end

  defp resolve_effective_recipe(recipe, method, path), do: active_recipe(recipe, method, path)

  defp unsupported_exchange(recipe) do
    get_in(recipe, ["exchange", "id"]) || Map.get(recipe, "exchange")
  end

  defp select_branch(recipe, path) do
    recipe
    |> branch_family()
    |> select_branch_from_family(path)
  end

  defp branch_family(recipe) do
    recipe |> branch_section() |> Map.get("branch_family")
  end

  # The map that holds branch_family (and the shared crypto_op/nonce fields):
  # the recipe itself, its `private` section, or the nested sign_recipe private.
  defp branch_section(recipe) do
    cond do
      match?(%{"branch_family" => _}, recipe) ->
        recipe

      match?(%{"branch_family" => _}, Map.get(recipe, "private", %{})) ->
        Map.get(recipe, "private")

      match?(%{"branch_family" => _}, get_in(recipe, ["auth", "sign_recipe", "private"]) || %{}) ->
        get_in(recipe, ["auth", "sign_recipe", "private"])

      true ->
        recipe
    end
  end

  # No branch_family at all → flat recipe; resolve the top-level/section recipe.
  defp select_branch_from_family(nil, _path), do: nil

  defp select_branch_from_family(%{"discriminator" => "path_substring", "branches" => branches}, path) do
    case find_matching_branch(branches, to_string(path)) do
      nil -> {:abstain, :no_branch_matched}
      branch -> normalize_branch_result(branch)
    end
  end

  # A branch_family is present but its discriminator is one we don't implement —
  # we can't pick a branch, so abstain rather than silently signing the section
  # default; a new distill spec shape then fails loud at the first signing call.
  defp select_branch_from_family(%{} = _unknown_family, _path), do: {:abstain, :unknown_discriminator}

  defp find_matching_branch(branches, normalized) do
    Enum.find(branches, &branch_matches?(&1, normalized))
  end

  defp branch_matches?(branch, normalized) do
    m = branch["match"] || %{}

    (is_binary(m["path_contains"]) and String.contains?(normalized, m["path_contains"])) or
      m["otherwise"] == true
  end

  defp normalize_branch_result(%{"status" => "deferred"} = branch), do: {:deferred, branch}
  defp normalize_branch_result(branch) when is_map(branch), do: branch

  defp execute_stages(recipe, base_context) do
    block = get_canonical_block(recipe)
    stages = get_in(block, ["stages"]) || []

    Enum.reduce(stages, %{}, fn stage, acc ->
      name = stage["name"]
      val = execute_stage(stage, base_context)
      Map.put(acc, name, val)
    end)
  end

  defp get_canonical_block(recipe) do
    cs =
      Map.get(recipe, "canonical_string") ||
        get_in(recipe, ["private", "canonical_string"]) || %{}

    cs["POST"] || cs["GET"] || cs["*"] || cs |> Map.values() |> List.first() || cs
  end

  defp execute_stage(%{"op" => "hash", "algo" => algo, "components" => comps, "output_encoding" => enc}, context) do
    payload =
      comps
      |> Enum.map(&component_value(&1, Map.put(context, :stages, %{})))
      |> :erlang.iolist_to_binary()

    hashed =
      case algo do
        "sha256" -> Signing.sha256(payload)
        "sha512" -> Signing.sha512(payload)
        _ -> payload
      end

    case enc do
      "binary" -> hashed
      "hex" -> Signing.encode_hex(hashed)
      _ -> hashed
    end
  end

  defp execute_stage(_, _), do: ""

  defp maybe_inject_query_auth_params(params, credentials, recipe, timestamp, recv_window) do
    params
    |> normalize_query_params()
    |> inject_declared_query_params(credentials, recipe, timestamp, recv_window)
    |> maybe_inject_query_timestamp(recipe, timestamp)
  end

  defp normalize_query_params(nil), do: %{}
  defp normalize_query_params(params), do: params

  defp inject_declared_query_params(params, credentials, recipe, timestamp, recv_window) do
    recipe
    |> Map.get("query_params", [])
    |> List.wrap()
    |> Enum.reduce(params, fn declaration, acc ->
      inject_query_param(acc, declaration, credentials, timestamp, recv_window)
    end)
  end

  defp inject_query_param(
         params,
         %{"name" => name, "source" => "literal", "value" => value},
         _credentials,
         _timestamp,
         _recv_window
       ) do
    put_query_param(params, name, value)
  end

  defp inject_query_param(params, %{"name" => name, "source" => source}, credentials, timestamp, recv_window) do
    put_query_param(params, name, query_param_value(source, credentials, timestamp, recv_window))
  end

  defp inject_query_param(params, _declaration, _credentials, _timestamp, _recv_window), do: params

  defp query_param_value("api_key", credentials, _timestamp, _recv_window), do: credentials.api_key
  defp query_param_value("timestamp", _credentials, timestamp, _recv_window), do: timestamp
  defp query_param_value("recv_window", _credentials, _timestamp, recv_window), do: to_string(recv_window)
  defp query_param_value(_source, _credentials, _timestamp, _recv_window), do: nil

  defp maybe_inject_query_timestamp(params, recipe, timestamp) when is_map(params) do
    placement = Map.get(recipe, "signature_placement") || %{}
    has_ts_decl = Map.has_key?(recipe, "timestamp")

    if placement["location"] == "query" and has_ts_decl and not declared_query_timestamp?(recipe) do
      key = "timestamp"
      has = has_key_any_type?(params, key)
      if has, do: params, else: Map.put(params, key, timestamp)
    else
      params
    end
  end

  defp maybe_inject_query_timestamp(params, _recipe, _ts), do: params || %{}

  defp declared_query_timestamp?(recipe) do
    recipe
    |> Map.get("query_params", [])
    |> List.wrap()
    |> Enum.any?(&match?(%{"source" => "timestamp"}, &1))
  end

  defp put_query_param(params, _key, nil), do: params

  defp put_query_param(params, key, value) when is_map(params) do
    params
    |> Map.reject(fn {existing, _value} -> to_string(existing) == key end)
    |> Map.put(key, value)
  end

  defp put_query_param(params, key, value) when is_list(params) do
    params
    |> Enum.reject(fn {existing, _value} -> to_string(existing) == key end)
    |> Kernel.++([{key, value}])
  end

  defp has_key_any_type?(params, key) when is_binary(key) do
    Map.has_key?(params, key) or Enum.any?(Map.keys(params), fn k -> to_string(k) == key end)
  end

  defp prepare_secret(credentials, recipe) do
    secret = credentials.secret

    case get_in(recipe, ["crypto_op", "key_encoding"]) do
      "base64_decode" -> Signing.decode_base64(secret)
      _ -> secret
    end
  end
end
