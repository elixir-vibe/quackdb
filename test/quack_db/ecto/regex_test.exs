defmodule QuackDB.Ecto.RegexTest do
  use ExUnit.Case, async: true

  import Ecto.Query
  import QuackDB.Ecto.Regex

  test "builds regexp predicate expressions" do
    query =
      from(event in "events",
        where:
          regexp_matches(event.name, ~r/^duck/i) and
            regexp_full_match(event.kind, "duck|goose", "c"),
        select: %{name: event.name}
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."name" AS "name" FROM "events" AS q0 WHERE (regexp_matches(q0."name", '^duck', 'i') AND regexp_full_match(q0."kind", 'duck|goose', 'c'))]
  end

  test "builds regexp extraction and replacement expressions" do
    query =
      from(event in "events",
        select: %{
          year: regexp_extract(event.name, ~r/(\d{4})/, 1),
          all_numbers: regexp_extract_all(event.name, "\\d+"),
          slug: regexp_replace(event.name, ~r/\s+/, "-", "g")
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT regexp_extract(q0."name", '(\d{4})', 1) AS "year", regexp_extract_all(q0."name", '\d+') AS "all_numbers", regexp_replace(q0."name", '\s+', '-', 'g') AS "slug" FROM "events" AS q0]
  end

  test "builds regexp split and escape expressions" do
    query =
      from(event in "events",
        select: %{
          parts: regexp_split_to_array(event.name, ~r/\s*,\s*/),
          escaped: regexp_escape(event.name)
        }
      )

    assert query |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT regexp_split_to_array(q0."name", '\s*,\s*') AS "parts", regexp_escape(q0."name") AS "escaped" FROM "events" AS q0]
  end

  test "rejects Elixir regex modifiers that DuckDB cannot represent" do
    assert_raise ArgumentError, ~r/unsupported DuckDB regex modifier: x/, fn ->
      defmodule UnsupportedRegexModifierProbe do
        import Ecto.Query
        import QuackDB.Ecto.Regex

        def query do
          from(event in "events", where: regexp_matches(event.name, ~r/duck/x))
        end
      end
    end
  end
end
