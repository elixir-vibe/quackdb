defmodule QuackDB.BinaryTest do
  use ExUnit.Case, async: false

  test "exposes pinned version and known checksum targets" do
    assert QuackDB.Binary.default_version() == "2.0.0"

    for target <-
          ~w(linux-amd64 linux-amd64-musl linux-arm64 linux-arm64-musl osx-amd64 osx-arm64 osx-universal) do
      assert {"2.0.0", target} in QuackDB.Binary.known_targets()
    end
  end

  test "distinguishes musl and glibc Linux architecture triples" do
    for {arch, target} <- [{"x86_64", "linux-amd64"}, {"aarch64", "linux-arm64"}] do
      for triple <- ["#{arch}-alpine-linux-musl", "#{arch}-unknown-linux-musl"] do
        assert QuackDB.Binary.target_for_system({:unix, :linux}, triple) ==
                 {:ok, target <> "-musl"}
      end

      for triple <- ["#{arch}-pc-linux-gnu", "#{arch}-unknown-linux-gnu"] do
        assert QuackDB.Binary.target_for_system({:unix, :linux}, triple) == {:ok, target}
      end
    end
  end

  test "rejects unsupported targets" do
    results = [
      QuackDB.Binary.target_for_system({:unix, :linux}, "riscv64-unknown-linux-musl"),
      QuackDB.Binary.target_for_system({:win32, :nt}, "x86_64-pc-windows"),
      QuackDB.Binary.install(target: "linux-riscv64-musl")
    ]

    for result <- results do
      assert {:error, %QuackDB.Error{code: :unsupported_target}} = result
    end
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
    path = QuackDB.TestHelper.duckdb_2_path()

    if path do
      assert {:ok, ^path} = QuackDB.Binary.path(path: path)
    end
  end

  test "respects QUACKDB_BINARY_PATH override" do
    path = QuackDB.TestHelper.duckdb_2_path()

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

  test "rejects DuckDB CLIs older than 2.0" do
    case System.find_executable("duckdb") do
      nil ->
        :ok

      path ->
        if path != QuackDB.TestHelper.duckdb_2_path() do
          assert {:error, %QuackDB.Error{code: code}} = QuackDB.Binary.path(path: path)
          assert code in [:invalid_duckdb_binary, :unsupported_duckdb_version]
        end
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
