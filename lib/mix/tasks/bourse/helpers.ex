defmodule Mix.Tasks.Bourse.Helpers do
  @moduledoc false

  alias Bourse.WS.Config

  @type exchange_row :: %{
          id: String.t(),
          module: module() | nil,
          loaded: boolean(),
          ws: boolean(),
          signing_pattern: atom(),
          ws_subscription: atom() | nil,
          ws_auth: atom() | nil
        }

  @doc "Builds per-exchange metadata rows for bourse.exchanges and bourse.classify."
  @spec exchange_rows() :: [exchange_row()]
  def exchange_rows do
    Bourse.Spec.exchanges()
    |> Enum.sort()
    |> Enum.map(&build_exchange_row/1)
  end

  @doc "Resolves REST signing patterns for every compiled exchange."
  @spec signing_results() :: [{String.t(), atom(), map()}]
  def signing_results do
    Enum.map(Bourse.Spec.exchanges(), fn exchange_id ->
      spec = Bourse.Spec.load!(exchange_id)
      {pattern, config} = Bourse.Exchange.signing_from_spec(spec)
      {exchange_id, pattern, config}
    end)
  end

  @doc """
  Returns per-exchange currency-network catalog rows from the vendored specs.

  Each row is `{exchange_id, populated_currency_count, status}` where `status`
  is `:populated` when at least one currency carries a non-empty `networks`
  map, else `:empty`.
  """
  @spec currency_network_rows() :: [{String.t(), non_neg_integer(), :populated | :empty}]
  def currency_network_rows do
    Bourse.Spec.exchanges()
    |> Enum.sort()
    |> Enum.map(fn exchange_id ->
      spec = Bourse.Spec.load!(exchange_id)
      count = populated_currency_network_count(spec)
      status = if count > 0, do: :populated, else: :empty
      {exchange_id, count, status}
    end)
  end

  @doc """
  Returns a sample `{currency_code, network_code, network_map}` for `exchange_id`.

  Picks the first currency with a non-empty `networks` map. Returns `nil` when
  the exchange spec has no populated network metadata.
  """
  @spec currency_network_sample(String.t()) ::
          {String.t(), String.t(), map()} | nil
  def currency_network_sample(exchange_id) do
    exchange_id
    |> Bourse.Spec.load!()
    |> get_in(["markets", "currencies"])
    |> find_first_populated_network()
  end

  @doc "Prints a grouped pattern summary section to stdout."
  @spec print_pattern_section(String.t(), [{String.t(), atom(), term()}], keyword()) :: :ok
  def print_pattern_section(title, results, opts \\ []) do
    by_pattern = Enum.group_by(results, fn {_, pattern, _} -> pattern end)
    details_title = Keyword.get(opts, :details_title, "#{title} — Details")

    IO.puts("\n=== #{title} ===\n")

    by_pattern
    |> Enum.sort_by(fn {_pattern, entries} -> -length(entries) end)
    |> Enum.each(fn {pattern, entries} ->
      IO.puts("  #{format_pattern(pattern)} #{length(entries)} exchanges")
    end)

    IO.puts("\n  Total: #{length(results)} exchanges\n")

    IO.puts("=== #{details_title} ===\n")

    by_pattern
    |> Enum.sort_by(fn {pattern, _} -> Atom.to_string(pattern) end)
    |> Enum.each(fn {pattern, entries} ->
      ids = entries |> Enum.map(fn {id, _, _} -> id end) |> Enum.sort()
      IO.puts("  #{format_pattern(pattern)}")
      IO.puts("    #{Enum.join(ids, ", ")}\n")
    end)

    :ok
  end

  @doc "Formats a pattern atom for aligned task output."
  @spec format_pattern(atom()) :: String.t()
  def format_pattern(pattern) do
    String.pad_trailing(inspect(pattern), 40)
  end

  defp populated_currency_network_count(spec) do
    case get_in(spec, ["markets", "currencies"]) do
      currencies when is_map(currencies) -> count_populated_networks(currencies)
      _ -> 0
    end
  end

  defp count_populated_networks(currencies) do
    Enum.count(currencies, fn {_code, record} ->
      case record do
        %{"networks" => networks} when is_map(networks) -> map_size(networks) > 0
        _ -> false
      end
    end)
  end

  defp find_first_populated_network(nil), do: nil

  defp find_first_populated_network(currencies) do
    Enum.find_value(currencies, fn {currency_code, record} ->
      case record do
        %{"networks" => networks} when is_map(networks) and map_size(networks) > 0 ->
          {network_code, network_map} = hd(Map.to_list(networks))
          {currency_code, network_code, network_map}

        _ ->
          nil
      end
    end)
  end

  defp build_exchange_row(exchange_id) do
    spec = Bourse.Spec.load!(exchange_id)
    {signing_pattern, _} = Bourse.Exchange.signing_from_spec(spec)
    ws_config = Config.for_exchange(exchange_id)

    %{
      id: exchange_id,
      module: Bourse.Registry.module_for(exchange_id),
      loaded: Bourse.Registry.loaded?(exchange_id),
      ws: Config.supported?(exchange_id),
      signing_pattern: signing_pattern,
      ws_subscription: ws_config && ws_config[:subscription_pattern],
      ws_auth: ws_config && ws_config[:auth_pattern]
    }
  end
end
