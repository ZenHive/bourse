defmodule Bourse.Unified.Descriptor do
  @moduledoc """
  Authored unified-method descriptors for Descripex `api()` hints.

  Merges `endpoints.descriptors` from runtime venue specs at compile time.
  `Bourse` uses `build_api_opts/2` to enrich hints (slot 5) while keeping
  hand-authored Elixir arg shape and curated `@doc` descriptions.
  """

  alias Bourse.Error
  alias Bourse.Spec

  @runtime_manifest Spec.manifest_path()
  @external_resource @runtime_manifest
  @runtime_venues Spec.exchanges()

  # Recompile this module whenever a first-class spec changes. `@merged_descriptors`
  # is frozen from these files at compile time; without the resource link an
  # authored descriptor (e.g. a newly added unified method's return_type) would
  # silently fail to route until an unrelated clean rebuild. The generated
  # exchange modules track their spec the same way (`Spec.spec_path/1`).
  for id <- @runtime_venues do
    @external_resource Spec.spec_path(id)
  end

  @base_errors [:not_supported, :authentication_error, :invalid_nonce, :rate_limit_exceeded, :network_error]

  @merged_descriptors Enum.reduce(@runtime_venues, %{}, fn id, acc ->
                        descriptors =
                          case Spec.load!(id) do
                            %{"endpoints" => %{"descriptors" => d}} when is_map(d) -> d
                            _ -> %{}
                          end

                        Map.merge(descriptors, acc, fn _name, descriptor, existing ->
                          cond do
                            is_map(descriptor) and is_map(existing) -> Map.merge(descriptor, existing)
                            is_map(existing) -> existing
                            true -> descriptor
                          end
                        end)
                      end)

  @doc "Returns the merged JS-name → descriptor map from runtime venue specs."
  @spec descriptors() :: %{String.t() => map()}
  def descriptors, do: @merged_descriptors

  @doc """
  Builds Descripex `api()` opts from authored descriptor data and Elixir arg shape.

  `required_params` is the hand-authored positional tail (after `exchange`).
  Falls back to structural hints when no descriptor exists for `js_name`.
  """
  @spec build_api_opts(String.t(), [atom()]) :: keyword()
  def build_api_opts(js_name, required_params) do
    case Map.get(@merged_descriptors, js_name) do
      nil -> fallback_api_opts(required_params)
      descriptor -> compose_api_opts(descriptor, required_params)
    end
  end

  @doc false
  @spec descriptors_from_spec(String.t()) :: map()
  def descriptors_from_spec(exchange_id) do
    case Spec.load!(exchange_id) do
      %{"endpoints" => %{"descriptors" => descriptors}} when is_map(descriptors) ->
        descriptors

      _ ->
        %{}
    end
  end

  defp compose_api_opts(descriptor, required_params) do
    signature_params = get_in(descriptor, ["signature", "params"]) || []
    params_doc = descriptor["params_doc"] || %{}

    params =
      [exchange: [kind: :value, description: "Exchange configuration struct"]] ++
        Enum.map(required_params, &build_param_entry(&1, signature_params, params_doc))

    opts_entries = build_opts_entries(required_params, signature_params, params_doc)

    maybe_put_opts([params: params, returns: build_returns(descriptor), errors: build_errors(descriptor)], opts_entries)
  end

  defp fallback_api_opts(required_params) do
    [
      params:
        [exchange: [kind: :value, description: "Exchange configuration struct"]] ++
          Enum.map(required_params, fn p ->
            {p, [kind: :value, description: humanize(p)]}
          end),
      returns: default_returns(),
      errors: @base_errors
    ]
  end

  defp build_param_entry(name, signature_params, params_doc) do
    ts_name = Atom.to_string(name)
    sig = find_signature_param(signature_params, ts_name)
    desc = param_doc(params_doc, ts_name) || humanize(name)
    desc = maybe_append_ts_type(desc, sig)

    details = maybe_put_default([kind: :value, description: desc], sig)

    {name, details}
  end

  defp build_opts_entries(required_params, signature_params, params_doc) do
    required_set = MapSet.new(required_params)

    sig_opts =
      signature_params
      |> Enum.filter(&truthy_optional?/1)
      |> Enum.reject(fn p ->
        p["name"] == "params" or
          MapSet.member?(required_set, elixir_param_atom(p["name"]))
      end)
      |> Enum.map(&build_opt_entry(&1, params_doc))

    dotted_opts = build_dotted_opt_entries(params_doc)

    dotted_opts
    |> Map.new()
    |> Map.merge(Map.new(sig_opts))
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  defp build_opt_entry(%{"name" => ts_name} = param, params_doc) do
    key = elixir_param_atom(ts_name)
    desc = param_doc(params_doc, ts_name) || humanize(key)
    desc = maybe_append_ts_type(desc, param)

    details = maybe_put_default([kind: :value, description: desc], param)

    {key, details}
  end

  defp build_dotted_opt_entries(params_doc) do
    params_doc
    |> Enum.filter(fn {key, _} -> String.starts_with?(key, "params.") end)
    |> Enum.map(fn {"params." <> suffix, desc} ->
      key = elixir_param_atom(suffix)
      {key, [kind: :value, description: desc]}
    end)
  end

  defp build_returns(descriptor) do
    case descriptor["returns"] do
      %{"description" => desc} when is_binary(desc) ->
        ts_return = get_in(descriptor, ["signature", "return_type"])
        base = "{:ok, #{desc}} on success, {:error, Bourse.Error.t()} on failure"

        if is_binary(ts_return) do
          %{type: :result_tuple, description: base <> " (TS: #{ts_return})"}
        else
          %{type: :result_tuple, description: base}
        end

      _ ->
        default_returns()
    end
  end

  defp build_errors(descriptor) do
    case descriptor["errors"] do
      errors when is_list(errors) ->
        upstream =
          errors
          |> Enum.map(&map_error_class/1)
          |> Enum.reject(&is_nil/1)

        Enum.uniq(@base_errors ++ upstream)

      _ ->
        @base_errors
    end
  end

  defp map_error_class(class) when is_binary(class), do: Error.from_spec_class(class)

  defp map_error_class(%{"class" => class}) when is_binary(class), do: Error.from_spec_class(class)

  defp map_error_class(_), do: nil

  defp default_returns do
    %{
      type: :result_tuple,
      description: "{:ok, map()} on success, {:error, Bourse.Error.t()} on failure"
    }
  end

  defp find_signature_param(signature_params, elixir_name) do
    Enum.find(signature_params, fn p ->
      # reach:disable-next-line unsafe_atom_creation — elixir_name is Atom.to_string of an interned atom
      elixir_param_atom(p["name"]) == String.to_atom(elixir_name)
    end)
  end

  defp param_doc(params_doc, ts_name) when is_map(params_doc) do
    Map.get(params_doc, ts_name) || Map.get(params_doc, "params." <> ts_name)
  end

  defp param_doc(_, _), do: nil

  defp maybe_append_ts_type(desc, %{"type" => type}) when is_binary(type) and type != "" do
    if String.contains?(desc, type), do: desc, else: "#{desc} (TS: #{type})"
  end

  defp maybe_append_ts_type(desc, _), do: desc

  defp maybe_put_default(details, %{"default" => default}) do
    case normalize_ts_default(default) do
      nil -> details
      value -> Keyword.put(details, :default, value)
    end
  end

  defp maybe_put_default(details, _), do: details

  defp normalize_ts_default(nil), do: nil
  defp normalize_ts_default("undefined"), do: nil
  defp normalize_ts_default("null"), do: nil
  defp normalize_ts_default("{}"), do: nil

  defp normalize_ts_default(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value

  defp normalize_ts_default(_), do: nil

  defp truthy_optional?(%{"optional" => true}), do: true
  defp truthy_optional?(_), do: false

  defp elixir_param_atom(ts_name) when is_binary(ts_name) do
    # reach:disable-next-line unsafe_atom_creation — TS option names aren't interned; to_existing_atom would raise
    ts_name |> Macro.underscore() |> String.to_atom()
  end

  defp humanize(atom) do
    atom |> Atom.to_string() |> String.replace("_", " ")
  end

  defp maybe_put_opts(opts, []), do: opts

  defp maybe_put_opts(opts, entries), do: Keyword.put(opts, :opts, entries)
end
