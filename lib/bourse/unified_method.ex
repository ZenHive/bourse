defmodule Bourse.UnifiedMethod do
  @moduledoc """
  Compile-time mapping of unified method names to endpoint configs.

  Bridges the gap between Bourse's unified API names (e.g., `"fetchTicker"`) and
  the generated endpoint functions (e.g., `:public_get_v5_market_tickers`).

  The spec's `endpoints.unified` (v4; was `structure.unified_endpoints` in v3)
  maps each unified method to JS interface names (e.g., `"publicGetV5MarketTickers"`).
  This module converts those JS names to Elixir endpoint config atoms and resolves
  them against the pre-computed `@bourse_endpoint_configs` list.

  ## Usage (compile time, in generator macro)

      mapping = Bourse.UnifiedMethod.build_unified_mapping(
        spec["endpoints"]["unified"],
        endpoint_configs
      )
      # => %{fetch_ticker: [%{name: :public_get_v5_market_tickers, ...}], ...}

  """

  # Regex splitting path segments on /, -, ., _, {, }, :, @
  # @ included because BigOne uses "depth@{symbol}/snapshot" style paths
  @path_separator_pattern ~r/[\/\-._{}:@]/

  @doc """
  Builds a mapping from unified method atoms to endpoint configs.

  Takes the spec's `unified` (endpoints.unified) map (camelCase JS names) and the
  pre-computed endpoint configs list, returns a map of snake_case atoms
  to lists of matching endpoint configs.

  Unified methods with no matching endpoint configs are excluded from
  the result (the exchange doesn't support them at the endpoint level).

  ## Examples

      build_unified_mapping(
        %{"fetchTicker" => ["publicGetV5MarketTickers"]},
        [%{name: :public_get_v5_market_tickers, method: :get, ...}]
      )
      #=> %{fetch_ticker: [%{name: :public_get_v5_market_tickers, ...}]}

  """
  @spec build_unified_mapping(map() | nil, [map()], %{String.t() => atom()}) :: %{atom() => [map()]}
  def build_unified_mapping(unified_endpoints, endpoint_configs, js_to_atom \\ %{})
  def build_unified_mapping(nil, _endpoint_configs, _js_to_atom), do: %{}

  def build_unified_mapping(unified_endpoints, endpoint_configs, js_to_atom) when is_map(unified_endpoints) do
    # Forward-convert: compute JS interface name for each endpoint config,
    # then build a lookup from JS name to config.
    # This is more reliable than reverse-converting JS names because
    # build_function_name preserves section casing and path separators
    # that Macro.underscore would mangle.
    js_name_lookup =
      Map.new(endpoint_configs, fn config ->
        js_name = endpoint_config_to_js_name(config.sections, config.method, config.path)
        {js_name, config}
      end)

    Enum.reduce(unified_endpoints, %{}, fn {js_method_name, js_interface_names}, acc ->
      # Use canonical atom from method_defs when available, fall back to
      # Macro.underscore for spec methods not in our list.
      method_atom = Map.get_lazy(js_to_atom, js_method_name, fn -> to_snake_atom(js_method_name) end)

      configs =
        js_interface_names
        |> Enum.map(&Map.get(js_name_lookup, &1))
        |> Enum.reject(&is_nil/1)

      if configs == [] do
        acc
      else
        Map.put(acc, method_atom, configs)
      end
    end)
  end

  @doc """
  Forward-converts an endpoint config to its camel-cased interface method name.

  Used to validate the mapping and for cross-referencing with spec data.
  Sections are joined with camelCase (first as-is, subsequent capitalized).
  Path segments split on `/ - . _ { } :` and each capitalized.

  ## Examples

      endpoint_config_to_js_name(["public"], :get, "v5/market/tickers")
      #=> "publicGetV5MarketTickers"

      endpoint_config_to_js_name(["private", "options"], :delete, "{settle}/orders")
      #=> "privateOptionsDeleteSettleOrders"

      endpoint_config_to_js_name(["dapiPublic"], :get, "ticker/24hr")
      #=> "dapiPublicGetTicker24hr"

  """
  @spec endpoint_config_to_js_name([String.t()], atom(), String.t()) :: String.t()
  def endpoint_config_to_js_name(sections, method, path) do
    prefix = sections_to_js_prefix(sections)
    http_method = method |> to_string() |> String.capitalize()
    path_part = path_to_js_suffix(path)
    "#{prefix}#{http_method}#{path_part}"
  end

  # Converts a camelCase JS unified method name to a snake_case atom.
  # Only called at compile time from build_unified_mapping/2.
  defp to_snake_atom(camel_case) when is_binary(camel_case) do
    camel_case
    |> Macro.underscore()
    # reach:disable-next-line unsafe_atom_creation — compile-time; non-method_defs names aren't interned → would raise
    |> String.to_atom()
  end

  # Joins sections into a camelCase JS prefix.
  # First section as-is, subsequent sections uppercased-first-char only.
  # Uses upcase_first/1 (not String.capitalize/1) because capitalize lowercases
  # the rest of the string, breaking camelCase section names like "accountCategory"
  # → "Accountcategory" instead of "AccountCategory" (Ascendex).
  defp sections_to_js_prefix([]), do: ""

  defp sections_to_js_prefix([first | rest]) do
    first <> Enum.map_join(rest, &upcase_first/1)
  end

  # Converts a path to camelCase JS suffix.
  # Splits on separators (/ - . _ { } :), uppercases first char of each part.
  # Uses upcase_first/1 instead of String.capitalize/1 because capitalize
  # lowercases the rest (e.g., "algoOrder" → "Algoorder"), breaking camelCase
  # paths that Bourse preserves as-is.
  defp path_to_js_suffix(path) do
    path
    |> String.split(@path_separator_pattern, trim: true)
    |> Enum.map_join(&upcase_first/1)
  end

  # Uppercases only the first character, leaving the rest unchanged.
  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp upcase_first(string), do: string
end
