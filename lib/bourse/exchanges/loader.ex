defmodule Bourse.Exchanges.Loader do
  @moduledoc false

  @doc false
  @spec create(module(), Macro.t(), keyword()) :: {:module, module(), binary(), term()}
  def create(module_name, body, location) do
    unload(module_name)
    Module.create(module_name, body, location)
  end

  defp unload(module_name) do
    if Code.ensure_loaded?(module_name) do
      :code.purge(module_name)
      :code.delete(module_name)
    end
  end
end
