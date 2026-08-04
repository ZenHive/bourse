defmodule Mix.Tasks.Ccxt.RecordFixturesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Bourse.RecordedResponseFixtures
  alias Mix.Tasks.Ccxt.RecordFixtures

  test "--errors writes scrubbed fixtures and merges the error manifest" do
    paths = [
      RecordedResponseFixtures.fixture_path("bybit", :error_bad_symbol),
      RecordedResponseFixtures.fixture_path("bybit", :error_invalid_signature),
      Path.join(RecordedResponseFixtures.error_fixture_root(), "_manifest.json")
    ]

    originals = Map.new(paths, &{&1, File.read!(&1)})
    on_exit(fn -> Enum.each(originals, fn {path, body} -> File.write!(path, body) end) end)

    stub = unique_stub()

    Req.Test.stub(stub, fn conn ->
      case conn.request_path do
        "/v5/market/tickers" ->
          Req.Test.json(conn, %{
            "retCode" => 10_001,
            "retMsg" => "params error: symbol invalid",
            "result" => %{}
          })

        "/v5/account/wallet-balance" ->
          conn
          |> Plug.Conn.put_status(401)
          |> Req.Test.json(%{"retCode" => 10_003, "retMsg" => "API key is invalid"})
      end
    end)

    with_http_stub(stub, fn ->
      capture_io(fn -> RecordFixtures.run(["--errors", "bybit"]) end)
    end)

    manifest =
      RecordedResponseFixtures.error_fixture_root()
      |> Path.join("_manifest.json")
      |> RecordedResponseFixtures.load_fixture!()

    rows = Enum.filter(manifest["recordings"], &(&1["venue"] == "bybit"))
    today = Date.to_iso8601(Date.utc_today())

    assert Enum.map(rows, & &1["http_status"]) == [200, 401]
    assert Enum.all?(rows, &(&1["capture_date"] == today))
  end

  test "an explicit read target writes the normal response corpus manifest" do
    paths = [
      RecordedResponseFixtures.fixture_path("bybit", :fetch_ticker),
      Path.join(RecordedResponseFixtures.fixture_root(), "_manifest.json")
    ]

    preserve_files(paths)
    stub = unique_stub()

    Req.Test.stub(stub, fn conn ->
      Req.Test.json(conn, %{
        "retCode" => 0,
        "retMsg" => "OK",
        "result" => %{
          "category" => "linear",
          "list" => [%{"lastPrice" => "100000", "symbol" => "BTCUSDT"}]
        }
      })
    end)

    with_http_stub(stub, fn ->
      capture_io(fn -> RecordFixtures.run(["bybit", "fetch_ticker"]) end)
    end)

    fixture =
      "bybit"
      |> RecordedResponseFixtures.fixture_path(:fetch_ticker)
      |> RecordedResponseFixtures.load_fixture!()

    manifest =
      RecordedResponseFixtures.fixture_root()
      |> Path.join("_manifest.json")
      |> RecordedResponseFixtures.load_fixture!()

    assert fixture["body"]["result"]["list"] == [%{"lastPrice" => "100000", "symbol" => "BTCUSDT"}]
    assert "bybit/fetch_ticker.json" in manifest["fixtures"]
  end

  test "capture failures report missing credentials and unexpected success" do
    variables = ~w(DERIBIT_TESTNET_API_KEY DERIBIT_TESTNET_API_SECRET)

    with_env(variables, nil, fn ->
      error_output =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert_raise Mix.Error, ~r/fixture capture.*failed/, fn ->
              RecordFixtures.run(["--private", "deribit"])
            end
          end)
        end)

      assert error_output =~ ~s(export DERIBIT_TESTNET_API_KEY="replace-me")
      assert error_output =~ ~s(export DERIBIT_TESTNET_API_SECRET="replace-me")
    end)

    stub = unique_stub()
    Req.Test.stub(stub, &Req.Test.json(&1, %{"retCode" => 0, "retMsg" => "OK", "result" => %{}}))

    error_output =
      with_http_stub(stub, fn ->
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert_raise Mix.Error, ~r/fixture capture.*failed/, fn ->
              RecordFixtures.run(["bybit", "error_bad_symbol"])
            end
          end)
        end)
      end)

    assert error_output =~ "expected_error_got_success"
  end

  test "invalid argument shapes and empty selections fail loudly" do
    assert_raise Mix.Error, ~r/usage: mix ccxt.record_fixtures/, fn ->
      RecordFixtures.run(["one", "two", "three"])
    end

    assert_raise Mix.Error, ~r/No matching/, fn ->
      RecordFixtures.run(["--errors", "not-a-venue"])
    end

    assert_raise Mix.Error, ~r/unknown fixture capture method/, fn ->
      RecordFixtures.run(["bybit", "not_a_method"])
    end
  end

  defp unique_stub do
    {__MODULE__, System.unique_integer([:positive])}
  end

  defp preserve_files(paths) do
    originals = Map.new(paths, &{&1, File.read!(&1)})
    on_exit(fn -> Enum.each(originals, fn {path, body} -> File.write!(path, body) end) end)
  end

  defp with_env(variables, value, fun) do
    previous = Map.new(variables, &{&1, System.get_env(&1)})
    Enum.each(variables, &put_env(&1, value))

    try do
      fun.()
    after
      Enum.each(previous, fn {variable, prior} -> put_env(variable, prior) end)
    end
  end

  defp put_env(variable, nil), do: System.delete_env(variable)
  defp put_env(variable, value), do: System.put_env(variable, value)

  defp with_http_stub(stub, fun) do
    key = {Bourse.HTTP, :base_client}
    previous = :persistent_term.get(key, :missing)

    client =
      Req.new(
        compressed: true,
        decode_body: true,
        plug: {Req.Test, stub},
        retry: false
      )

    :persistent_term.put(key, client)

    try do
      fun.()
    after
      case previous do
        :missing -> :persistent_term.erase(key)
        client -> :persistent_term.put(key, client)
      end
    end
  end
end
