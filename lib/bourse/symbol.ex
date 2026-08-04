defmodule Bourse.Symbol do
  @moduledoc """
  Bidirectional symbol normalization between unified and exchange-specific formats.

  Bourse uses a unified symbol format: `BASE/QUOTE` (e.g., "BTC/USDT").
  Different exchanges use different formats:

  - Binance: "BTCUSDT" (no separator, uppercase)
  - Coinbase: "BTC-USD" (dash separator)
  - Gate.io: "BTC_USDT" (underscore separator)
  - Bitstamp: "btcusd" (lowercase, no separator)
  - Derivatives: "BTC/USDT:USDT" (with settle currency)
  - Kraken: "XXBTZUSD" (X/Z prefixes for currencies)
  - KrakenFutures: "PI_XBTUSD" (contract type prefixes)

  ## Format-Based Conversion

  Use with a format map for simple normalization:

      format = %{separator: "-", case: :upper}
      Bourse.Symbol.normalize("BTC-USD", format)
      #=> "BTC/USD"

      Bourse.Symbol.denormalize("BTC/USD", format)
      #=> "BTC-USD"

  ## Parsing and Building

  Parse unified symbols into components:

      Bourse.Symbol.parse("BTC/USDT:USDT")
      #=> {:ok, %{base: "BTC", quote: "USDT", settle: "USDT"}}

      Bourse.Symbol.parse_extended("BTC/USDT:USDT-260327")
      #=> {:ok, %Bourse.Symbol.ParsedSymbol{base: "BTC", quote: "USDT", settle: "USDT", expiry: "260327", ...}}

      Bourse.Symbol.build("BTC", "USDT", "USDT")
      #=> "BTC/USDT:USDT"

  ## Currency Aliases

  Apply exchange-specific currency code mappings:

      aliases = %{"XBT" => "BTC", "XXRP" => "XRP"}
      Bourse.Symbol.apply_alias("XBT", aliases)
      #=> "BTC"

  """

  alias Bourse.Symbol.Error, as: SymbolError
  alias Bourse.Symbol.ParsedSymbol

  # Default quote currencies for no-separator splitting (longest-match-first)
  @default_quote_currencies ~w(USDT USDC USD EUR GBP JPY BTC ETH BUSD TUSD DAI USDD FDUSD)
  @sorted_quote_currencies Enum.sort_by(@default_quote_currencies, &String.length/1, :desc)

  # KrakenFutures contract prefixes
  @known_contract_prefixes ["PI_", "PF_", "FI_", "FF_", "PV_"]

  # Month abbreviations for date conversion
  @month_abbrevs %{
    1 => "JAN",
    2 => "FEB",
    3 => "MAR",
    4 => "APR",
    5 => "MAY",
    6 => "JUN",
    7 => "JUL",
    8 => "AUG",
    9 => "SEP",
    10 => "OCT",
    11 => "NOV",
    12 => "DEC"
  }

  @month_numbers %{
    "JAN" => 1,
    "FEB" => 2,
    "MAR" => 3,
    "APR" => 4,
    "MAY" => 5,
    "JUN" => 6,
    "JUL" => 7,
    "AUG" => 8,
    "SEP" => 9,
    "OCT" => 10,
    "NOV" => 11,
    "DEC" => 12
  }

  @type symbol_format :: %{separator: String.t(), case: :upper | :lower | :mixed}

  @type parsed_symbol :: %{base: String.t(), quote: String.t(), settle: String.t() | nil}

  @typedoc "Extended parse result — alias of `t:Bourse.Symbol.ParsedSymbol.t/0`."
  @type parsed_extended :: ParsedSymbol.t()

  @type ws_symbol_format ::
          :dash_separated | :lowercase_no_slash | :uppercase_no_slash | :slash | :unknown

  @type pattern_config :: %{
          optional(:quote_settled_suffix) => String.t(),
          pattern: atom(),
          separator: String.t(),
          case: :upper | :lower | :mixed,
          date_format: :yymmdd | :ddmmmyy | :yyyymmdd | nil,
          suffix: String.t() | nil,
          prefix: String.t() | nil
        }

  # Pattern categories for dispatch
  @spot_patterns ~w(no_separator_upper no_separator_lower no_separator_mixed
                    underscore_upper underscore_lower underscore_mixed
                    dash_upper dash_lower dash_mixed
                    colon_upper colon_lower colon_mixed)a

  @swap_patterns ~w(implicit suffix_perpetual suffix_swap suffix_perp)a
  @future_patterns ~w(future_yymmdd future_ddmmmyy future_yyyymmdd future_unknown)a
  @option_patterns ~w(option_ddmmmyy option_yymmdd option_base_yymmdd option_base_yyyymmdd
                      option_with_settle option_unknown)a

  # ===========================================================================
  # Normalization (Exchange → Unified)
  # ===========================================================================

  @doc """
  Converts an exchange-specific symbol to unified format.

  Takes a format map with `:separator` and `:case` keys. Optionally applies
  currency aliases (from `commonCurrencies` spec data) to map exchange-specific
  codes to unified codes.

  ## Parameters

  - `symbol` - The exchange-specific symbol (e.g., "BTCUSDT")
  - `format` - Map with `:separator` and `:case` keys
  - `opts` - Keyword options:
    - `:aliases` - Currency alias map (e.g., `%{"XBT" => "BTC"}`)
    - `:quote_currencies` - Custom list of known quote currencies for no-separator splitting

  ## Returns

  The unified symbol (e.g., "BTC/USDT"), or original if cannot parse.
  """
  @spec normalize(String.t(), symbol_format(), keyword()) :: String.t()
  def normalize(symbol, format, opts \\ [])

  def normalize(symbol, %{separator: sep, case: sym_case}, opts) when is_binary(symbol) do
    aliases = Keyword.get(opts, :aliases, %{})
    quote_currencies = Keyword.get(opts, :quote_currencies)

    # Apply case normalization to uppercase
    symbol = if sym_case == :lower, do: String.upcase(symbol), else: symbol

    # Apply currency aliases (exchange code → unified code)
    symbol = apply_currency_aliases(symbol, aliases)

    # Split by separator
    case sep do
      "" -> find_and_split(symbol, quote_currencies)
      "/" -> symbol
      _ -> String.replace(symbol, sep, "/")
    end
  end

  # ===========================================================================
  # Denormalization (Unified → Exchange)
  # ===========================================================================

  @doc """
  Converts a unified symbol to exchange-specific format.

  Strips settle currency (colon suffix) before conversion, then applies
  separator replacement and case transformation.

  ## Parameters

  - `symbol` - The unified symbol (e.g., "BTC/USDT" or "BTC/USDT:USDT")
  - `format` - Map with `:separator` and `:case` keys
  """
  @spec denormalize(String.t(), symbol_format()) :: String.t()
  def denormalize(symbol, %{separator: sep, case: sym_case}) when is_binary(symbol) do
    # Strip settle currency (e.g., "BTC/USDT:USDT" → "BTC/USDT")
    pair = symbol |> String.split(":", parts: 2) |> hd()

    # Replace unified separator with exchange separator
    result = String.replace(pair, "/", sep)

    # Apply case transformation
    case sym_case do
      :lower -> String.downcase(result)
      :upper -> String.upcase(result)
      _mixed -> result
    end
  end

  # ===========================================================================
  # WebSocket Symbol Denormalization
  # ===========================================================================

  @doc """
  Converts a unified symbol to WebSocket channel format.

  WebSocket channels often use different symbol formats than REST APIs.
  """
  @spec denormalize_ws(String.t(), ws_symbol_format()) :: String.t()
  def denormalize_ws(symbol, :dash_separated), do: String.replace(symbol, "/", "-")
  def denormalize_ws(symbol, :lowercase_no_slash), do: symbol |> String.replace("/", "") |> String.downcase()
  def denormalize_ws(symbol, :uppercase_no_slash), do: String.replace(symbol, "/", "")
  def denormalize_ws(symbol, :slash), do: symbol
  def denormalize_ws(symbol, _unknown), do: String.replace(symbol, "/", "")

  # ===========================================================================
  # Parsing
  # ===========================================================================

  @doc """
  Parses a unified symbol into its components.

  ## Returns

  `{:ok, %{base, quote, settle}}` or `{:error, :invalid_format}`.

      Bourse.Symbol.parse("BTC/USDT")
      #=> {:ok, %{base: "BTC", quote: "USDT", settle: nil}}

      Bourse.Symbol.parse("BTC/USDT:USDT")
      #=> {:ok, %{base: "BTC", quote: "USDT", settle: "USDT"}}
  """
  @spec parse(String.t()) :: {:ok, parsed_symbol()} | {:error, :invalid_format}
  def parse(symbol) when is_binary(symbol) do
    case String.split(symbol, ":") do
      [pair, settle] -> parse_pair(pair, settle)
      [pair] -> parse_pair(pair, nil)
      _ -> {:error, :invalid_format}
    end
  end

  @doc """
  Parses a unified symbol into its components, raising on error.
  """
  @spec parse!(String.t()) :: parsed_symbol()
  def parse!(symbol) when is_binary(symbol) do
    case parse(symbol) do
      {:ok, result} -> result
      {:error, :invalid_format} -> raise SymbolError.invalid_format(symbol)
    end
  end

  @doc """
  Parses a unified symbol into extended components including derivative fields.

  Returns a `%Bourse.Symbol.ParsedSymbol{}` with the same field names as the former
  ad-hoc map (`base`, `quote`, `settle`, `expiry`, `strike`, `option_type`).
  Dot-access and map-pattern matching (`%{base: b}`) both work on the struct.

      Bourse.Symbol.parse_extended("BTC/USDT:USDT-260327")
      #=> {:ok, %Bourse.Symbol.ParsedSymbol{base: "BTC", quote: "USDT", settle: "USDT", expiry: "260327", strike: nil, option_type: nil}}

      Bourse.Symbol.parse_extended("BTC/USD:BTC-260112-84000-C")
      #=> {:ok, %Bourse.Symbol.ParsedSymbol{base: "BTC", quote: "USD", settle: "BTC", expiry: "260112", strike: "84000", option_type: "C"}}
  """
  @spec parse_extended(String.t()) :: {:ok, parsed_extended()} | {:error, :invalid_format}
  def parse_extended(symbol) when is_binary(symbol) do
    case String.split(symbol, ":") do
      [pair] -> parse_extended_pair(pair, nil)
      [pair, settle_and_rest] -> parse_extended_pair(pair, settle_and_rest)
      _ -> {:error, :invalid_format}
    end
  end

  # ===========================================================================
  # Building
  # ===========================================================================

  @doc """
  Builds a unified symbol from components.

      Bourse.Symbol.build("BTC", "USDT")
      #=> "BTC/USDT"

      Bourse.Symbol.build("BTC", "USD", "BTC")
      #=> "BTC/USD:BTC"
  """
  @spec build(String.t(), String.t(), String.t() | nil) :: String.t()
  def build(base, quote_currency, settle \\ nil)

  def build(base, quote_currency, nil), do: "#{base}/#{quote_currency}"
  def build(base, quote_currency, settle), do: "#{base}/#{quote_currency}:#{settle}"

  # ===========================================================================
  # Currency Aliases
  # ===========================================================================

  @doc """
  Applies a currency alias mapping to a single currency code.

  Used with `commonCurrencies` data from exchange specs.

      Bourse.Symbol.apply_alias("XBT", %{"XBT" => "BTC"})
      #=> "BTC"

      Bourse.Symbol.apply_alias("ETH", %{"XBT" => "BTC"})
      #=> "ETH"
  """
  @spec apply_alias(String.t(), map()) :: String.t()
  def apply_alias(currency, aliases) when is_binary(currency) and is_map(aliases) do
    Map.get(aliases, currency, currency)
  end

  @doc """
  Inverts an alias map for reverse lookups (unified → exchange code).

      Bourse.Symbol.reverse_aliases(%{"XBT" => "BTC", "ZEUR" => "EUR"})
      #=> %{"BTC" => "XBT", "EUR" => "ZEUR"}
  """
  @spec reverse_aliases(map()) :: map()
  def reverse_aliases(aliases) when is_map(aliases) do
    Map.new(aliases, fn {k, v} -> {v, k} end)
  end

  # ===========================================================================
  # Prefix Handling
  # ===========================================================================

  @doc """
  Strips known exchange prefixes from a symbol.

  Handles KrakenFutures contract prefixes (PI_, PF_, FI_, FF_, PV_) and
  Kraken currency prefixes (X for crypto, Z for fiat).

      Bourse.Symbol.strip_prefix("PI_XBTUSD")
      #=> {"PI_", "XBTUSD"}

      Bourse.Symbol.strip_prefix("XXBT")
      #=> {"X", "XBT"}

      Bourse.Symbol.strip_prefix("ZUSD")
      #=> {"Z", "USD"}

      Bourse.Symbol.strip_prefix("BTCUSDT")
      #=> {nil, "BTCUSDT"}
  """
  @spec strip_prefix(String.t()) :: {String.t() | nil, String.t()}
  def strip_prefix(symbol) when is_binary(symbol) do
    case find_matching_prefix(symbol, @known_contract_prefixes) do
      {_prefix, _rest} = result -> result
      nil -> strip_currency_prefix(symbol)
    end
  end

  # ===========================================================================
  # Quote Currency Detection
  # ===========================================================================

  @doc """
  Returns the list of known quote currencies, optionally extended with
  exchange-specific currencies.

  Currencies are sorted by length descending for longest-match-first splitting.

      Bourse.Symbol.get_quote_currencies()
      #=> ["FDUSD", "USDD", "USDT", "USDC", "BUSD", "TUSD", ...]

      Bourse.Symbol.get_quote_currencies(["TRY", "BRL"])
      #=> ["FDUSD", "USDD", "USDT", ..., "TRY", "BRL"]
  """
  @spec get_quote_currencies(list(String.t()) | nil) :: list(String.t())
  def get_quote_currencies(extra \\ nil)
  def get_quote_currencies(nil), do: @sorted_quote_currencies

  def get_quote_currencies(extra) when is_list(extra) do
    (@default_quote_currencies ++ extra)
    |> Enum.uniq()
    |> Enum.sort_by(&String.length/1, :desc)
  end

  # ===========================================================================
  # Date Conversion
  # ===========================================================================

  @doc """
  Converts dates between derivative symbol formats.

  Supported formats: `:yymmdd`, `:ddmmmyy`, `:yyyymmdd`.

      Bourse.Symbol.convert_date("260327", :yymmdd, :ddmmmyy)
      #=> "27MAR26"

      Bourse.Symbol.convert_date("27MAR26", :ddmmmyy, :yymmdd)
      #=> "260327"

      Bourse.Symbol.convert_date("260327", :yymmdd, :yyyymmdd)
      #=> "20260327"
  """
  @spec convert_date(String.t(), atom(), atom()) :: String.t()
  def convert_date(date_str, format, format), do: date_str

  def convert_date(<<yy::binary-2, mm::binary-2, dd::binary-2>>, :yymmdd, :ddmmmyy) do
    month = String.to_integer(mm)
    day = String.to_integer(dd)
    "#{day}#{Map.fetch!(@month_abbrevs, month)}#{yy}"
  end

  def convert_date(date_str, :ddmmmyy, :yymmdd) do
    date_upper = String.upcase(date_str)

    case Regex.run(~r/^(\d{1,2})([A-Z]{3})(\d{2})$/, date_upper) do
      [_, day_str, month_str, year_str] ->
        month = Map.fetch!(@month_numbers, month_str)
        day = String.to_integer(day_str)
        "#{year_str}#{pad_two(month)}#{pad_two(day)}"

      _ ->
        date_str
    end
  end

  def convert_date(<<_century::binary-2, rest::binary>>, :yyyymmdd, :yymmdd), do: rest
  def convert_date(date_str, :yymmdd, :yyyymmdd), do: "20#{date_str}"

  def convert_date(date_str, :yyyymmdd, :ddmmmyy) do
    date_str |> convert_date(:yyyymmdd, :yymmdd) |> convert_date(:yymmdd, :ddmmmyy)
  end

  def convert_date(date_str, :ddmmmyy, :yyyymmdd) do
    date_str |> convert_date(:ddmmmyy, :yymmdd) |> convert_date(:yymmdd, :yyyymmdd)
  end

  # ===========================================================================
  # Market Type Detection
  # ===========================================================================

  @doc """
  Detects market type from parsed extended symbol components.

  Priority: option > future > swap > spot.

  Accepts `%Bourse.Symbol.ParsedSymbol{}` (from `parse_extended/1`) or a map with
  the same keys for call-site convenience.
  """
  @spec detect_market_type(parsed_extended() | map()) :: :spot | :swap | :future | :option
  def detect_market_type(%ParsedSymbol{} = parsed) do
    cond do
      parsed.option_type != nil -> :option
      parsed.expiry != nil -> :future
      parsed.settle != nil -> :swap
      true -> :spot
    end
  end

  def detect_market_type(%{option_type: option_type, expiry: expiry, settle: settle}) do
    cond do
      option_type != nil -> :option
      expiry != nil -> :future
      settle != nil -> :swap
      true -> :spot
    end
  end

  def detect_market_type(other) do
    raise ArgumentError,
          "Bourse.Symbol.detect_market_type/1 expects a %Bourse.Symbol.ParsedSymbol{} (from parse_extended/1), got: #{inspect(other)}"
  end

  # ===========================================================================
  # Private: Pair Parsing
  # ===========================================================================

  defp parse_pair(pair, settle) do
    case String.split(pair, "/") do
      [base, quote_currency] when base != "" and quote_currency != "" ->
        {:ok, %{base: base, quote: quote_currency, settle: settle}}

      _ ->
        {:error, :invalid_format}
    end
  end

  # ===========================================================================
  # Private: Extended Parsing
  # ===========================================================================

  # Simple pair like "BTC/USDT" (no derivative suffix)
  defp parse_extended_pair(pair, nil) do
    case String.split(pair, "/") do
      [base, quote_currency] when base != "" and quote_currency != "" ->
        {:ok,
         %ParsedSymbol{
           base: base,
           quote: quote_currency,
           settle: nil,
           expiry: nil,
           strike: nil,
           option_type: nil
         }}

      _ ->
        {:error, :invalid_format}
    end
  end

  # Pair with derivative suffix like "BTC/USDT" + "USDT-260327"
  defp parse_extended_pair(pair, settle_and_rest) do
    case String.split(pair, "/") do
      [base, quote_currency] when base != "" and quote_currency != "" ->
        parse_derivative_suffix(base, quote_currency, settle_and_rest)

      _ ->
        {:error, :invalid_format}
    end
  end

  # Parses "USDT" or "USDT-260327" or "BTC-260112-84000-C"
  defp parse_derivative_suffix(base, quote_currency, settle_and_rest) do
    parts = String.split(settle_and_rest, "-")

    case parts do
      [settle] ->
        {:ok,
         %ParsedSymbol{
           base: base,
           quote: quote_currency,
           settle: settle,
           expiry: nil,
           strike: nil,
           option_type: nil
         }}

      [settle, expiry] ->
        {:ok,
         %ParsedSymbol{
           base: base,
           quote: quote_currency,
           settle: settle,
           expiry: expiry,
           strike: nil,
           option_type: nil
         }}

      [settle, expiry, strike, option_type] ->
        {:ok,
         %ParsedSymbol{
           base: base,
           quote: quote_currency,
           settle: settle,
           expiry: expiry,
           strike: strike,
           option_type: option_type
         }}

      _ ->
        {:error, :invalid_format}
    end
  end

  # ===========================================================================
  # Private: Currency Alias Application
  # ===========================================================================

  defp apply_currency_aliases(symbol, aliases) when map_size(aliases) == 0, do: symbol

  defp apply_currency_aliases(symbol, aliases) do
    Enum.reduce(aliases, symbol, fn {from, to}, acc ->
      String.replace(acc, from, to)
    end)
  end

  # ===========================================================================
  # Private: No-Separator Splitting
  # ===========================================================================

  # Splits "BTCUSDT" into "BTC/USDT" by finding known quote currency at end
  defp find_and_split(symbol, custom_currencies) when is_binary(symbol) do
    currencies = if custom_currencies, do: get_quote_currencies(custom_currencies), else: @sorted_quote_currencies
    if String.contains?(symbol, "/"), do: symbol, else: split_by_quote(symbol, currencies)
  end

  defp split_by_quote(symbol, currencies) do
    case Enum.find(currencies, &String.ends_with?(symbol, &1)) do
      nil -> symbol
      quote_currency -> build_split(symbol, quote_currency)
    end
  end

  defp build_split(symbol, quote_currency) do
    base = String.replace_suffix(symbol, quote_currency, "")
    if base == "", do: symbol, else: "#{base}/#{quote_currency}"
  end

  # ===========================================================================
  # Private: Prefix Handling
  # ===========================================================================

  defp find_matching_prefix(symbol, prefixes) do
    Enum.find_value(prefixes, fn prefix ->
      if String.starts_with?(symbol, prefix) do
        {prefix, String.replace_prefix(symbol, prefix, "")}
      end
    end)
  end

  # Kraken X/Z currency prefixes
  defp strip_currency_prefix(symbol) do
    cond do
      # XXBT → X + XBT (doubled X prefix for crypto)
      String.starts_with?(symbol, "XX") ->
        {"X", String.slice(symbol, 1..-1//1)}

      # ZUSD → Z + USD (fiat prefix, only for 4-char codes)
      String.starts_with?(symbol, "Z") and String.length(symbol) == 4 ->
        {"Z", String.slice(symbol, 1..-1//1)}

      true ->
        {nil, symbol}
    end
  end

  # ===========================================================================
  # Exchange ID Conversion (unified ↔ exchange)
  # ===========================================================================

  @doc """
  Converts a unified symbol to exchange-specific ID.

  For Binance COIN-M and grammars with an authored quote-settled suffix,
  resolves the exact native ID from loaded markets before using the exchange's
  `symbol_patterns` to handle spot, swap, future, and option symbols. Returns
  the unified symbol unchanged when no pattern config exists.

  Outbound currency aliases come from `exchange.outbound_aliases` (default
  `%{}`), populated only for exchanges that accept the alias on input
  (e.g. Kraken: `BTC` → `XBT`). Inbound aliasing (`from_exchange_id`) uses
  `common_currencies` directly — that direction is universal.

  ## Parameters

  - `unified_symbol` - The unified symbol (e.g., "BTC/USDT:USDT-260327")
  - `exchange` - A `%Bourse.Exchange{}` struct with `symbol_patterns` populated

  ## Examples

      Bourse.Symbol.to_exchange_id("BTC/USDT", binance_exchange)
      #=> "BTCUSDT"

      Bourse.Symbol.to_exchange_id("BTC/USD:BTC-260112-84000-C", deribit_exchange)
      #=> "BTC-12JAN26-84000-C"

  """
  @spec to_exchange_id(String.t(), Bourse.Exchange.t()) :: String.t()
  def to_exchange_id(unified_symbol, %Bourse.Exchange{} = exchange) when is_binary(unified_symbol) do
    case loaded_market_id(exchange, unified_symbol) do
      nil -> to_exchange_id_from_pattern(unified_symbol, exchange)
      exchange_id -> exchange_id
    end
  end

  @doc """
  Converts a unified symbol to exchange-specific ID, raising on failure.
  """
  @spec to_exchange_id!(String.t(), Bourse.Exchange.t()) :: String.t()
  def to_exchange_id!(unified_symbol, %Bourse.Exchange{} = exchange) when is_binary(unified_symbol) do
    case loaded_market_id(exchange, unified_symbol) do
      nil -> to_exchange_id_from_pattern!(unified_symbol, exchange)
      exchange_id -> exchange_id
    end
  end

  defp to_exchange_id_from_pattern(unified_symbol, exchange) do
    case parse_extended(unified_symbol) do
      {:ok, parsed} ->
        market_type = detect_market_type(parsed)

        case Map.get(exchange.symbol_patterns, market_type) do
          nil -> unified_symbol
          config -> apply_pattern(parsed, config, exchange.outbound_aliases)
        end

      {:error, _} ->
        unified_symbol
    end
  end

  defp to_exchange_id_from_pattern!(unified_symbol, exchange) do
    case parse_extended(unified_symbol) do
      {:ok, parsed} ->
        market_type = detect_market_type(parsed)

        case Map.get(exchange.symbol_patterns, market_type) do
          nil -> raise SymbolError.pattern_not_found(unified_symbol, market_type, exchange.id)
          config -> apply_pattern(parsed, config, exchange.outbound_aliases)
        end

      {:error, _} ->
        raise SymbolError.invalid_format(unified_symbol)
    end
  end

  defp loaded_market_id(%Bourse.Exchange{id: "binancecoinm", markets: markets}, unified_symbol) when is_list(markets) do
    Enum.find_value(markets, &exact_loaded_market_id(&1, unified_symbol))
  end

  defp loaded_market_id(%Bourse.Exchange{markets: markets, symbol_patterns: patterns}, unified_symbol)
       when is_list(markets) do
    suffixes =
      patterns
      |> Map.values()
      |> Enum.map(fn
        config when is_map(config) -> Map.get(config, :quote_settled_suffix)
        _other -> nil
      end)
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    Enum.find_value(markets, &loaded_market_id(&1, unified_symbol, suffixes))
  end

  defp loaded_market_id(_exchange, _unified_symbol), do: nil

  defp exact_loaded_market_id(%{symbol: symbol, id: exchange_id}, symbol) when is_binary(exchange_id), do: exchange_id

  defp exact_loaded_market_id(%{"symbol" => symbol, "id" => exchange_id}, symbol) when is_binary(exchange_id),
    do: exchange_id

  defp exact_loaded_market_id(_market, _unified_symbol), do: nil

  defp loaded_market_id(%{symbol: symbol, id: exchange_id}, symbol, suffixes) when is_binary(exchange_id) do
    if Enum.any?(suffixes, &String.contains?(exchange_id, &1)), do: exchange_id
  end

  defp loaded_market_id(%{"symbol" => symbol, "id" => exchange_id}, symbol, suffixes) when is_binary(exchange_id) do
    if Enum.any?(suffixes, &String.contains?(exchange_id, &1)), do: exchange_id
  end

  defp loaded_market_id(_market, _unified_symbol, _suffixes), do: nil

  @doc """
  Converts an exchange-specific ID to unified symbol format.

  Requires `market_type` since exchange IDs are ambiguous without context.

  ## Contract (identity, unified conversion, or raise)

  Under the selected pattern the result is one of:

  1. **Identity** — the pattern grammar does not match (e.g. Deribit combo
     ids under `:option` / `:future`); the input id is returned **unchanged**.
     No intermediate rewrite (upcase, `d`→`D`) is emitted.
  2. **Unified conversion** — a unified symbol containing `/` (grammar matched).
  3. **Raise** — a non-identity rewrite that is still exchange-id-shaped (no
     `/`). That is silent corruption from a partial transform, not a soft
     fallback.

  This is the public-API counterpart of carve C27: combo native ids are not a
  special-cased branch here; they take the identity path because the single-leg
  grammar cannot represent them.

  ## Parameters

  - `exchange_id` - The exchange-specific ID (e.g., "BTCUSDT_260327")
  - `exchange` - A `%Bourse.Exchange{}` struct with `symbol_patterns` populated
  - `market_type` - The market type (`:spot`, `:swap`, `:future`, `:option`)

  ## Examples

      Bourse.Symbol.from_exchange_id("BTCUSDT", binance_exchange, :spot)
      #=> "BTC/USDT"

      Bourse.Symbol.from_exchange_id("BTC-PERPETUAL", deribit_exchange, :swap)
      #=> "BTC/USD:BTC"

      Bourse.Symbol.from_exchange_id("BTC-12JAN26-84000-C", deribit_exchange, :option)
      #=> "BTC/USD:BTC-260112-84000-C"

  """
  @spec from_exchange_id(String.t(), Bourse.Exchange.t(), atom()) :: String.t()
  def from_exchange_id(exchange_id, %Bourse.Exchange{} = exchange, market_type)
      when is_binary(exchange_id) and is_atom(market_type) do
    config = Map.get(exchange.symbol_patterns, market_type)

    if config do
      exchange_id
      |> reverse_pattern(config, market_type, exchange.common_currencies)
      |> maybe_reverse_full_date_option(exchange_id, exchange, market_type)
      |> ensure_from_exchange_conversion!(exchange_id, exchange, market_type)
    else
      # No pattern config for this market type — return unchanged rather than
      # applying lossy spot conversion that strips derivative context
      exchange_id
    end
  end

  @doc """
  Converts an exchange-specific ID to unified symbol, raising on failure.

  Same conversion contract as `from_exchange_id/3`. Also raises when no pattern
  config exists for `market_type`.
  """
  @spec from_exchange_id!(String.t(), Bourse.Exchange.t(), atom()) :: String.t()
  def from_exchange_id!(exchange_id, %Bourse.Exchange{} = exchange, market_type)
      when is_binary(exchange_id) and is_atom(market_type) do
    config = Map.get(exchange.symbol_patterns, market_type)

    if config do
      exchange_id
      |> reverse_pattern(config, market_type, exchange.common_currencies)
      |> maybe_reverse_full_date_option(exchange_id, exchange, market_type)
      |> ensure_from_exchange_conversion!(exchange_id, exchange, market_type)
    else
      raise SymbolError.pattern_not_found(exchange_id, market_type, exchange.id)
    end
  end

  # Accept identity (grammar no-match) or a unified symbol (grammar matched).
  # Reject non-identity rewrites that are still exchange-id-shaped — those are
  # partial transforms (e.g. upcase-only) that look plausible but resolve nowhere.
  defp ensure_from_exchange_conversion!(converted, original, exchange, market_type) do
    cond do
      converted == original ->
        converted

      String.contains?(converted, "/") ->
        converted

      true ->
        raise SymbolError.unrepresentable_id(original, converted, exchange.id, market_type)
    end
  end

  # Multi-row read paths can only infer `:swap` from an unannotated dash id. The
  # authored Derive full-date option grammar is disjoint, so retry that one
  # pattern when the coarse classification produced identity.
  defp maybe_reverse_full_date_option(converted, original, exchange, market_type)
       when converted == original and market_type != :option do
    case Map.get(exchange.symbol_patterns, :option) do
      %{pattern: :option_base_yyyymmdd} = config ->
        reverse_pattern(original, config, :option, exchange.common_currencies)

      _other ->
        converted
    end
  end

  defp maybe_reverse_full_date_option(converted, _original, _exchange, _market_type), do: converted

  # ===========================================================================
  # Private: Apply Pattern (unified → exchange)
  # ===========================================================================

  # Dispatches to market-type-specific pattern application
  defp apply_pattern(parsed, config, forward_aliases) do
    base = apply_forward_alias(parsed.base, forward_aliases)
    quote_aliased = apply_forward_alias(parsed.quote, forward_aliases)
    parsed = %{parsed | base: base, quote: quote_aliased}
    pattern = config.pattern

    cond do
      pattern in @spot_patterns -> apply_spot_pattern(parsed, config)
      pattern in @swap_patterns -> apply_swap_pattern(parsed, config)
      pattern in @future_patterns -> apply_future_pattern(parsed, config)
      pattern in @option_patterns -> apply_option_pattern(parsed, config)
      true -> "#{base}#{config.separator}#{parsed.quote}"
    end
  end

  # Spot: separator + case + optional prefix
  defp apply_spot_pattern(parsed, config) do
    result = "#{parsed.base}#{config.separator}#{parsed.quote}"

    result =
      if config.pattern in [:no_separator_mixed, :underscore_mixed, :dash_mixed, :colon_mixed] do
        result
      else
        apply_case(result, config.case)
      end

    apply_prefix(result, config.prefix)
  end

  # Swap: suffix handling (implicit, perpetual, swap, perp)
  # Inverse / USD-quoted perps use a base-only id:
  #   deribit `BTC-PERPETUAL`, derive `BTC-PERP`.
  # Linear non-USD-quoted perps keep base+quote (e.g. ADA_USDC-PERPETUAL).
  # The discriminator is quote == "USD", NOT the separator char — deribit's
  # separator is "_" (for the linear form), so gating base-only on
  # `separator == "-"` produced "BTC_USD-PERPETUAL" against the real spec and
  # the live API rejected it ("instrument is not open"). Same rule applies to
  # `:suffix_perp` (Derive's `-PERP` family).
  defp apply_swap_pattern(parsed, config) do
    quote_currency = native_quote_currency(parsed, config)

    result =
      case config.pattern do
        :implicit ->
          apply_case("#{parsed.base}#{config.separator}#{quote_currency}", config.case)

        pattern when pattern in [:suffix_perpetual, :suffix_perp] and parsed.quote == "USD" ->
          apply_case("#{parsed.base}#{config.suffix}", config.case)

        _suffix_pattern ->
          apply_case("#{parsed.base}#{config.separator}#{quote_currency}#{config.suffix}", config.case)
      end

    apply_prefix(result, config.prefix)
  end

  # Future: date format dispatch
  # Note: for YYMMDD/YYYYMMDD, pair separator may differ from date separator.
  # Binance: BTCUSDT_260327 (pair has no sep, date uses "_")
  # OKX: BTC-USD-260327 (all parts use "-")
  defp apply_future_pattern(parsed, config) do
    result =
      case config.pattern do
        :future_yymmdd ->
          {pair_sep, date_sep} = future_separators(config.separator)
          quote_currency = native_quote_currency(parsed, config)

          apply_case(
            "#{parsed.base}#{pair_sep}#{quote_currency}#{date_sep}#{parsed.expiry}",
            config.case
          )

        :future_ddmmmyy ->
          apply_future_ddmmmyy(parsed, config)

        :future_yyyymmdd ->
          {pair_sep, date_sep} = future_separators(config.separator)
          expiry = convert_date(parsed.expiry, :yymmdd, :yyyymmdd)

          apply_case(
            "#{parsed.base}#{pair_sep}#{parsed.quote}#{date_sep}#{expiry}",
            config.case
          )

        :future_unknown ->
          apply_case(
            "#{parsed.base}#{config.separator}#{parsed.quote}#{config.separator}#{parsed.expiry}",
            config.case
          )
      end

    apply_prefix(result, config.prefix)
  end

  # Binance-style: "_" separates pair from date, but pair itself has no separator
  # OKX-style: "-" separates all components uniformly
  defp future_separators("_"), do: {"", "_"}
  defp future_separators(sep), do: {sep, sep}

  # DDMMMYY future: Deribit inverse (BTC-16JAN26), Deribit linear
  # (BTC_USDC-16JAN26), and Bybit style (BTCUSDT-16JAN26).
  defp apply_future_ddmmmyy(parsed, config) do
    expiry_converted = convert_date(parsed.expiry, :yymmdd, :ddmmmyy)

    result =
      cond do
        parsed.quote == "USD" and parsed.settle == parsed.base ->
          "#{parsed.base}-#{expiry_converted}"

        config.separator == "_" and parsed.quote == "USDC" and parsed.settle == "USDC" ->
          "#{parsed.base}_#{parsed.quote}-#{expiry_converted}"

        true ->
          "#{parsed.base}#{parsed.quote}-#{expiry_converted}"
      end

    apply_case(result, config.case)
  end

  # Option: Deribit/OKX/Bybit formatting
  defp apply_option_pattern(parsed, config) do
    result =
      case config.pattern do
        :option_ddmmmyy ->
          expiry = convert_date(parsed.expiry, :yymmdd, :ddmmmyy)

          if config.separator == "_" and parsed.quote == "USDC" and parsed.settle == "USDC" do
            strike = encode_deribit_decimal_strike(parsed.strike)
            base = apply_case(parsed.base, config.case)
            quote = apply_case(parsed.quote, config.case)
            option_type = apply_case(parsed.option_type, config.case)

            "#{base}_#{quote}-#{expiry}-#{strike}-#{option_type}"
          else
            apply_case("#{parsed.base}-#{expiry}-#{parsed.strike}-#{parsed.option_type}", config.case)
          end

        :option_yymmdd ->
          quote_currency = native_quote_currency(parsed, config)

          apply_case(
            "#{parsed.base}-#{quote_currency}-#{parsed.expiry}-#{parsed.strike}-#{parsed.option_type}",
            config.case
          )

        pattern when pattern in [:option_base_yymmdd, :option_base_yyyymmdd] ->
          expiry = option_base_expiry(parsed.expiry, pattern)
          apply_case("#{parsed.base}-#{expiry}-#{parsed.strike}-#{parsed.option_type}", config.case)

        :option_with_settle ->
          expiry = convert_date(parsed.expiry, :yymmdd, :ddmmmyy)

          parsed
          |> option_with_settle_id(expiry)
          |> apply_case(config.case)

        :option_unknown ->
          apply_case(
            "#{parsed.base}-#{parsed.expiry}-#{parsed.strike}-#{parsed.option_type}",
            config.case
          )
      end

    apply_prefix(result, config.prefix)
  end

  defp option_base_expiry(expiry, :option_base_yymmdd), do: expiry
  defp option_base_expiry(expiry, :option_base_yyyymmdd), do: convert_date(expiry, :yymmdd, :yyyymmdd)

  # ===========================================================================
  # Private: Reverse Pattern (exchange → unified)
  # ===========================================================================

  # Main dispatcher for exchange ID → unified symbol conversion
  defp reverse_pattern(exchange_id, config, market_type, aliases) do
    case market_type do
      :spot -> reverse_spot(exchange_id, config, aliases)
      :swap -> reverse_swap(exchange_id, config, aliases)
      :future -> reverse_future(exchange_id, config, aliases)
      :option -> reverse_option(exchange_id, config, aliases)
      _ -> exchange_id
    end
  end

  # Spot: "BTCUSDT" → "BTC/USDT"
  defp reverse_spot(exchange_id, config, aliases) do
    id = exchange_id |> strip_pattern_prefix(config) |> String.upcase()
    sep = config.separator

    {base, quote_currency} =
      if sep == "" do
        split_no_separator(id, aliases)
      else
        case String.split(id, sep) do
          [b, q] -> {b, q}
          _ -> {id, ""}
        end
      end

    # Unsplittable derivative ids (e.g. BTCUSD_PERP under a spot no-separator config)
    # must not become "BTCUSD_PERP/" via build/2 with an empty quote.
    if quote_currency == "" do
      exchange_id
    else
      base = apply_reverse_alias(base, aliases)
      build(base, quote_currency)
    end
  end

  # Swap: "BTC-PERPETUAL" → "BTC/USD:BTC"
  defp reverse_swap(exchange_id, config, aliases) do
    id = exchange_id |> strip_pattern_prefix(config) |> String.upcase()

    # Remove suffix if present
    id_without_suffix =
      case config.suffix do
        nil -> id
        suffix -> String.replace_suffix(id, String.upcase(suffix), "")
      end

    sep = config.separator

    {base, quote_currency} =
      if sep == "" do
        split_no_separator(id_without_suffix, aliases)
      else
        case String.split(id_without_suffix, sep) do
          [b, q] -> {b, q}
          [b] -> {b, "USD"}
          _ -> {id_without_suffix, ""}
        end
      end

    # Same guard as reverse_spot: never emit a trailing-slash unified form when the
    # pair cannot be split (coin-m ids under a linear/implicit swap pattern).
    if quote_currency == "" do
      exchange_id
    else
      base = apply_reverse_alias(base, aliases)
      {quote_currency, quote_settled?} = unified_quote_currency(quote_currency, config)

      settle =
        if quote_settled?,
          do: quote_currency,
          else: swap_settle(config.pattern, base, quote_currency)

      build(base, quote_currency, settle)
    end
  end

  # Deribit's inverse USD perps (BTC-PERPETUAL) settle in base. Its linear
  # USDC perps (1000BONK_USDC-PERPETUAL) settle in quote. Derive's BASE-PERP
  # family is linear USDC-settled with a USD quote (BTC/USD:USDC).
  defp swap_settle(:suffix_perp, _base, _quote), do: "USDC"
  defp swap_settle(_pattern, base, "USD"), do: base
  defp swap_settle(_pattern, _base, quote), do: quote

  # Future: dispatch by date format.
  # No-match returns the original exchange_id (not the uppercased intermediate)
  # so unrepresentable ids (e.g. Deribit future_combo) stay verbatim.
  defp reverse_future(exchange_id, config, aliases) do
    id = exchange_id |> strip_pattern_prefix(config) |> String.upcase()

    result =
      case config.date_format do
        :ddmmmyy -> reverse_future_ddmmmyy(id, config, aliases)
        :yymmdd -> reverse_future_yymmdd(id, config, aliases)
        :yyyymmdd -> reverse_future_yyyymmdd(id, config, aliases)
        _ -> nil
      end

    result || exchange_id
  end

  # DDMMMYY future: try Deribit linear (BTC_USDC-16JAN26), Bybit
  # (BTCUSDT-16JAN26), then Deribit inverse (BTC-16JAN26).
  defp reverse_future_ddmmmyy(id, _config, aliases) do
    deribit_linear_result = parse_deribit_linear_future(id, aliases)
    bybit_result = parse_bybit_future(id, aliases)
    deribit_result = parse_deribit_future(id, aliases)

    cond do
      deribit_linear_result != nil -> deribit_linear_result
      bybit_result != nil -> bybit_result
      deribit_result != nil -> deribit_result
      true -> nil
    end
  end

  # Deribit linear USDC: BTC_USDC-16JAN26 → BTC/USDC:USDC-260116
  defp parse_deribit_linear_future(id, aliases) do
    ~r/^([A-Z]+)_([A-Z]+)-(\d{1,2}[A-Z]{3}\d{2})$/
    |> Regex.run(id)
    |> build_quote_settled_ddmmmyy_future(aliases)
  end

  # Deribit: BTC-16JAN26 → BTC/USD:BTC-260116
  defp parse_deribit_future(id, aliases) do
    case Regex.run(~r/^([A-Z]+)-(\d{1,2}[A-Z]{3}\d{2})$/, id) do
      [_, base, date] ->
        base = apply_reverse_alias(base, aliases)
        expiry = convert_date(date, :ddmmmyy, :yymmdd)
        build(base, "USD", "#{base}-#{expiry}")

      _ ->
        nil
    end
  end

  # Bybit: BTCUSDT-16JAN26 → BTC/USDT:USDT-260116
  defp parse_bybit_future(id, aliases) do
    ~r/^([A-Z]+)(USDT|USDC|USD)-(\d{1,2}[A-Z]{3}\d{2})$/
    |> Regex.run(id)
    |> build_quote_settled_ddmmmyy_future(aliases)
  end

  # Shared tail for the two DDMMMYY id shapes that carry an explicit quote and
  # settle in it: Deribit linear (BASE_QUOTE-DDMMMYY) and Bybit (BASEQUOTE-DDMMMYY).
  defp build_quote_settled_ddmmmyy_future([_, base, quote_currency, date], aliases) do
    base = apply_reverse_alias(base, aliases)
    expiry = convert_date(date, :ddmmmyy, :yymmdd)
    build(base, quote_currency, "#{quote_currency}-#{expiry}")
  end

  defp build_quote_settled_ddmmmyy_future(_no_match, _aliases), do: nil

  # YYMMDD future: Binance (BTCUSDT_260327) or OKX (BTC-USD-260327)
  defp reverse_future_yymmdd(id, config, aliases) do
    sep = config.separator
    parts = String.split(id, sep)

    case parts do
      # reach:disable-next-line suboptimal — sep is config-derived, not the case subject; can't hoist to head
      [pair, date] when sep == "_" ->
        {base, quote_currency} = split_no_separator(pair, aliases)
        base = apply_reverse_alias(base, aliases)
        build(base, quote_currency, "#{quote_currency}-#{date}")

      [base, quote_currency, date] ->
        base = apply_reverse_alias(base, aliases)
        {quote_currency, quote_settled?} = unified_quote_currency(quote_currency, config)
        settle = future_settle(base, quote_currency, quote_settled?)
        build(base, quote_currency, "#{settle}-#{date}")

      _ ->
        nil
    end
  end

  # YYYYMMDD future: dates are 8 digits (e.g., "20260327"). The unified format
  # uses YYMMDD ("260327"), so convert the trailing date via convert_date/3
  # and split identically to the YYMMDD handler.
  defp reverse_future_yyyymmdd(id, config, aliases) do
    sep = config.separator
    parts = String.split(id, sep)

    case parts do
      [pair, date] when byte_size(date) == 8 ->
        yymmdd_date = convert_date(date, :yyyymmdd, :yymmdd)
        {base, quote_currency} = split_no_separator(pair, aliases)
        base = apply_reverse_alias(base, aliases)
        build(base, quote_currency, "#{quote_currency}-#{yymmdd_date}")

      [base, quote_currency, date] when byte_size(date) == 8 ->
        yymmdd_date = convert_date(date, :yyyymmdd, :yymmdd)
        base = apply_reverse_alias(base, aliases)
        settle = if quote_currency in ["USD", "USDC"], do: base, else: quote_currency
        build(base, quote_currency, "#{settle}-#{yymmdd_date}")

      _ ->
        nil
    end
  end

  # Option: dispatch by pattern type.
  # No-match returns the original exchange_id (not the uppercased intermediate)
  # so unrepresentable ids (e.g. Deribit option_combo with C24 d-strikes) stay
  # verbatim instead of being silently rewritten.
  defp reverse_option(exchange_id, config, aliases) do
    id = exchange_id |> strip_pattern_prefix(config) |> String.upcase()

    result =
      case config.pattern do
        :option_ddmmmyy -> reverse_option_ddmmmyy(id, aliases)
        :option_yymmdd -> reverse_option_yymmdd(id, aliases, config)
        :option_base_yymmdd -> reverse_option_base_yymmdd(id, aliases)
        :option_base_yyyymmdd -> reverse_option_base_yyyymmdd(id, aliases)
        :option_with_settle -> reverse_option_with_settle(id, aliases)
        _ -> nil
      end

    result || exchange_id
  end

  # Deribit: BTC-12JAN26-84000-C → BTC/USD:BTC-260112-84000-C
  # Deribit linear: AVAX_USDC-22JUN26-5d5-C → AVAX/USDC:USDC-260622-5.5-C
  defp reverse_option_ddmmmyy(id, aliases) do
    case Regex.run(~r/^([A-Z]+)_([A-Z]+)-(\d{1,2}[A-Z]{3}\d{2})-(\d+(?:D\d+)?)-([CP])$/, id) do
      [_, base, quote_currency, date, strike, opt_type] ->
        base = apply_reverse_alias(base, aliases)
        expiry = convert_date(date, :ddmmmyy, :yymmdd)
        strike = decode_deribit_decimal_strike(strike)
        build(base, quote_currency, "#{quote_currency}-#{expiry}-#{strike}-#{opt_type}")

      _ ->
        reverse_inverse_option_ddmmmyy(id, aliases)
    end
  end

  defp reverse_inverse_option_ddmmmyy(id, aliases) do
    case Regex.run(~r/^([A-Z]+)-(\d{1,2}[A-Z]{3}\d{2})-(\d+)-([CP])$/, id) do
      [_, base, date, strike, opt_type] ->
        base = apply_reverse_alias(base, aliases)
        expiry = convert_date(date, :ddmmmyy, :yymmdd)
        build(base, "USD", "#{base}-#{expiry}-#{strike}-#{opt_type}")

      _ ->
        nil
    end
  end

  defp encode_deribit_decimal_strike(strike) do
    strike
    |> normalize_decimal_string()
    |> String.replace(".", "d")
  end

  defp decode_deribit_decimal_strike(strike) do
    strike
    |> String.replace("D", ".")
    |> normalize_decimal_string()
  end

  defp normalize_decimal_string(value) do
    value
    |> Decimal.new()
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  rescue
    Decimal.Error -> value
  end

  # OKX: BTC-USD-260112-80000-C → BTC/USD:BTC-260112-80000-C
  defp reverse_option_yymmdd(id, aliases, config) do
    case Regex.run(~r/^([A-Z]+)-([A-Z_]+)-(\d{6})-(\d+(?:\.\d+)?)-([CP])$/, id) do
      [_, base, quote_currency, date, strike, opt_type] ->
        base = apply_reverse_alias(base, aliases)
        {quote_currency, quote_settled?} = unified_quote_currency(quote_currency, config)
        settle = option_settle(base, quote_currency, quote_settled?)
        build(base, quote_currency, "#{settle}-#{date}-#{strike}-#{opt_type}")

      _ ->
        nil
    end
  end

  defp native_quote_currency(parsed, config) do
    case Map.get(config, :quote_settled_suffix) do
      suffix
      when is_binary(suffix) and suffix != "" and parsed.quote == "USD" and
             parsed.settle == parsed.quote ->
        parsed.quote <> suffix

      _other ->
        parsed.quote
    end
  end

  defp unified_quote_currency(native_quote, config) do
    case Map.get(config, :quote_settled_suffix) do
      suffix when is_binary(suffix) and suffix != "" ->
        split_quote_settled_suffix(native_quote, suffix)

      _other ->
        {native_quote, false}
    end
  end

  defp split_quote_settled_suffix(native_quote, suffix) do
    case String.split(native_quote, suffix, parts: 2) do
      [quote_currency, ""] when quote_currency != "" ->
        {quote_currency, true}

      [quote_currency, <<"_", _native_family::binary>>] when quote_currency != "" ->
        {quote_currency, true}

      _other ->
        {native_quote, false}
    end
  end

  defp future_settle(_base, quote_currency, true), do: quote_currency
  defp future_settle(base, quote_currency, false) when quote_currency in ["USD", "USDC"], do: base
  defp future_settle(_base, quote_currency, false), do: quote_currency

  defp option_settle(_base, quote_currency, true), do: quote_currency
  defp option_settle(base, "USD", false), do: base
  defp option_settle(_base, quote_currency, false), do: quote_currency

  # Binance EAPI: BTC-260925-145000-C → BTC/USDT:USDT-260925-145000-C
  defp reverse_option_base_yymmdd(id, aliases) do
    case Regex.run(~r/^([A-Z]+)-(\d{6})-(\d+(?:\.\d+)?)-([CP])$/, id) do
      [_, base, date, strike, opt_type] ->
        base = apply_reverse_alias(base, aliases)
        build(base, "USDT", "USDT-#{date}-#{strike}-#{opt_type}")

      _ ->
        nil
    end
  end

  # Derive: ZEC-20260925-800-P → ZEC/USDC:USDC-260925-800-P
  defp reverse_option_base_yyyymmdd(id, aliases) do
    case Regex.run(~r/^([A-Z]+)-(\d{8})-(\d+(?:\.\d+)?)-([CP])$/, id) do
      [_, base, date, strike, opt_type] ->
        base = apply_reverse_alias(base, aliases)
        expiry = convert_date(date, :yyyymmdd, :yymmdd)
        build(base, "USDC", "USDC-#{expiry}-#{strike}-#{opt_type}")

      _no_match ->
        nil
    end
  end

  # Bybit: BTC-25DEC26-105000-P-USDT → BTC/USDT:USDT-261225-105000-P
  defp reverse_option_with_settle(id, aliases) do
    case Regex.run(~r/^([A-Z]+)-(\d{1,2}[A-Z]{3}\d{2})-(\d+)-([CP])(?:-([A-Z]+))?$/, id) do
      [_, base, date, strike, opt_type, settle] ->
        base = apply_reverse_alias(base, aliases)
        expiry = convert_date(date, :ddmmmyy, :yymmdd)
        build(base, settle, "#{settle}-#{expiry}-#{strike}-#{opt_type}")

      [_, base, date, strike, opt_type] ->
        base = apply_reverse_alias(base, aliases)
        expiry = convert_date(date, :ddmmmyy, :yymmdd)
        build(base, "USDC", "USDC-#{expiry}-#{strike}-#{opt_type}")

      _ ->
        nil
    end
  end

  # Bybit names its USDC-settled option generation bare (BTC-27DEC24-55000-P), settlement
  # implied; only USDT-settled ids carry a settle suffix. Verified against the venue's own
  # namespace — GET /v5/market/instruments-info?category=option returns zero `-USDC` ids.
  defp option_with_settle_id(%{settle: "USDC"} = parsed, expiry) do
    "#{parsed.base}-#{expiry}-#{parsed.strike}-#{parsed.option_type}"
  end

  defp option_with_settle_id(parsed, expiry) do
    "#{parsed.base}-#{expiry}-#{parsed.strike}-#{parsed.option_type}-#{parsed.settle}"
  end

  # ===========================================================================
  # Private: Conversion Helpers
  # ===========================================================================

  # Case transformation
  defp apply_case(str, :upper), do: String.upcase(str)
  defp apply_case(str, :lower), do: String.downcase(str)
  defp apply_case(str, _), do: str

  # Prefix handling
  defp apply_prefix(result, nil), do: result
  defp apply_prefix(result, prefix), do: prefix <> result

  # Strip prefix from exchange ID (case-insensitive match)
  defp strip_pattern_prefix(id, config) do
    case config[:prefix] do
      nil ->
        id

      prefix ->
        if String.starts_with?(String.downcase(id), String.downcase(prefix)) do
          String.slice(id, String.length(prefix)..-1//1)
        else
          id
        end
    end
  end

  # Forward alias: unified → exchange (e.g., BTC → XBT)
  defp apply_forward_alias(currency, forward) when map_size(forward) == 0, do: currency
  defp apply_forward_alias(currency, forward), do: Map.get(forward, currency, currency)

  # Reverse alias: exchange → unified (e.g., XBT → BTC)
  defp apply_reverse_alias(currency, aliases) when map_size(aliases) == 0, do: currency
  defp apply_reverse_alias(currency, aliases), do: Map.get(aliases, currency, currency)

  # No-separator splitting with alias-aware best-match selection
  defp split_no_separator(symbol, aliases) do
    all_matches =
      for q <- @sorted_quote_currencies, String.ends_with?(symbol, q) do
        {String.replace_suffix(symbol, q, ""), q}
      end

    case all_matches do
      [] -> {symbol, ""}
      [single] -> single
      multiple -> pick_best_split(multiple, aliases)
    end
  end

  # Prefer the split whose base is a known exchange currency (key in aliases)
  defp pick_best_split(matches, aliases) when map_size(aliases) == 0, do: hd(matches)

  defp pick_best_split(matches, aliases) do
    Enum.find(matches, hd(matches), fn {base, _quote} -> Map.has_key?(aliases, base) end)
  end

  # ===========================================================================
  # Private: Helpers
  # ===========================================================================

  defp pad_two(n) when n < 10, do: "0#{n}"
  defp pad_two(n), do: "#{n}"
end
