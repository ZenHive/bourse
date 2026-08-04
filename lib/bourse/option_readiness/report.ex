defmodule Bourse.OptionReadiness.Report do
  @moduledoc """
  Durable option-readiness matrix report.

  Every cell and venue status links back to captured evidence. Reports are
  ordinary data plus JSON serialization — nothing is persisted automatically.

  Orthogonal short-side capability (`capabilities.short_fill_ready` /
  `side_status.short` plus `short_evidence`) is serialized alongside the legacy
  scalar `status` without replacing it.
  """

  alias Bourse.OptionReadiness.VenueRow

  @schema_version 1

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          observed_at: integer(),
          venues: [VenueRow.t()],
          path: String.t() | nil,
          meta: map()
        }

  @enforce_keys [:observed_at, :venues]
  defstruct [
    :observed_at,
    :venues,
    :path,
    schema_version: @schema_version,
    meta: %{}
  ]

  @doc "Builds a report from venue rows."
  @spec new([VenueRow.t()], integer(), keyword()) :: t()
  def new(venues, observed_at, opts \\ []) when is_list(venues) and is_integer(observed_at) do
    %__MODULE__{
      observed_at: observed_at,
      venues: venues,
      meta: %{
        "generated_by" => "Bourse.OptionReadiness",
        "task" => 402,
        "opts" => safe_opts(opts)
      }
    }
  end

  @doc "Default durable report filename for one run."
  @spec default_filename(t()) :: String.t()
  def default_filename(%__MODULE__{observed_at: observed_at}) do
    "option_readiness_#{observed_at}.json"
  end

  @doc "JSON-safe map representation with linked cell evidence."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = report) do
    %{
      "schema_version" => report.schema_version,
      "observed_at" => report.observed_at,
      "path" => report.path,
      "meta" => report.meta,
      "venues" => Enum.map(report.venues, &VenueRow.to_map/1)
    }
  end

  @doc "Writes pretty-printed JSON and returns the absolute path."
  @spec write(t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def write(%__MODULE__{} = report, path) when is_binary(path) do
    absolute = Path.expand(path)
    payload = report |> Map.put(:path, absolute) |> to_map() |> Jason.encode!(pretty: true)

    with :ok <- File.mkdir_p(Path.dirname(absolute)),
         :ok <- File.write(absolute, payload <> "\n") do
      {:ok, absolute}
    end
  end

  @doc "Reads a previously written report."
  @spec read(Path.t()) :: {:ok, t()} | {:error, term()}
  def read(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, document} <- Jason.decode(contents) do
      venues =
        document
        |> Map.fetch!("venues")
        |> Enum.map(fn venue_map ->
          {:ok, row} = VenueRow.from_injected(venue_map["venue"], venue_map, observed_at: venue_map["observed_at"])
          row
        end)

      {:ok,
       %__MODULE__{
         schema_version: Map.get(document, "schema_version", @schema_version),
         observed_at: Map.fetch!(document, "observed_at"),
         venues: venues,
         path: Path.expand(path),
         meta: Map.get(document, "meta", %{})
       }}
    end
  end

  defp safe_opts(opts) do
    opts
    |> Keyword.drop([:exchanges, :evidence, :judgments])
    |> Map.new(fn {k, v} -> {Atom.to_string(k), inspect(v)} end)
  end
end
