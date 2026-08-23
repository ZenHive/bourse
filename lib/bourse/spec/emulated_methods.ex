defmodule Bourse.Spec.EmulatedMethods do
  @moduledoc """
  Reads explicit emulated-method declarations from the owned runtime specs.
  """

  alias Bourse.Spec

  @doc "Returns every supported runtime exchange ID."
  @spec exchanges() :: [String.t()]
  def exchanges, do: Spec.exchanges()

  @doc "Returns all emulated method entries for an exchange."
  @spec methods_for(String.t()) :: [map()]
  def methods_for(exchange_id) do
    if Spec.supported?(exchange_id) do
      exchange_id
      |> Spec.load!()
      |> Map.fetch!("emulated_methods")
    else
      []
    end
  end

  @doc "Returns emulated method names for an exchange."
  @spec method_names_for(String.t()) :: [String.t()]
  def method_names_for(exchange_id) do
    exchange_id
    |> methods_for()
    |> Enum.map(&Map.get(&1, "name"))
  end

  @doc "Returns an emulated method entry by name for an exchange."
  @spec method_for(String.t(), String.t()) :: map() | nil
  def method_for(exchange_id, method_name) do
    exchange_id
    |> methods_for()
    |> Enum.find(fn method -> Map.get(method, "name") == method_name end)
  end

  @doc ~s{Returns emulated method entries filtered by scope ("rest" or "ws").}
  @spec methods_for_scope(String.t(), String.t()) :: [map()]
  def methods_for_scope(exchange_id, scope) when is_binary(scope) do
    exchange_id
    |> methods_for()
    |> Enum.filter(fn method -> Map.get(method, "scope") == scope end)
  end

  @doc "Returns the runtime emulation declarations keyed by supported venue."
  @spec load() :: map()
  def load do
    emulated_methods = Map.new(exchanges(), &{&1, methods_for(&1)})
    %{"emulated_methods" => emulated_methods}
  end

  @doc "Rebuilds the runtime emulation declarations from the owned specs."
  @spec reload!() :: map()
  def reload!, do: load()
end
