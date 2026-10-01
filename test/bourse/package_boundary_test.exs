defmodule Bourse.PackageBoundaryTest do
  # A packaged module that calls a repo-internal one compiles and passes here,
  # where `lib/` is whole, and fails at the consumer with an undefined module.
  # 0.9.1 nearly shipped `CredentialCheck` calling `Bourse.LighterProvision`.
  use ExUnit.Case, async: true

  test "no packaged module references a module the package leaves out" do
    packaged = packaged_ex_files()
    unpackaged = Path.wildcard("lib/**/*.ex") -- packaged

    internal_modules =
      for file <- unpackaged,
          [_, name] <- Regex.scan(~r/^defmodule\s+([\w.]+)/m, File.read!(file)),
          do: name

    offenders =
      for file <- packaged,
          source = code_lines(file),
          module <- internal_modules,
          Regex.match?(~r/(?<![\w.`])#{Regex.escape(module)}(?![\w`])/, source),
          do: {file, module}

    assert offenders == []
  end

  # A module named in a comment is not a call; doc mentions sit in backticks.
  defp code_lines(file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.join("\n")
  end

  defp packaged_ex_files do
    Mix.Project.config()[:package][:files]
    |> Enum.flat_map(fn path ->
      if File.dir?(path), do: Path.wildcard(Path.join(path, "**/*.ex")), else: [path]
    end)
    |> Enum.filter(&(String.starts_with?(&1, "lib/") and String.ends_with?(&1, ".ex")))
  end
end
