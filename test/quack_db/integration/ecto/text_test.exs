defmodule QuackDB.Integration.Ecto.TextTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.Ecto.Text
  import QuackDB.QuackServerCase
  import QuackDB.TestHelper

  @moduletag :integration

  test "text helpers execute against a real Quack server" do
    start_repo!()
    table = unique_table("quackdb_ecto_text")

    create_table!(QuackDB.IntegrationRepo, table,
      id: :integer,
      name: :varchar,
      kind: :varchar
    )

    insert_rows!(QuackDB.IntegrationRepo, table, [
      [1, "duck-goose", "bird"],
      [2, "salmon trout", "fish"]
    ])

    query =
      from(event in table,
        order_by: event.id,
        select: %{
          has_duck: contains(event.name, "duck"),
          has_duck_explicit: contains_text(event.name, "duck"),
          starts_with_duck: starts_with(event.name, "duck"),
          ends_with_trout: ends_with(event.name, "trout"),
          has_prefix: prefix(event.name, "du"),
          has_suffix: suffix(event.name, "se"),
          second_part: split_part(event.name, "-", 2),
          words: string_split(event.name, " "),
          regex_parts: string_split_regex(event.name, "[-\\s]+")
        }
      )

    assert [
             %{
               has_duck: true,
               has_duck_explicit: true,
               starts_with_duck: true,
               ends_with_trout: false,
               has_prefix: true,
               has_suffix: true,
               second_part: "goose",
               words: ["duck-goose"],
               regex_parts: ["duck", "goose"]
             },
             %{
               has_duck: false,
               has_duck_explicit: false,
               starts_with_duck: false,
               ends_with_trout: true,
               has_prefix: false,
               has_suffix: false,
               second_part: "",
               words: ["salmon", "trout"],
               regex_parts: ["salmon", "trout"]
             }
           ] = QuackDB.IntegrationRepo.all(query)
  end
end
