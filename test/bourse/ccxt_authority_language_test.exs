defmodule Bourse.CcxtAuthorityLanguageTest do
  @moduledoc """
  Prevents compatibility references from presenting CCXT as venue authority.
  """

  use ExUnit.Case, async: true

  @ccxt_reference ~r/\bccxt(?:-js|_client_bak|_[a-z0-9_]+)?\b/i

  # Mix-task references are allowed token-scoped: the named tokens are stripped
  # from the line, and the residual line must carry no CCXT reference at all.
  # A line-wide substring allowlist would let authority language ride along on
  # any line that merely mentions a `mix bourse.*` task.
  @mix_task_tokens ~r{(?:Mix\.Tasks\.Bourse[A-Za-z.]*|mix bourse(?:\.[A-Za-z0-9_*.]+)?|bourse\.[a-z][A-Za-z0-9_.]*|test/mix/tasks/bourse_[a-z0-9_.]+)}i

  @allowlist [
    {~r{^lib/mix/tasks/}, {:tokens, @mix_task_tokens}},
    {~r{^lib/mix/tasks/bourse/reference_corpus\.ex$}, ~r{CCXT reference corpus}i},
    {~r{^lib/bourse\.ex$}, ~r{CCXT corpus is authoring and compatibility}i},
    {~r{^lib/bourse/error\.ex$}, ~r{CCXT compatibility exception class}i},
    {~r{^lib/bourse/exchange\.ex$}, ~r{reference specs encode CCXT}i},
    {~r{^lib/bourse/multi\.ex$}, ~r{ccxt_client_bak}i},
    {~r{^lib/bourse/spec\.ex$}, ~r{CCXT-derived documents}i},
    {~r{^lib/bourse/spec/schema\.ex$}, ~r{Mix\.Tasks\.Bourse}i},
    {~r{^lib/bourse/unified\.ex$}, ~r{CCXT compatibility mapping}i},
    {~r{^lib/bourse/unified/read_parse\.ex$}, ~r{CCXT-projected reference bulk}i},
    {~r{^lib/bourse/unified/request_shape/hyperliquid\.ex$}, ~r{diverges from CCXT}i},
    {~r{^lib/bourse/ws/subscription\.ex$}, ~r{ccxt_client_bak}i}
  ]

  test "lib comments and docs use CCXT only for explicit compatibility boundaries" do
    violations =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(&ccxt_references/1)
      |> Enum.reject(&allowed?/1)

    assert violations == [],
           """
           CCXT may appear in lib comments and docs only through the explicit
           compatibility/reference allowlist. Rewrite provider-authority language
           or add a narrowly-scoped demarcating reference:

           #{Enum.map_join(violations, "\n", &format_reference/1)}
           """
  end

  test "no source references the retired CCXT module namespace" do
    guard = "test/bourse/ccxt_authority_language_test.exs"

    violations =
      (Path.wildcard("lib/**/*.ex") ++ Path.wildcard("test/**/*.{ex,exs}"))
      |> Enum.reject(&(&1 == guard))
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _number} -> Regex.match?(~r/\bCCXT\.[A-Z]/, line) end)
        |> Enum.map(fn {line, number} -> "#{path}:#{number}: #{String.trim(line)}" end)
      end)

    assert violations == [],
           """
           The CCXT.* module namespace is retired (repo namespace is Bourse.*).
           References found:

           #{Enum.join(violations, "\n")}
           """
  end

  defp ccxt_references(path) do
    source = File.read!(path)
    {:ok, ast, comments} = Code.string_to_quoted_with_comments(source, columns: true)

    comment_references(path, comments) ++ doc_references(path, ast)
  end

  defp comment_references(path, comments) do
    Enum.flat_map(comments, fn comment ->
      references_in_text(path, comment.line, comment.text)
    end)
  end

  defp doc_references(path, ast) do
    {_ast, references} =
      Macro.prewalk(ast, [], fn
        {:@, meta, [{kind, _kind_meta, [text]}]} = node, acc
        when kind in [:moduledoc, :doc] and is_binary(text) ->
          {node, references_in_text(path, meta[:line], text) ++ acc}

        node, acc ->
          {node, acc}
      end)

    references
  end

  defp references_in_text(path, start_line, text) do
    text
    |> String.split("\n")
    |> Enum.with_index(start_line)
    |> Enum.flat_map(fn {line, line_number} ->
      if Regex.match?(@ccxt_reference, line) do
        [{path, line_number, String.trim(line)}]
      else
        []
      end
    end)
  end

  defp allowed?({path, _line, text}) do
    Enum.any?(@allowlist, fn
      {path_pattern, {:tokens, token_pattern}} ->
        Regex.match?(path_pattern, path) and
          not Regex.match?(@ccxt_reference, Regex.replace(token_pattern, text, ""))

      {path_pattern, text_pattern} ->
        Regex.match?(path_pattern, path) and Regex.match?(text_pattern, text)
    end)
  end

  defp format_reference({path, line, text}), do: "#{path}:#{line}: #{text}"
end
