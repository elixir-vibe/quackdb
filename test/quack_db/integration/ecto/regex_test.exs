defmodule QuackDB.Integration.Ecto.RegexTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import QuackDB.Ecto.Regex
  import QuackDB.QuackServerCase
  import QuackDB.TestHelper

  @moduletag :integration

  test "regular-expression helpers execute against a real Quack server" do
    start_repo!()
    table = unique_table("quackdb_ecto_regex")

    create_table!(QuackDB.IntegrationRepo, table,
      id: :integer,
      name: :varchar,
      kind: :varchar
    )

    insert_rows!(QuackDB.IntegrationRepo, table, [
      [1, "Duck 2024", "bird"],
      [2, "salmon, trout", "fish"]
    ])

    query =
      from(event in table,
        order_by: event.id,
        select: %{
          matches_duck: regexp_matches(event.name, ~r/^duck/i),
          bird_kind: regexp_full_match(event.kind, ~r/bird/),
          year: regexp_extract(event.name, ~r/(\d{4})/, 1),
          numbers: regexp_extract_all(event.name, ~r/\d+/),
          slug: regexp_replace(event.name, ~r/\s+/, "-", "g"),
          parts: regexp_split_to_array(event.name, ~r/\s*,\s*/),
          escaped: regexp_escape(event.kind)
        }
      )

    assert [
             %{
               matches_duck: true,
               bird_kind: true,
               year: "2024",
               numbers: ["2024"],
               slug: "Duck-2024",
               parts: ["Duck 2024"],
               escaped: "bird"
             },
             %{
               matches_duck: false,
               bird_kind: false,
               year: "",
               numbers: [],
               slug: "salmon,-trout",
               parts: ["salmon", "trout"],
               escaped: "fish"
             }
           ] = QuackDB.IntegrationRepo.all(query)
  end
end
