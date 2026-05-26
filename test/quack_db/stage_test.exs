defmodule QuackDB.StageTest do
  use ExUnit.Case, async: true

  test "serves a local file for the callback duration" do
    path = Path.join(System.tmp_dir!(), "quackdb-stage-#{System.unique_integer([:positive])}.csv")
    File.write!(path, "id,name\n1,duck\n")

    try do
      assert "id,name\n1,duck\n" =
               QuackDB.Stage.with_file(path, fn staged ->
                 assert staged.path == path
                 assert staged.file_name == Path.basename(path)
                 assert staged.port > 0

                 staged.url
                 |> Req.get!()
                 |> Map.fetch!(:body)
               end)
    after
      File.rm(path)
    end
  end

  test "raises for missing files" do
    assert_raise ArgumentError, ~r/expected a regular file to stage/, fn ->
      QuackDB.Stage.with_file("/definitely/missing.csv", fn _staged -> :ok end)
    end
  end
end
