defmodule Bourse.Test.RequestCollector do
  @moduledoc """
  Captures requests observed by a `Req.Test` plug so their shape can be asserted
  in the test process, after the call under test returns.

  An `ExUnit` assertion raised *inside* a `Req.Test` plug callback is inert as a
  diagnostic: `Bourse.HTTP` wraps the transport in a rescue, so the
  `ExUnit.AssertionError` is converted into
  `{:error, %Bourse.Error{type: :network_error}}`. The outer assertion still fails
  — there is no false green — but the message naming the wrong path, param or
  header is destroyed and the failure reads as a network error.

  Capturing instead of asserting moves the assertion back into the test process,
  where the diagnostic survives:

      {:ok, requests} = RequestCollector.start_link()

      Req.Test.stub(stub, fn conn ->
        conn = RequestCollector.capture(requests, conn)
        Req.Test.json(conn, %{"ret_code" => 0})
      end)

      assert {:ok, _} = HTTP.request(exchange, :get, "/v5/market/tickers", opts)

      conn = RequestCollector.one!(requests)
      assert conn.request_path == "/v5/market/tickers"

  The collector is a process, so a plug invoked from a spawned `Task` (the
  binance market fan-out) uses the same mechanism as one invoked directly by the
  test process — there is no separate cross-process path to get wrong.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @type request :: %{conn: Plug.Conn.t(), body: binary()}
  @type t :: pid()

  @doc "Starts a collector linked to the calling test process."
  @spec start_link() :: {:ok, t()}
  def start_link do
    Agent.start_link(fn -> [] end)
  end

  @doc """
  Captures the request and returns the connection for the plug to respond with.

  The body is read here, so a plug that also needs the body to build its
  response must use `capture_with_body/2` instead — a second `read_body/1` on
  the same connection yields `""`.
  """
  @spec capture(t(), Plug.Conn.t()) :: Plug.Conn.t()
  def capture(collector, conn) when is_pid(collector) do
    {conn, _body} = capture_with_body(collector, conn)
    conn
  end

  @doc "Captures the request and returns `{conn, body}` for body-dependent plugs."
  @spec capture_with_body(t(), Plug.Conn.t()) :: {Plug.Conn.t(), binary()}
  def capture_with_body(collector, conn) when is_pid(collector) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    Agent.update(collector, &[%{conn: conn, body: body} | &1])
    {conn, body}
  end

  @doc "Returns every captured request, in arrival order."
  @spec requests(t()) :: [request()]
  def requests(collector) when is_pid(collector) do
    Agent.get(collector, &Enum.reverse/1)
  end

  @doc """
  Returns the single observed connection, flunking with a named diagnostic when
  the plug was not reached exactly once.
  """
  @spec one!(t()) :: Plug.Conn.t()
  def one!(collector) when is_pid(collector), do: one_request!(collector).conn

  @doc "Like `one!/1` but returns the full `%{conn:, body:}` request."
  @spec one_request!(t()) :: request()
  def one_request!(collector) when is_pid(collector) do
    case requests(collector) do
      [request] ->
        request

      [] ->
        flunk("expected the Req.Test plug to observe exactly 1 request, got none")

      many ->
        paths = Enum.map_join(many, ", ", & &1.conn.request_path)
        flunk("expected the Req.Test plug to observe exactly 1 request, got #{length(many)}: #{paths}")
    end
  end

  @doc "Decoded query string of the single observed request."
  @spec query(t()) :: %{String.t() => String.t()}
  def query(collector) when is_pid(collector), do: query(one!(collector))

  @spec query(Plug.Conn.t()) :: %{String.t() => String.t()}
  def query(%Plug.Conn{} = conn), do: URI.decode_query(conn.query_string || "")

  @doc "JSON-decoded body of the single observed request."
  @spec json_body!(t()) :: term()
  def json_body!(collector) when is_pid(collector) do
    collector |> one_request!() |> Map.fetch!(:body) |> Jason.decode!()
  end

  @doc "Request paths of every observed request, in arrival order."
  @spec paths(t()) :: [String.t()]
  def paths(collector) when is_pid(collector) do
    collector |> requests() |> Enum.map(& &1.conn.request_path)
  end
end
