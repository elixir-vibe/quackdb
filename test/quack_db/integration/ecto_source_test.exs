defmodule QuackDB.Integration.EctoSourceTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.QuackServerCase

  @moduletag :integration

  test "Ecto Repo.all/2 queries source helpers against a real Quack server" do
    start_repo!()

    path =
      Path.join(
        System.tmp_dir!(),
        "quackdb_ecto_source_#{System.unique_integer([:positive])}.csv"
      )

    File.write!(path, "id,name\n1,duck\n2,goose\n")

    on_exit(fn -> File.rm(path) end)

    source = QuackDB.Source.csv(path, header: true)

    query =
      from(event in source,
        where: event.id > 1,
        select: %{id: event.id, name: event.name}
      )

    assert [%{id: 2, name: "goose"}] = QuackDB.IntegrationRepo.all(query)
  end

  test "Ecto Repo.all/2 queries fragment sources against a real Quack server" do
    start_repo!()

    path =
      Path.join(
        System.tmp_dir!(),
        "quackdb_ecto_fragment_#{System.unique_integer([:positive])}.csv"
      )

    File.write!(path, "id,name\n1,duck\n2,goose\n")

    on_exit(fn -> File.rm(path) end)

    query =
      from(event in fragment("read_csv(?, header = TRUE)", ^path),
        where: event.id > 1,
        select: %{id: event.id, name: event.name}
      )

    assert [%{id: 2, name: "goose"}] = QuackDB.IntegrationRepo.all(query)
  end
end
