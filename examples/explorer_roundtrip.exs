Mix.install([
  {:quackdb, path: Path.expand("..", __DIR__)},
  {:ecto_sql, "~> 3.13"},
  {:explorer, "~> 0.11"}
])

defmodule ExplorerRoundtrip.Event do
  use Ecto.Schema

  @primary_key false
  schema "explorer_events" do
    field(:id, :integer)
    field(:category, :string)
    field(:score, :float)
  end
end

defmodule ExplorerRoundtrip.Connection do
  def start do
    case System.get_env("QUACKDB_URI") do
      nil ->
        token = "super_secret"
        {:ok, server} = QuackDB.Server.start_link(token: token)
        QuackDB.start_link(uri: QuackDB.Server.uri(server), token: token)

      uri ->
        QuackDB.start_link(uri: uri, token: System.get_env("QUACKDB_TOKEN", ""))
    end
  end
end

defmodule ExplorerRoundtrip.SchemaDDL do
  def create_table(schema, options \\ []) do
    columns =
      Enum.map(schema.__schema__(:fields), fn field ->
        {field, duckdb_type(schema.__schema__(:type, field))}
      end)

    QuackDB.DDL.create_table(schema.__schema__(:source), columns, options)
  end

  defp duckdb_type(:integer), do: :integer
  defp duckdb_type(:string), do: :varchar
  defp duckdb_type(:float), do: :double
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
alias ExplorerRoundtrip.Connection
alias ExplorerRoundtrip.Event
alias ExplorerRoundtrip.Queries
alias ExplorerRoundtrip.SchemaDDL

{:ok, conn} = Connection.start()

table = Event.__schema__(:source)

QuackDB.query!(conn, QuackDB.DDL.drop_table(table, if_exists: true))
QuackDB.query!(conn, SchemaDDL.create_table(Event, temporary: true))

df =
  DataFrame.new(
    id: [1, 2, 3, 4],
    category: ["alpha", "alpha", "beta", "beta"],
    score: [10.0, 20.0, 15.0, 25.0]
  )

QuackDB.Explorer.insert_dataframe!(conn, table, df, batch_size: 2)

summary = QuackDB.Explorer.dataframe!(conn, Queries.summary())

IO.inspect(summary, label: "summary dataframe")
