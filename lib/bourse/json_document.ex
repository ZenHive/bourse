defmodule Bourse.JsonDocument do
  @moduledoc """
  Strict JSON document decoding shared by compile-time loaders.

  Rejects duplicate object keys at any nesting level before decoding with
  Jason, so hand-edited documents fail loudly instead of silently keeping
  the first key occurrence.
  """

  @doc """
  Decodes a JSON document after rejecting duplicate object keys.

  Raises `ArgumentError` naming the file, duplicated key, and object path on
  duplicates. Malformed JSON still raises `Jason.DecodeError` with a byte
  position rather than an opaque `:json` ErlangError.
  """
  @spec decode_file!(String.t()) :: map() | list()
  def decode_file!(path) when is_binary(path) do
    contents = File.read!(path)
    validate_no_duplicate_keys!(contents, path)
    Jason.decode!(contents)
  end

  defp validate_no_duplicate_keys!(contents, path) do
    callbacks = %{
      object_start: fn _ -> [] end,
      object_push: fn key, value, entries -> [{key, value} | entries] end,
      object_finish: fn entries, accumulator -> {{:object, Enum.reverse(entries)}, accumulator} end
    }

    {document, _accumulator, _rest} = :json.decode(contents, nil, callbacks)
    validate_json_value!(document, path, [])
  rescue
    # Malformed JSON is not this pass's concern: `:json` reports it as an opaque
    # `{:invalid_byte, _}` ErlangError, so defer to `Jason.decode!/1` — the caller
    # runs it next and raises the documented `Jason.DecodeError` with a position.
    ErlangError -> :ok
  end

  # `segments` is the reversed trail of path pieces, rendered only when raising —
  # nesting a document deeply must not build a string per visited node.
  defp validate_json_value!({:object, entries}, path, segments) do
    Enum.reduce(entries, MapSet.new(), fn {key, value}, keys ->
      if MapSet.member?(keys, key), do: raise_duplicate_key!(path, key, segments)

      validate_json_value!(value, path, [[".", key] | segments])
      MapSet.put(keys, key)
    end)
  end

  defp validate_json_value!(values, path, segments) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.each(fn {value, index} ->
      validate_json_value!(value, path, [["[", Integer.to_string(index), "]"] | segments])
    end)
  end

  defp validate_json_value!(_value, _path, _segments), do: :ok

  defp raise_duplicate_key!(path, key, segments) do
    object_path = IO.iodata_to_binary(["$" | Enum.reverse(segments)])

    raise ArgumentError,
          "JSON document #{path} contains duplicate key #{inspect(key)} at object path #{object_path}"
  end
end
