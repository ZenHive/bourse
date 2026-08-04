defmodule Bourse.Test.RequestCollectorTest do
  use ExUnit.Case, async: true

  alias Bourse.Test.RequestCollector

  defp stub_name, do: {:request_collector, System.unique_integer([:positive])}

  test "captures a request made from a spawned task" do
    {:ok, requests} = RequestCollector.start_link()
    stub = stub_name()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert {:ok, %{body: %{"ok" => true}}} =
             fn -> Req.get(plug: {Req.Test, stub}, url: "https://example.test/ping?symbol=BTCUSDT") end
             |> Task.async()
             |> Task.await()

    conn = RequestCollector.one!(requests)
    assert conn.request_path == "/ping"
    assert RequestCollector.query(requests) == %{"symbol" => "BTCUSDT"}
  end

  test "capture_with_body/2 hands the body back to a body-dependent plug" do
    {:ok, requests} = RequestCollector.start_link()
    stub = stub_name()

    Req.Test.stub(stub, fn conn ->
      {conn, body} = RequestCollector.capture_with_body(requests, conn)
      Req.Test.json(conn, %{"echoed" => body})
    end)

    assert {:ok, %{body: %{"echoed" => ~s({"side":"buy"})}}} =
             Req.post(plug: {Req.Test, stub}, url: "https://example.test/order", body: ~s({"side":"buy"}))

    assert RequestCollector.json_body!(requests) == %{"side" => "buy"}
  end

  test "one!/1 flunks by name when the plug was never reached" do
    {:ok, requests} = RequestCollector.start_link()

    assert_raise ExUnit.AssertionError, ~r/exactly 1 request, got none/, fn ->
      RequestCollector.one!(requests)
    end
  end

  test "one!/1 flunks naming the observed paths when the plug ran more than once" do
    {:ok, requests} = RequestCollector.start_link()
    stub = stub_name()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, %{})
    end)

    for path <- ["/first", "/second"] do
      assert {:ok, _} = Req.get(plug: {Req.Test, stub}, url: "https://example.test#{path}")
    end

    assert RequestCollector.paths(requests) == ["/first", "/second"]

    assert_raise ExUnit.AssertionError, ~r|got 2: /first, /second|, fn ->
      RequestCollector.one!(requests)
    end
  end

  test "captured headers survive for post-hoc assertion" do
    {:ok, requests} = RequestCollector.start_link()
    stub = stub_name()

    Req.Test.stub(stub, fn conn ->
      conn = RequestCollector.capture(requests, conn)
      Req.Test.json(conn, %{})
    end)

    assert {:ok, _} =
             Req.get(
               plug: {Req.Test, stub},
               url: "https://example.test/balance",
               headers: [{"x-simulated-trading", "1"}]
             )

    conn = RequestCollector.one!(requests)
    assert Plug.Conn.get_req_header(conn, "x-simulated-trading") == ["1"]
  end
end
