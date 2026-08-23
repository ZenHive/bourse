defmodule Bourse.Test.Generator.SignatureHelper do
  @moduledoc """
  Signature format validation helpers for the signing test generator.

  Validates output of `Bourse.Signing.sign/4` per pattern — signature
  encoding/length, required headers, timestamp/nonce format. No HTTP,
  no credentials required; operates purely on the signed-request map.

  Covers the generic HTTP patterns in `Bourse.Signing.patterns/0`; venue-specific
  DEX signers have dedicated parity tests.
  """

  import ExUnit.Assertions

  # SHA256 = 32B → 64 hex / 44 base64
  @signature_lengths %{
    sha256: %{hex: 64, base64: 44}
  }

  @timestamp_digits %{milliseconds: 13, seconds: 10}

  @pattern_algorithms %{
    hmac_sha256_headers: :sha256,
    hmac_sha256_iso_passphrase: :sha256,
    deribit: :sha256
  }

  @pattern_timestamp_formats %{
    hmac_sha256_headers: :milliseconds,
    hmac_sha256_iso_passphrase: :iso8601
  }

  # Default signature encoding per pattern (used when spec config omits it).
  # Derived from what each pattern's signing module actually produces.
  @pattern_default_encoding %{
    hmac_sha256_query: :hex,
    hmac_sha256_headers: :hex,
    hmac_sha256_iso_passphrase: :base64,
    deribit: :hex
  }

  @pattern_required_headers %{
    hmac_sha256_query: [:api_key_header],
    hmac_sha256_headers: [:api_key_header, :timestamp_header, :signature_header],
    hmac_sha256_iso_passphrase: [:api_key_header, :timestamp_header, :signature_header, :passphrase_header],
    deribit: [],
    api_key_secret_headers: [:api_key_header, :secret_header]
  }

  # Signer defaults mirrored from each signing module. When spec config omits a
  # header-name key, the signer falls back to these — so the helper must assert
  # against the same default instead of silently skipping.
  # Recipe-backed HMAC patterns resolve per-exchange names from sign_recipe first
  # (auth_headers + signature_placement.key); no family-wide Bybit fallback.
  @pattern_default_headers %{
    hmac_sha256_iso_passphrase: %{}
  }

  @doc """
  Validates the signature in a signed request for the given pattern.
  """
  @spec validate_signature_for_pattern(map(), map(), atom()) :: :ok
  def validate_signature_for_pattern(signed, signing, :hmac_sha256_query) do
    validate_query_signature(signed, signing)
  end

  def validate_signature_for_pattern(signed, _signing, :deribit) do
    headers_map = Map.new(signed.headers)
    auth = Map.get(headers_map, "Authorization")
    assert auth, "Expected Authorization header for deribit signing"

    assert String.starts_with?(auth, "deri-hmac-sha256 "),
           "Expected Authorization to start with 'deri-hmac-sha256 ', got: #{auth}"

    [_prefix, pairs_str] = String.split(auth, " ", parts: 2)

    pairs =
      pairs_str
      |> String.split(",")
      |> Map.new(fn pair ->
        [key, value] = String.split(pair, "=", parts: 2)
        {key, value}
      end)

    for field <- ["id", "ts", "sig", "nonce"] do
      assert Map.has_key?(pairs, field),
             "Expected '#{field}=' in Authorization header. Found: #{inspect(Map.keys(pairs))}"
    end

    sig = pairs["sig"]
    sig_length = String.length(sig)

    assert sig_length == @signature_lengths.sha256.hex,
           "Expected sig 64-char hex, got #{sig_length}: #{sig}"

    assert String.match?(sig, ~r/^[0-9a-f]+$/),
           "Expected sig lowercase hex, got: #{sig}"

    assert String.match?(pairs["ts"], ~r/^\d{#{@timestamp_digits.milliseconds}}$/),
           "Expected ts to be #{@timestamp_digits.milliseconds}-digit ms, got: #{pairs["ts"]}"

    assert String.match?(pairs["nonce"], ~r/^\d+$/),
           "Expected numeric nonce, got: #{pairs["nonce"]}"

    :ok
  end

  def validate_signature_for_pattern(_signed, _signing, :api_key_secret_headers), do: :ok

  def validate_signature_for_pattern(signed, signing, pattern) do
    case Map.fetch(@pattern_algorithms, pattern) do
      {:ok, algorithm} ->
        validate_header_signature(signed, signing, algorithm, pattern)

      :error ->
        flunk("Unknown signing pattern: #{inspect(pattern)}")
    end
  end

  @doc """
  Validates all required headers for a pattern are present.
  """
  @spec validate_required_headers(map(), map(), atom()) :: :ok
  def validate_required_headers(headers_map, signing, pattern) do
    required = required_headers_for_pattern(signing, pattern)
    found = headers_map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

    for header <- required do
      assert Map.has_key?(headers_map, header),
             "Expected header '#{header}' for pattern #{inspect(pattern)}. Found: #{Enum.join(found, ", ")}"
    end

    :ok
  end

  @doc """
  Validates timestamp/nonce format for a pattern.
  """
  @spec validate_timestamp_format(map(), map(), map(), atom()) :: :ok
  def validate_timestamp_format(_headers_map, signed, signing, :hmac_sha256_query) do
    validate_query_timestamp(signed, signing)
  end

  def validate_timestamp_format(_headers_map, _signed, _signing, :deribit), do: :ok

  def validate_timestamp_format(headers_map, _signed, signing, pattern) do
    if recipe_places_timestamp_in_header?(signing) or not has_sign_recipe?(signing) do
      format = timestamp_format_for_signing(signing, pattern)

      case format do
        nil -> :ok
        fmt -> validate_header_timestamp(headers_map, signing, fmt, pattern)
      end
    else
      :ok
    end
  end

  defp validate_query_signature(signed, signing) do
    signature_key = signing[:signature_key] || recipe_signature_key(signing) || "signature"
    encoding = signing[:signature_encoding] || :hex

    params = query_params_from_signed(signed)
    signature = params[signature_key]

    assert signature != nil,
           "Expected query signature key '#{signature_key}' in URL or body: #{inspect(signed.url)}"

    validate_signature_encoding(signature, encoding, :sha256)
  end

  defp validate_header_signature(signed, signing, algorithm, pattern) do
    sig_header = header_name(signing, :signature_header, pattern) || signing[:sign_header]
    encoding = signing[:signature_encoding] || Map.get(@pattern_default_encoding, pattern, :hex)

    assert sig_header,
           "No signature header resolvable for pattern #{inspect(pattern)} — signer would fail to emit one. Populate signing config, sign_recipe auth_headers/signature_placement, or add a @pattern_default_headers entry."

    headers_map = Map.new(signed.headers)
    signature = headers_map[sig_header]

    assert signature != nil,
           "Expected signature in header '#{sig_header}'. Headers: #{inspect(Map.keys(headers_map))}"

    validate_signature_encoding(signature, encoding, algorithm)
  end

  @config_key_to_auth_source %{
    api_key_header: "api_key",
    timestamp_header: "timestamp",
    passphrase_header: "passphrase",
    recv_window_header: "recv_window",
    nonce_header: "nonce"
  }

  defp header_name(signing, key, pattern) do
    signing[key] ||
      header_name_from_recipe(signing, key) ||
      get_in(@pattern_default_headers, [pattern, key])
  end

  defp header_name_from_recipe(signing, key) do
    case Map.fetch(signing, :sign_recipe) do
      {:ok, recipe} when is_map(recipe) -> resolve_header_name_from_recipe(recipe, key)
      _ -> nil
    end
  end

  defp resolve_header_name_from_recipe(recipe, key) do
    walk_recipe_candidates(recipe, fn candidate ->
      case key do
        :signature_header -> resolve_signature_header_name(candidate)
        other -> resolve_auth_header_name(candidate, other)
      end
    end)
  end

  defp resolve_signature_header_name(recipe) do
    case get_in(recipe, ["signature_placement", "location"]) do
      "header" -> get_in(recipe, ["signature_placement", "key"])
      _ -> nil
    end
  end

  defp recipe_signature_key(signing) do
    case Map.fetch(signing, :sign_recipe) do
      {:ok, recipe} when is_map(recipe) -> walk_recipe_candidates(recipe, &get_in(&1, ["signature_placement", "key"]))
      _ -> nil
    end
  end

  defp resolve_auth_header_name(recipe, key) do
    case Map.get(@config_key_to_auth_source, key) do
      nil -> nil
      source -> find_auth_header_name(Map.get(recipe, "auth_headers", []), source)
    end
  end

  defp walk_recipe_candidates(recipe, fun) when is_map(recipe) do
    if recipe_candidate?(recipe) do
      fun.(recipe)
    else
      recipe
      |> Enum.reject(fn {k, _v} -> k in ["auth_headers", "canonical_string", "pre_sign_transforms", "branch_family"] end)
      |> Enum.find_value(fn {_k, nested} -> walk_recipe_candidates(nested, fun) end)
      |> Kernel.||(walk_branch_family(recipe, fun))
    end
  end

  defp walk_recipe_candidates(_recipe, _fun), do: nil

  defp walk_branch_family(%{"branch_family" => %{"branches" => branches}}, fun) when is_list(branches) do
    Enum.find_value(branches, fn b -> if is_map(b), do: walk_recipe_candidates(b, fun) end)
  end

  defp walk_branch_family(_, _), do: nil

  # recipe is always a map here — walk_recipe_candidates only calls this from its
  # is_map/1-guarded clause, so no non-map fallback clause is needed.
  defp recipe_candidate?(recipe) when is_map(recipe) do
    Map.has_key?(recipe, "canonical_string") and
      (Map.has_key?(recipe, "crypto_op") or Map.has_key?(recipe, "signature_placement"))
  end

  @doc """
  Returns a request path that selects a *derived* branch for branch_family
  recipes (e.g. Bybit's `v5`), falling back to `default` for flat recipes.

  The generic per-pattern signing tests use synthetic `/api/v1/*` paths. A
  branch_family exchange resolves those to its `otherwise` branch — which is
  `status: "deferred"` and therefore returns `:unsupported`. Embedding the first
  derived branch's `path_contains` token routes the generic test through a real,
  signable branch instead. The deferred (`otherwise`) branch's `:unsupported`
  contract is asserted separately.
  """
  @spec branch_path(map(), String.t()) :: String.t()
  def branch_path(signing, default) do
    case first_derived_branch_token(Map.get(signing, :sign_recipe)) do
      token when is_binary(token) -> "/" <> token <> "/order/create"
      _ -> default
    end
  end

  defp first_derived_branch_token(recipe) when is_map(recipe) do
    recipe
    |> branch_family_branches()
    |> Enum.find_value(fn branch ->
      if branch["status"] == "derived", do: get_in(branch, ["match", "path_contains"])
    end)
  end

  defp first_derived_branch_token(_), do: nil

  defp branch_family_branches(recipe) do
    bf =
      Map.get(recipe, "branch_family") ||
        get_in(recipe, ["private", "branch_family"]) || %{}

    get_in(bf, ["branches"]) || []
  end

  defp timestamp_format_for_signing(signing, pattern) do
    case recipe_timestamp_format(Map.get(signing, :sign_recipe)) do
      nil -> Map.get(@pattern_timestamp_formats, pattern)
      format -> format
    end
  end

  defp recipe_timestamp_format(recipe) when is_map(recipe) do
    if Map.has_key?(recipe, "timestamp") do
      map_recipe_timestamp_format(recipe)
    else
      recipe
      |> Enum.reject(fn {k, _v} -> k in ["auth_headers", "canonical_string", "pre_sign_transforms", "branch_family"] end)
      |> Enum.find_value(fn {_k, nested} -> recipe_timestamp_format(nested) end)
      |> Kernel.||(walk_branch_family_for_ts(recipe))
    end
  end

  defp recipe_timestamp_format(_), do: nil

  defp walk_branch_family_for_ts(%{"branch_family" => %{"branches" => bs}}) when is_list(bs) do
    Enum.find_value(bs, fn b -> if is_map(b), do: recipe_timestamp_format(b) end)
  end

  defp walk_branch_family_for_ts(_), do: nil

  defp map_recipe_timestamp_format(recipe) do
    case get_in(recipe, ["timestamp", "format"]) do
      format when format in ["iso8601", "iso8601_seconds"] -> :iso8601
      "seconds" -> :seconds
      format when format in ["string", "integer"] -> :milliseconds
      _ -> nil
    end
  end

  defp find_auth_header_name(headers, source) do
    headers
    |> List.wrap()
    |> Enum.find_value(fn
      %{"name" => name, "source" => ^source} when is_binary(name) -> name
      _ -> nil
    end)
  end

  defp recipe_timestamp_key(signing) do
    with {:ok, recipe} <- Map.fetch(signing, :sign_recipe), true <- is_map(recipe) do
      walk_recipe_candidates(recipe, &timestamp_key_from_candidate/1)
    else
      _ -> nil
    end
  end

  defp timestamp_key_from_candidate(cand) do
    get_in(cand, ["timestamp", "key"]) || timestamp_query_param_name(cand) || default_timestamp_key(cand)
  end

  defp timestamp_query_param_name(cand) do
    cand
    |> Map.get("query_params", [])
    |> List.wrap()
    |> Enum.find_value(fn
      %{"name" => name, "source" => "timestamp"} when is_binary(name) -> name
      _ -> nil
    end)
  end

  defp default_timestamp_key(cand) do
    if get_in(cand, ["timestamp"]) ||
         find_auth_header_name(get_in(cand, ["auth_headers"]) || [], "timestamp") do
      "timestamp"
    end
  end

  defp recipe_timestamp_location(signing) do
    with {:ok, recipe} <- Map.fetch(signing, :sign_recipe), true <- is_map(recipe) do
      walk_recipe_candidates(recipe, &timestamp_location_from_candidate/1)
    else
      _ -> nil
    end
  end

  defp timestamp_location_from_candidate(cand) do
    case get_in(cand, ["signature_placement", "location"]) do
      loc when loc in ["query", "header"] -> loc
      _ -> find_ts_location_from_auth(cand)
    end
  end

  defp find_ts_location_from_auth(cand) do
    headers = get_in(cand, ["auth_headers"]) || []
    if find_auth_header_name(headers, "timestamp"), do: "header"
  end

  defp has_sign_recipe?(%{sign_recipe: r}) when is_map(r), do: true
  defp has_sign_recipe?(_), do: false

  defp recipe_places_timestamp_in_header?(signing) do
    recipe_timestamp_location(signing) == "header"
  end

  defp validate_signature_encoding(signature, :hex, algorithm) do
    assert String.match?(signature, ~r/^[a-fA-F0-9]+$/),
           "Hex signature should be hex-only, got: #{signature}"

    expected = hex_length(algorithm)
    actual = String.length(signature)

    assert actual == expected,
           "Expected #{algorithm} hex length #{expected}, got #{actual}"

    :ok
  end

  defp validate_signature_encoding(signature, :base64, algorithm) do
    assert String.match?(signature, ~r/^[A-Za-z0-9+\/]+=*$/),
           "Base64 signature invalid, got: #{signature}"

    expected = base64_length(algorithm)
    actual = String.length(signature)

    # ±2 tolerance for padding variants
    assert actual >= expected - 2 and actual <= expected + 2,
           "Expected #{algorithm} base64 ~#{expected} chars, got #{actual}"

    :ok
  end

  defp validate_signature_encoding(signature, _encoding, _algorithm) do
    assert String.length(signature) > 0, "Signature should not be empty"
    :ok
  end

  defp hex_length(:sha256), do: @signature_lengths.sha256.hex

  defp base64_length(:sha256), do: @signature_lengths.sha256.base64

  defp required_headers_for_pattern(signing, pattern) do
    if has_sign_recipe?(signing) do
      signing
      |> compute_required_from_recipe()
      |> Enum.map(&header_name(signing, &1, pattern))
      |> ensure_all_resolved!(pattern)
    else
      @pattern_required_headers
      |> Map.get(pattern, [])
      |> Enum.map(&header_name(signing, &1, pattern))
      |> ensure_all_resolved!(pattern)
    end
  end

  defp compute_required_from_recipe(signing) do
    r = Map.get(signing, :sign_recipe)
    req = []
    req = if has_auth_source?(r, "api_key"), do: req ++ [:api_key_header], else: req
    req = if has_auth_source?(r, "secret"), do: req ++ [:secret_header], else: req
    req = if has_auth_source?(r, "passphrase"), do: req ++ [:passphrase_header], else: req
    req = if has_auth_source?(r, "timestamp"), do: req ++ [:timestamp_header], else: req
    req = if has_auth_source?(r, "nonce"), do: req ++ [:nonce_header], else: req
    loc = recipe_timestamp_location(signing) || get_in(r, ["signature_placement", "location"])
    if loc == "header", do: req ++ [:signature_header], else: req
  end

  defp has_auth_source?(nil, _), do: false

  defp has_auth_source?(r, src) when is_map(r) do
    headers = get_in(r, ["auth_headers"]) || []
    # also check branches
    in_branches = get_in(r, ["branch_family", "branches"]) || []
    has_in = Enum.any?(List.wrap(headers), &(&1["source"] == src))
    has_in or Enum.any?(in_branches, fn b -> has_auth_source?(b, src) end) or has_auth_source?(Map.get(r, "private"), src)
  end

  defp has_auth_source?(_, _), do: false

  defp ensure_all_resolved!(headers, pattern) do
    if Enum.any?(headers, &is_nil/1) do
      flunk(
        "Pattern #{inspect(pattern)} has unresolvable required header. " <>
          "Spec config missing a header-name key, sign_recipe auth_headers/signature_placement " <>
          "incomplete, and no signer default defined."
      )
    end

    headers
  end

  defp validate_query_timestamp(signed, signing) do
    ts_key = signing[:timestamp_key] || recipe_timestamp_key(signing) || "timestamp"
    loc = recipe_timestamp_location(signing)

    # only validate presence in query when recipe places timestamp in query (or no recipe info)
    if loc in [nil, "query"] do
      params = query_params_from_signed(signed)
      timestamp = params[ts_key]

      assert timestamp != nil,
             "Expected query timestamp '#{ts_key}' in URL or body: #{inspect(signed.url)}"

      ts_str = to_string(timestamp)

      if String.contains?(ts_str, "T") or String.contains?(ts_str, ":") do
        # iso format declared in recipe; accept
        :ok
      else
        digits = @timestamp_digits.milliseconds

        assert String.match?(ts_str, ~r/^\d{#{digits}}$/),
               "Expected #{digits}-digit ms timestamp, got: #{timestamp}"

        :ok
      end
    else
      :ok
    end
  end

  defp query_params_from_signed(%{url: url, body: body, method: method}) do
    uri = URI.parse(url)
    query_params = URI.decode_query(uri.query || "")

    if method in [:post, :put] and map_size(query_params) == 0 and is_binary(body) and body != "" do
      URI.decode_query(body)
    else
      query_params
    end
  end

  defp validate_header_timestamp(headers_map, signing, format, pattern) do
    timestamp_header = header_name(signing, :timestamp_header, pattern)

    if is_nil(timestamp_header) do
      # recipe-driven venue may embed ts (e.g. kraken stage) or place elsewhere; skip
      :ok
    else
      assert Map.has_key?(headers_map, timestamp_header),
             "Expected timestamp in header '#{timestamp_header}'. Headers: #{inspect(Map.keys(headers_map))}"

      timestamp = headers_map[timestamp_header]

      assert timestamp != nil,
             "Expected timestamp in header '#{timestamp_header}'. Headers: #{inspect(Map.keys(headers_map))}"

      validate_timestamp_value(timestamp, format)
    end
  end

  defp validate_timestamp_value(timestamp, :milliseconds) do
    digits = @timestamp_digits.milliseconds

    assert String.match?(timestamp, ~r/^\d{#{digits}}$/),
           "Expected #{digits}-digit ms timestamp, got: #{timestamp}"

    :ok
  end

  defp validate_timestamp_value(timestamp, :seconds) do
    digits = @timestamp_digits.seconds

    assert String.match?(timestamp, ~r/^\d{#{digits}}$/),
           "Expected #{digits}-digit seconds timestamp, got: #{timestamp}"

    :ok
  end

  defp validate_timestamp_value(timestamp, :iso8601) do
    assert String.match?(timestamp, ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/),
           "Expected ISO8601 timestamp, got: #{timestamp}"

    :ok
  end
end
