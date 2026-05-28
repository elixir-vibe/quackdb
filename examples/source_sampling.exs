Mix.install([
  {:quackdb, path: Path.expand("..", __DIR__)},
  {:ecto_sql, "~> 3.13"}
])

Code.require_file("support/quackdb_demo.exs", __DIR__)

Application.put_env(:quackdb, SourceSamplingExample.Repo,
  adapter: Ecto.Adapters.QuackDB,
  uri: System.get_env("QUACKDB_URI"),
  token: System.get_env("QUACKDB_TOKEN", "")
)

defmodule SourceSamplingExample.Repo do
  use Ecto.Repo,
    otp_app: :quackdb,
    adapter: Ecto.Adapters.QuackDB
end

%{server: server} = QuackDBDemo.start_connection()

repo_options =
  if server do
    [uri: QuackDB.Server.uri(server), token: "super_secret"]
  else
    [uri: System.fetch_env!("QUACKDB_URI"), token: System.get_env("QUACKDB_TOKEN", "")]
  end

{:ok, _repo} = SourceSamplingExample.Repo.start_link(repo_options)

path =
  Path.join(
    System.tmp_dir!(),
    "quackdb-source-sampling-#{System.unique_integer([:positive])}.json"
  )

File.write!(path, """
{"name":"duck","kind":"bird","score":95}
{"name":"goose","kind":"bird","score":72}
{"name":"salmon","kind":"fish","score":88}
""")

source = QuackDB.Source.json(path, format: :newline_delimited)
sampled = QuackDB.Source.sample(source, rows: 2)

defmodule SourceSamplingExample.Queries do
  import Ecto.Query

  def sampled_summary(source) do
    from(event in source,
      group_by: event.kind,
      select: %{
        kind: event.kind,
        events: count(),
        average_score: avg(event.score)
      }
    )
  end
end

SourceSamplingExample.Repo.all(SourceSamplingExample.Queries.sampled_summary(sampled))
|> IO.inspect(label: "sampled source analytics", charlists: :as_lists)

SourceSamplingExample.Repo.query!(
  QuackDB.Analytics.summarize({:query, "SELECT kind, score FROM #{sampled}"})
)
|> Map.fetch!(:rows)
|> IO.inspect(label: "sampled source profile", charlists: :as_lists)

File.rm(path)
