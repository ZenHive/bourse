defmodule Bourse.OracleProvenance.PathGuard do
  @moduledoc """
  Traversal guard for reviewed corpus paths.

  Capture and manifest paths are named by reviewed plans and registers, so a
  step id like `../../escape` would otherwise read or write outside the corpus
  the reviewer inspected. Every oracle-provenance module resolves relative
  paths through this one guard instead of carrying its own copy.
  """

  @doc """
  Expands `relative_path` under `root`, raising if it escapes the corpus root.

  `label` names the caller's artifact in the raised message.
  """
  @spec resolve_inside_root!(Path.t(), Path.t(), String.t()) :: Path.t()
  def resolve_inside_root!(root, relative_path, label) when is_binary(relative_path) do
    expanded_root = Path.expand(root)
    expanded_path = Path.expand(relative_path, expanded_root)
    relative = Path.relative_to(expanded_path, expanded_root)

    inside_root? =
      Path.type(relative_path) == :relative and Path.type(relative) == :relative and
        relative != ".." and not String.starts_with?(relative, "../")

    if !inside_root? do
      raise ArgumentError, "#{label} resolves outside its corpus root"
    end

    expanded_path
  end

  def resolve_inside_root!(_root, _relative_path, label) do
    raise ArgumentError, "#{label} path must be a string"
  end
end
