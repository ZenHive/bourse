defmodule Bourse.Unified.GreeksConventions do
  @moduledoc """
  Reads authored per-venue option-Greek unit conventions.

  Each first-class option venue declares native source fields plus denomination,
  unit, bump size and time basis for delta/gamma/vega/theta/rho. Unsupported
  fields stay explicit (`supported: false`) rather than being fabricated.
  """

  alias Bourse.Error
  alias Bourse.Exchange

  @greek_names ~w(delta gamma vega theta rho)

  @doc "Returns the authored Greek convention table for an exchange."
  @spec for_exchange(Exchange.t()) :: {:ok, map()} | {:error, Error.t()}
  def for_exchange(%Exchange{config: %{"greeks_conventions" => conventions}})
      when is_map(conventions) and map_size(conventions) > 0 do
    with :ok <- validate_table(conventions) do
      {:ok, conventions}
    end
  end

  def for_exchange(%Exchange{id: id}) do
    {:error, Error.not_supported(message: "exchange #{id} has no authored markets.greeks_conventions")}
  end

  @doc "Returns convention metadata for one Greek name."
  @spec convention(map(), String.t()) :: map() | nil
  def convention(table, name) when is_map(table) and is_binary(name), do: Map.get(table, name)

  @doc "Greek names the surface tracks."
  @spec names() :: [String.t()]
  def names, do: @greek_names

  defp validate_table(table) do
    missing = Enum.reject(@greek_names, &Map.has_key?(table, &1))

    case missing do
      [] ->
        validate_entries(table)

      names ->
        {:error, Error.invalid_parameters(message: "greeks_conventions missing entries: #{Enum.join(names, ", ")}")}
    end
  end

  defp validate_entries(table) do
    Enum.reduce_while(@greek_names, :ok, fn name, :ok ->
      case validate_entry(name, Map.fetch!(table, name)) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_entry(name, %{"supported" => false} = entry) when is_map(entry) do
    case Map.get(entry, "native_field") do
      field when field in [nil, ""] ->
        :ok

      _field ->
        {:error, Error.invalid_parameters(message: "unsupported greek #{name} must not name a native_field")}
    end
  end

  defp validate_entry(_name, %{
         "supported" => true,
         "native_field" => field,
         "denomination" => denomination,
         "unit" => unit,
         "bump_size" => bump,
         "time_basis" => time_basis
       })
       when is_binary(field) and field != "" and is_binary(denomination) and denomination != "" and is_binary(unit) and
              unit != "" and is_number(bump) and (is_binary(time_basis) or is_nil(time_basis)) do
    :ok
  end

  defp validate_entry(name, entry) do
    {:error, Error.invalid_parameters(message: "invalid greeks_conventions.#{name}: #{inspect(entry)}")}
  end
end
