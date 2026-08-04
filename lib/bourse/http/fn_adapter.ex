defmodule Bourse.HTTP.FnAdapter do
  @moduledoc false

  # Req 0.7 deprecates function values in the `:adapter` option (removal
  # planned for 0.8); adapters must be modules exporting `run/1`. Injected
  # transport funs (the capture layers' recording adapters, test transports)
  # still arrive as funs, so `Bourse.HTTP` stores the fun in the request's
  # private map and points `:adapter` at this module instead.
  @doc false
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(request) do
    Req.Request.get_private(request, :bourse_adapter_fun).(request)
  end
end
