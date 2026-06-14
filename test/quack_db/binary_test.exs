defmodule QuackDB.BinaryTest do
  use ExUnit.Case, async: false

  test "exposes pinned version and known checksum targets" do
    assert QuackDB.Binary.default_version() == "1.5.3"

    assert {"1.5.3", "linux-amd64"} in QuackDB.Binary.known_targets()
    assert {"1.5.3", "linux-arm64"} in QuackDB.Binary.known_targets()
    assert {"1.5.3", "osx-amd64"} in QuackDB.Binary.known_targets()
    assert {"1.5.3", "osx-arm64"} in QuackDB.Binary.known_targets()
  end

  test "detects Nix-style macOS architecture triples" do
    assert QuackDB.Binary.target_for_system({:unix, :darwin}, "aarch64-apple-darwin25.3.0") ==
             {:ok, "osx-arm64"}

    assert QuackDB.Binary.target_for_system({:unix, :darwin}, "arm64-apple-darwin25.3.0") ==
             {:ok, "osx-arm64"}

    assert QuackDB.Binary.target_for_system({:unix, :darwin}, "x86_64-apple-darwin25.3.0") ==
             {:ok, "osx-amd64"}
  end

  test "respects explicit path option" do
    path = System.find_executable("duckdb")

    if path do
      assert {:ok, ^path} = QuackDB.Binary.path(path: path)
    end
  end

  test "respects QUACKDB_BINARY_PATH override" do
    path = System.find_executable("duckdb")

    if path do
      previous = System.get_env("QUACKDB_BINARY_PATH")
      System.put_env("QUACKDB_BINARY_PATH", path)

      try do
        assert {:ok, ^path} = QuackDB.Binary.path()
      after
        restore_env("QUACKDB_BINARY_PATH", previous)
      end
    end
  end

  test "returns an error for invalid QUACKDB_BINARY_PATH" do
    previous = System.get_env("QUACKDB_BINARY_PATH")
    System.put_env("QUACKDB_BINARY_PATH", "/definitely/missing/duckdb")

    try do
      assert {:error, %QuackDB.Error{code: :invalid_duckdb_binary}} = QuackDB.Binary.path()
    after
      restore_env("QUACKDB_BINARY_PATH", previous)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
