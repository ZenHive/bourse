defmodule Bourse.CredentialsTest do
  use ExUnit.Case, async: true

  alias Bourse.Credentials

  describe "Inspect redaction" do
    test "inspect masks api_key, secret, password, and uid" do
      creds =
        Credentials.new!(
          api_key: "AKIA-REAL-KEY-MATERIAL",
          secret: "0xdeadbeefwalletprivatekey",
          password: "okx-passphrase",
          uid: "user-4711"
        )

      output = inspect(creds)

      refute output =~ "AKIA-REAL-KEY-MATERIAL"
      refute output =~ "0xdeadbeefwalletprivatekey"
      refute output =~ "okx-passphrase"
      refute output =~ "user-4711"
      assert output =~ "#Bourse.Credentials<"
      assert output =~ ~s(api_key: "***")
      assert output =~ ~s(secret: "***")
    end

    test "unset optional fields render as nil, not as masked" do
      creds = Credentials.new!(api_key: "k", secret: "s")
      output = inspect(creds)

      assert output =~ "password: nil"
      assert output =~ "uid: nil"
      assert output =~ "sandbox: false"
    end

    test "an %Bourse.Exchange{} carrying credentials leaks no key material through inspect" do
      creds = Credentials.new!(api_key: "exchange-embedded-key", secret: "exchange-embedded-secret")
      exchange = Bourse.Exchange.new!("bybit", credentials: creds)

      output = inspect(exchange, limit: :infinity, printable_limit: :infinity)

      refute output =~ "exchange-embedded-key"
      refute output =~ "exchange-embedded-secret"
    end
  end
end
