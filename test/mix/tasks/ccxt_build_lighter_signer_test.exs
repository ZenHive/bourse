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

  describe "target_for/3" do
    test "maps every unix host the release matrix builds on" do
      assert BuildLighterSigner.target_for({:unix, :darwin}, "aarch64-apple-darwin23.6.0") ==
               "darwin-arm64"

      assert BuildLighterSigner.target_for({:unix, :linux}, "x86_64-pc-linux-gnu") ==
               "linux-amd64"

      assert BuildLighterSigner.target_for({:unix, :linux}, "aarch64-unknown-linux-gnu") ==
               "linux-arm64"
    end

    # Windows answers `:system_architecture` with "win32" — the OS, not the CPU
    # — which is why the architecture has to come from the environment. The
    # windows-amd64 runner failed here before that split existed.
    test "reads the architecture from the environment on windows, ignoring win32" do
      assert BuildLighterSigner.target_for({:win32, :nt}, "win32", %{
               "PROCESSOR_ARCHITECTURE" => "AMD64"
             }) == "windows-amd64"

      assert BuildLighterSigner.target_for({:win32, :nt}, "win32", %{
               "PROCESSOR_ARCHITECTURE" => "ARM64"
             }) == "windows-arm64"
    end

    test "prefers the WOW64 host architecture over the emulated one" do
      assert BuildLighterSigner.target_for({:win32, :nt}, "win32", %{
               "PROCESSOR_ARCHITECTURE" => "x86",
               "PROCESSOR_ARCHITEW6432" => "AMD64"
             }) == "windows-amd64"
    end

    test "fails loudly rather than guessing when the host cannot be identified" do
      assert_raise Mix.Error, ~r/PROCESSOR_ARCHITECTURE is unset/, fn ->
        BuildLighterSigner.target_for({:win32, :nt}, "win32", %{})
      end

      assert_raise Mix.Error, ~r/Unsupported architecture: mips64/, fn ->
        BuildLighterSigner.target_for({:unix, :linux}, "mips64", %{})
      end
    end

    test "agrees with the host target this suite is running on" do
      assert BuildLighterSigner.host_target() in ~w(darwin-arm64 linux-amd64 linux-arm64 windows-amd64)
    end
  end

  describe "target naming" do
    test "windows carries an executable suffix the unix targets do not" do
      assert BuildLighterSigner.executable_name("windows-amd64") == "bourse_lighter_signer.exe"
      assert BuildLighterSigner.executable_name("linux-amd64") == "bourse_lighter_signer"
      assert BuildLighterSigner.executable_name("darwin-arm64") == "bourse_lighter_signer"
    end
  end
end
