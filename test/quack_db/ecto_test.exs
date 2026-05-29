defmodule QuackDB.EctoTest do
  use ExUnit.Case, async: true

  test "imports Ecto query, analytics, spatial, regex, list, and non-conflicting text helpers by default" do
    defmodule DefaultImports do
      use QuackDB.Ecto

      def query do
        from(event in "events",
          where:
            intersects(event.geom, envelope(0, 0, 10, 10)) and
              regexp_matches(event.name, ~r/duck/i) and contains_text(event.name, "duck") and
              contains_list(event.tags, ^"duck") and has_any(event.tags, ^["duck"]),
          group_by: event.category,
          select: %{category: event.category, median_score: median(event.score)}
        )
      end
    end

    assert %Ecto.Query{} = DefaultImports.query()
  end

  test "allows optional imports to be disabled" do
    defmodule QueryOnlyImports do
      use QuackDB.Ecto, analytics: false, spatial: false, regex: false, text: false, list: false

      def query do
        from(event in "events", select: event.id)
      end
    end

    assert %Ecto.Query{} = QueryOnlyImports.query()
  end
end
