defmodule QuackDB.Ecto.SQLGeneration.TaggedParamsTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  test "uses placeholders for planner tagged field params" do
    name = "phoenix"

    query = from(pkg in "packages", where: pkg.name == ^name, select: pkg.id)

    planned = %{
      query
      | wheres: [
          %{
            hd(query.wheres)
            | expr:
                {:==, [],
                 [
                   {{:., [], [{:&, [], [0]}, :name]}, [], []},
                   %Ecto.Query.Tagged{value: name, type: {0, :name}}
                 ]}
          }
        ]
    }

    assert planned |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT q0."id" FROM "packages" AS q0 WHERE (q0."name" = ?)]
  end

  test "casts non-field tagged params while preserving placeholders" do
    query =
      from(row in "fragments", where: fragment("? @> ?", row.terms, ^[1, 2]), select: row.id)

    planned = %{
      query
      | wheres: [
          %{
            hd(query.wheres)
            | expr:
                {:fragment, [],
                 [
                   raw: "",
                   expr: {{:., [], [{:&, [], [0]}, :terms]}, [], []},
                   raw: " @> ",
                   expr: %Ecto.Query.Tagged{value: [1, 2], type: {:array, :integer}},
                   raw: ""
                 ]}
          }
        ],
        limit: %{expr: %Ecto.Query.Tagged{value: 10, type: :integer}}
    }

    assert planned |> Ecto.Adapters.QuackDB.Connection.all() |> IO.iodata_to_binary() ==
             "SELECT q0.\"id\" FROM \"fragments\" AS q0 WHERE q0.\"terms\" @> CAST(? AS INTEGER[]) LIMIT CAST(? AS INTEGER)"
  end
end
