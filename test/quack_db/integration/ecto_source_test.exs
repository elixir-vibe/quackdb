defmodule QuackDB.Integration.EctoSourceTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.QuackServerCase
  import QuackDB.TestHelper

  @moduletag :integration

  test "Ecto Repo.all/2 queries source helpers against a real Quack server" do
    start_repo!()

    source = csv_source!("id,name\n1,duck\n2,goose\n")

    query =
      from(event in source,
        where: event.id > 1,
        select: %{id: event.id, name: event.name}
      )

    assert [%{id: 2, name: "goose"}] = QuackDB.IntegrationRepo.all(query)
  end

  test "Ecto Repo.all/2 queries fragment sources against a real Quack server" do
    start_repo!()

    path = csv_file!("id,name\n1,duck\n2,goose\n", "quackdb_ecto_fragment")

    query =
      from(event in fragment("read_csv(?, header = TRUE)", ^path),
        where: event.id > 1,
        select: %{id: event.id, name: event.name}
      )

    assert [%{id: 2, name: "goose"}] = QuackDB.IntegrationRepo.all(query)
  end
end
