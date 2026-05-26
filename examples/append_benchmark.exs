Mix.install([
  {:quackdb, path: Path.expand("..", __DIR__)},
  {:ecto_sql, "~> 3.13"},
  {:explorer, "~> 0.11"},
  {:benchee, "~> 1.3"}
])

Code.require_file("support/quackdb_demo.exs", __DIR__)

defmodule AppendBenchmark.Event do
  use Ecto.Schema

  @primary_key false
  schema "append_benchmark_events" do
    field(:id, :integer)
    field(:category, :string)
    field(:score, :float)
  end
end

defmodule AppendBenchmark.Repo do
  use Ecto.Repo,
    otp_app: :append_benchmark,
    adapter: Ecto.Adapters.QuackDB
end

defmodule AppendBenchmark do
  alias Explorer.DataFrame
  alias QuackDB.DML
  alias AppendBenchmark.Event
  alias AppendBenchmark.Repo

  def setup do
    %{conn: conn} = QuackDBDemo.start_connection()

    Application.put_env(:append_benchmark, Repo,
      uri: connection_uri(conn),
      token: connection_token(),
      pool_size: 1,
      log: false
    )

    {:ok, _repo} = Repo.start_link()
    %{conn: conn}
  end

  def rows(count) do
    Enum.map(1..count, fn id ->
      [id: id, category: category(id), score: id / 10]
    end)
  end

  def columns(rows) do
    [
      id: Enum.map(rows, &Keyword.fetch!(&1, :id)),
      category: Enum.map(rows, &Keyword.fetch!(&1, :category)),
      score: Enum.map(rows, &Keyword.fetch!(&1, :score))
    ]
  end

  def dataframe(rows) do
    rows
    |> columns()
    |> DataFrame.new()
  end

  def reset_table!(conn, table) do
    QuackDB.query!(conn, QuackDB.DDL.drop_table(table, if_exists: true))
    QuackDB.query!(conn, QuackDB.DDL.create_table(Event))
  end

  def insert_sql!(conn, table, rows) do
    QuackDB.query!(conn, DML.insert_into(table, rows))
  end

  defp category(id), do: Enum.at(["alpha", "beta", "gamma", "delta"], rem(id, 4))

  defp connection_uri(_conn), do: System.get_env("QUACKDB_URI", "http://[::1]:9494")
  defp connection_token, do: System.get_env("QUACKDB_TOKEN", "super_secret")
end

count = System.get_env("ROWS", "1000") |> String.to_integer()
batch_size = System.get_env("BATCH_SIZE", "1000") |> String.to_integer()
%{conn: conn} = AppendBenchmark.setup()
table = AppendBenchmark.Event.__schema__(:source)
rows = AppendBenchmark.rows(count)
columns = AppendBenchmark.columns(rows)
dataframe = AppendBenchmark.dataframe(rows)

Benchee.run(
  %{
    "SQL INSERT VALUES" => fn ->
      AppendBenchmark.reset_table!(conn, table)
      AppendBenchmark.insert_sql!(conn, table, rows)
    end,
    "native insert_rows" => fn ->
      AppendBenchmark.reset_table!(conn, table)
      QuackDB.insert_rows!(conn, table, rows, batch_size: batch_size)
    end,
    "native insert_columns" => fn ->
      AppendBenchmark.reset_table!(conn, table)
      QuackDB.insert_columns!(conn, table, columns, batch_size: batch_size)
    end,
    "Explorer insert_dataframe" => fn ->
      AppendBenchmark.reset_table!(conn, table)
      QuackDB.Explorer.insert_dataframe!(conn, table, dataframe, batch_size: batch_size)
    end,
    "Ecto insert_all SQL" => fn ->
      AppendBenchmark.reset_table!(conn, table)
      AppendBenchmark.Repo.insert_all(AppendBenchmark.Event, rows)
    end,
    "Ecto insert_all append" => fn ->
      AppendBenchmark.reset_table!(conn, table)

      AppendBenchmark.Repo.insert_all(AppendBenchmark.Event, rows,
        insert_method: :append,
        chunk_every: batch_size
      )
    end
  },
  time: 3,
  memory_time: 0,
  warmup: 1
)
