defmodule Bourse.WS.ListenKeyTest do
  @moduledoc """
  Offline contract for the REST round-trip behind the `:listen_key` pattern.

  Endpoint resolution is covered in `Bourse.WS.Auth.ListenKeyTest`; what these
  tests pin is that every way of failing to obtain a key is an error rather
  than a fallback. That matters more here than usual: a connection opened
  without a valid key is *accepted* by the venue and then delivers nothing, so
  a lenient failure mode here is invisible downstream. The venue-side
  confirmation is in `Bourse.WS.AuthLiveSmokeTest`.
  """

  use ExUnit.Case, async: true

  alias Bourse.Credentials
  alias Bourse.Exchange
  alias Bourse.WS.ListenKey

  @credentials Credentials.new!(api_key: "k", secret: "s")

  @config %{
    pre_auth: %{
      default_market_type: :linear,
      endpoints: %{linear: :fapiPrivate_post_listenkey},
      keepalive_endpoints: %{linear: :fapiPrivate_put_listenkey},
      keepalive_ms: 900_000
    }
  }

  describe "open/3" do
    test "returns the issued key and what is needed to keep it alive" do
      stub = stub_responding(%{"listenKey" => "issued-key"})
      exchange = Exchange.new!("binanceusdm", credentials: @credentials)

      assert {:ok, session} = ListenKey.open(exchange, @config, plug: {Req.Test, stub})

      assert session == %{
               listen_key: "issued-key",
               market_type: :linear,
               keepalive_endpoint: :fapiPrivate_put_listenkey,
               keepalive_ms: 900_000
             }
    end

    test "refuses a response that carries no key rather than connecting without one" do
      # The venue answering 200 is not the same as the venue issuing a key, and
      # a URL built from a missing key still connects. A body the error layer
      # does not recognise as a failure is exactly the case that reaches here.
      stub = stub_responding(%{"listenKey" => ""})
      exchange = Exchange.new!("binanceusdm", credentials: @credentials)

      assert {:error, {:no_listen_key_in_response, %{"listenKey" => ""}}} =
               ListenKey.open(exchange, @config, plug: {Req.Test, stub})
    end

    test "passes a venue failure through untouched" do
      stub = stub_failing(401, %{"code" => -2_014, "msg" => "API-key format invalid."})
      exchange = Exchange.new!("binanceusdm", credentials: @credentials)

      assert {:error, %Bourse.Error{code: -2_014}} =
               ListenKey.open(exchange, @config, plug: {Req.Test, stub})
    end
  end

  describe "keepalive/3" do
    test "refreshes through the authored endpoint" do
      stub = stub_responding(%{})
      exchange = Exchange.new!("binanceusdm", credentials: @credentials)
      session = %{keepalive_endpoint: :fapiPrivate_put_listenkey}

      assert :ok = ListenKey.keepalive(exchange, session, plug: {Req.Test, stub})
    end
  end

  describe "open/3 refusals" do
    test "reports missing credentials before attempting the round-trip" do
      assert {:error, :no_credentials} = ListenKey.open(Exchange.new!("binanceusdm"), @config)
    end

    test "names an endpoint the generated module does not carry" do
      exchange = Exchange.new!("binanceusdm", credentials: @credentials)
      config = put_in(@config, [:pre_auth, :endpoints], %{linear: :not_a_real_endpoint})

      assert {:error, {:unknown_listen_key_endpoint, :not_a_real_endpoint}} =
               ListenKey.open(exchange, config)
    end

    test "passes a resolution failure through rather than calling anything" do
      exchange = Exchange.new!("binanceusdm", credentials: @credentials)

      assert {:error, {:no_endpoint_for_market_type, _}} =
               ListenKey.open(exchange, @config, market_type: :spot)
    end
  end

  describe "keepalive/2" do
    test "reports a venue that authors no refresh endpoint as a configuration gap" do
      exchange = Exchange.new!("binanceusdm", credentials: @credentials)

      assert {:error, :no_keepalive_endpoint} =
               ListenKey.keepalive(exchange, %{keepalive_endpoint: nil})
    end

    test "names an unknown refresh endpoint the same way as an unknown issuer" do
      exchange = Exchange.new!("binanceusdm", credentials: @credentials)

      assert {:error, {:unknown_listen_key_endpoint, :nope}} =
               ListenKey.keepalive(exchange, %{keepalive_endpoint: :nope})
    end
  end

  defp stub_responding(body) do
    stub = {__MODULE__, :listen_key, System.unique_integer([:positive])}
    Req.Test.stub(stub, fn conn -> Req.Test.json(conn, body) end)
    stub
  end

  defp stub_failing(status, body) do
    stub = {__MODULE__, :listen_key_error, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn conn ->
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)

    stub
  end
end
