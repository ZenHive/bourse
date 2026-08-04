defmodule Mix.Tasks.Ccxt.BuildLighterSignerTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Ccxt.BuildLighterSigner

  test "source and output paths are independent of the consuming project working directory" do
    project_root = File.cwd!()

    File.cd!(System.tmp_dir!(), fn ->
      assert BuildLighterSigner.source_dir() == Path.join(project_root, "native/lighter_signer")

      assert BuildLighterSigner.output_dir("darwin-arm64") ==
               Application.app_dir(:bourse, ["priv", "native", "lighter_signer", "darwin-arm64"])
    end)
  end
end
