defmodule Bourse.Safe do
  @moduledoc """
  Safe accessors and coercions used by response normalization.
  """

  @type key :: atom() | String.t() | non_neg_integer()
  @type data :: map() | list()

  @doc "Safely reads a value from a map or list, returning `default` when absent."
  @spec value(term(), key() | nil, term()) :: term()
  def value(_data, nil, default), do: default

  def value(data, index, default) when is_list(data) and is_integer(index) do
    Enum.at(data, index, default)
  end

  # A dotted binary key is a nested path: `"stats.high"` reads `data["stats"]["high"]`.
  # This expresses successive nested-value drilling as a single authored key.
  # Provider response keys
  # never contain a literal dot, so this never shadows a flat key.
  def value(data, key, default) when is_map(data) and is_binary(key) do
    case :binary.match(key, ".") do
      :nomatch -> flat_value(data, key, default)
      _ -> nested_value(data, String.split(key, "."), default)
    end
  end

  def value(data, key, default) when is_map(data), do: flat_value(data, key, default)

  def value(_data, _key, default), do: default

  defp nested_value(data, [segment], default), do: flat_value(data, segment, default)

  defp nested_value(data, [segment | rest], default) when is_map(data) do
    case flat_value(data, segment, :__bourse_missing__) do
      sub when is_map(sub) -> nested_value(sub, rest, default)
      _ -> default
    end
  end

  defp nested_value(_data, _segments, default), do: default

  defp flat_value(data, key, default) do
    data
    |> lookup_variants(key)
    |> case do
      {:ok, nil} -> default
      {:ok, ""} -> default
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc "Safely reads the first present key from a map or list."
  @spec value_any(term(), [key()], term()) :: term()
  def value_any(data, keys, default) when is_list(keys) do
    Enum.reduce_while(keys, default, fn key, _acc ->
      case value(data, key, :__bourse_missing__) do
        :__bourse_missing__ -> {:cont, default}
        "" -> {:cont, default}
        found -> {:halt, found}
      end
    end)
  end

  @doc "Coerces a value to a string when present."
  @spec string(term()) :: String.t() | nil
  def string(nil), do: nil
  def string(value) when is_binary(value), do: value
  def string(value) when is_integer(value) or is_float(value) or is_boolean(value), do: to_string(value)
  def string(_value), do: nil

  @doc "Coerces a value to a lowercase string when present."
  @spec string_lower(term()) :: String.t() | nil
  def string_lower(value) do
    case string(value) do
      nil -> nil
      string -> String.downcase(string)
    end
  end

  @doc "Coerces a value to an integer when present."
  @spec integer(term()) :: integer() | nil
  def integer(nil), do: nil
  def integer(value) when is_integer(value), do: value
  def integer(value) when is_float(value), do: trunc(value)

  def integer(value) when is_binary(value) do
    value
    |> String.trim()
    |> parse_integer()
  end

  def integer(_value), do: nil

  @doc "Coerces a value to a number when present."
  @spec number(term()) :: number() | nil
  def number(nil), do: nil
  def number(value) when is_integer(value) or is_float(value), do: value

  def number(value) when is_binary(value) do
    value
    |> String.trim()
    |> parse_number()
  end

  def number(_value), do: nil

  @doc "Coerces a value to a boolean when present."
  @spec bool(term()) :: boolean() | nil
  def bool(nil), do: nil
  def bool(value) when is_boolean(value), do: value
  def bool(value) when value in [0, 0.0], do: false
  def bool(value) when is_integer(value) or is_float(value), do: true

  def bool(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "1" -> true
      "false" -> false
      "0" -> false
      _ -> nil
    end
  end

  def bool(_value), do: nil

  defp lookup_variants(data, key) do
    key
    |> key_variants()
    |> Enum.find_value(:error, fn variant ->
      case Map.fetch(data, variant) do
        {:ok, value} -> {:ok, value}
        :error -> nil
      end
    end)
  end

  defp key_variants(key) when is_atom(key), do: [key, Atom.to_string(key)]

  defp key_variants(key) when is_binary(key) do
    case existing_atom(key) do
      nil -> [key]
      atom -> [key, atom]
    end
  end

  defp key_variants(key), do: [key]

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp parse_integer(""), do: nil

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp parse_number(""), do: nil

  defp parse_number(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end
end
