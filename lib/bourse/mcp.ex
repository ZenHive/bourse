defmodule Bourse.MCP do
  @moduledoc """
  MCP tool definitions for the Bourse API.

  Generates Model Context Protocol tool definitions from Descripex-annotated
  functions on the `Bourse` module. Includes the `exchange/2` constructor and
  all 241 unified methods plus the `exchange/2` constructor — each becomes a discoverable MCP tool with typed
  input schema derived from `api()` param declarations.

      tools = Bourse.MCP.tools()
      # => [%{name: "bourse__fetch_ticker", description: "...", inputSchema: %{...}}, ...]

  """

  @modules [Bourse]

  @doc "Generate MCP tool definitions for all api()-annotated functions on the Bourse module."
  @spec tools(keyword()) :: [map()]
  def tools(opts \\ []), do: Descripex.MCP.tools(@modules, opts)
end
