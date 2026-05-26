defmodule QuackDB.BinaryTest do
  use ExUnit.Case, async: false

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
