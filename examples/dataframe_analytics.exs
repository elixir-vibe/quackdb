Mix.install([
  {:quackdb, path: Path.expand("..", __DIR__)},
  {:ecto_sql, "~> 3.13"},
  {:explorer, "~> 0.11"}
])

Code.require_file("support/quackdb_demo.exs", __DIR__)

defmodule ExplorerRoundtrip.Event do
  use Ecto.Schema

  @primary_key false
  schema "explorer_events" do
    field(:id, :integer)
    field(:category, :string)
    field(:score, :float)
  end
end

defmodule ExplorerRoundtrip.Queries do
  import Ecto.Query

  alias ExplorerRoundtrip.Event

  def summary do
    from(event in Event,
      group_by: event.category,
      order_by: event.category,
      select: %{
        category: event.category,
        events: count(event.id),
        avg_score: avg(event.score)
      }
    )
  end
end

alias Explorer.DataFrame
alias ExplorerRoundtrip.Event
alias ExplorerRoundtrip.Queries

%{conn: conn} = QuackDBDemo.start_connection()

table = Event.__schema__(:source)

QuackDB.query!(conn, QuackDB.DDL.drop_table(table, if_exists: true))
QuackDB.query!(conn, QuackDB.DDL.create_table(Event, temporary: true))

df =
  DataFrame.new(
    id: [1, 2, 3, 4],
    category: ["alpha", "alpha", "beta", "beta"],
    score: [10.0, 20.0, 15.0, 25.0]
  )

QuackDB.Explorer.insert_dataframe!(conn, table, df, batch_size: 2)

summary = QuackDB.Explorer.dataframe!(conn, Queries.summary())

IO.inspect(summary, label: "summary dataframe")
