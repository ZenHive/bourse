defmodule Bourse.OptionReadiness.Cell do
  @moduledoc """
  One timestamped evidence cell in the option readiness matrix.

  Cells are mechanical capture records. Status labels for the whole venue row
  are derived separately; a cell itself never claims `fill_ready`.
  """

  @type outcome ::
          :ok
          | :error
          | :empty
          | :untested
          | :skipped
          | :blocked
          | :unsupported

  @type t :: %__MODULE__{
          name: atom(),
          outcome: outcome(),
          observed_at: integer() | nil,
          environment: String.t() | nil,
          summary: String.t() | nil,
          evidence: map(),
          error: map() | nil
        }

  @enforce_keys [:name, :outcome]
  defstruct [
    :name,
    :outcome,
    :observed_at,
    :environment,
    :summary,
    evidence: %{},
    error: nil
  ]

  @doc "Builds a cell from keyword or map attributes."
  @spec new(atom(), keyword() | map()) :: t()
  def new(name, attrs \\ []) when is_atom(name) do
    attrs = Map.new(attrs)

    %__MODULE__{
      name: name,
      outcome: Map.fetch!(attrs, :outcome),
      observed_at: Map.get(attrs, :observed_at),
      environment: Map.get(attrs, :environment),
      summary: Map.get(attrs, :summary),
      evidence: Map.get(attrs, :evidence, %{}),
      error: Map.get(attrs, :error)
    }
  end

  @doc "True when the cell has not been exercised."
  @spec untested?(t()) :: boolean()
  def untested?(%__MODULE__{outcome: outcome}) when outcome in [:untested, :skipped], do: true
  def untested?(%__MODULE__{}), do: false

  @doc "True when the cell recorded a broken/error capture."
  @spec broken?(t()) :: boolean()
  def broken?(%__MODULE__{outcome: :error}), do: true
  def broken?(%__MODULE__{}), do: false

  @doc "JSON-safe map representation."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = cell) do
    %{
      "name" => Atom.to_string(cell.name),
      "outcome" => Atom.to_string(cell.outcome),
      "observed_at" => cell.observed_at,
      "environment" => cell.environment,
      "summary" => cell.summary,
      "evidence" => stringify_keys(cell.evidence),
      "error" => stringify_keys(cell.error)
    }
  end

  @doc "Rebuilds a cell from a JSON map or atom-key map."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    name = atomize_name(Map.get(map, "name") || Map.get(map, :name))
    outcome = atomize_outcome(Map.get(map, "outcome") || Map.get(map, :outcome))

    new(name,
      outcome: outcome,
      observed_at: Map.get(map, "observed_at") || Map.get(map, :observed_at),
      environment: Map.get(map, "environment") || Map.get(map, :environment),
      summary: Map.get(map, "summary") || Map.get(map, :summary),
      evidence: Map.get(map, "evidence") || Map.get(map, :evidence) || %{},
      error: Map.get(map, "error") || Map.get(map, :error)
    )
  end

  @known_names ~w(discovery greeks balances positions open_orders create_fetch_cancel preflight hedge)a
  @known_outcomes ~w(ok error empty untested skipped blocked unsupported)a

  defp atomize_name(name) when name in @known_names, do: name

  defp atomize_name(name) when is_binary(name) do
    atom = String.to_existing_atom(name)

    if atom in @known_names do
      atom
    else
      raise ArgumentError, "unknown cell name #{name}"
    end
  end

  defp atomize_outcome(outcome) when outcome in @known_outcomes, do: outcome

  defp atomize_outcome(outcome) when is_binary(outcome) do
    atom = String.to_existing_atom(outcome)

    if atom in @known_outcomes do
      atom
    else
      raise ArgumentError, "unknown cell outcome #{outcome}"
    end
  end

  @doc false
  @spec stringify_keys(term()) :: term()
  def stringify_keys(nil), do: nil

  def stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, encoded ->
      string_key = if is_atom(key), do: Atom.to_string(key), else: key

      if Map.has_key?(encoded, string_key) do
        raise ArgumentError, "duplicate JSON key after normalization: #{inspect(string_key)}"
      end

      Map.put(encoded, string_key, stringify_keys(value))
    end)
  end

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom), do: Atom.to_string(atom)
  def stringify_keys(other), do: other
end
