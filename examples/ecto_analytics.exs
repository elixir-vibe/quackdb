Mix.install([
  {:quackdb, path: Path.expand("..", __DIR__)},
  {:ecto_sql, "~> 3.13"}
])

Code.require_file("support/quackdb_demo.exs", __DIR__)

Application.put_env(:quackdb, EctoAnalyticsExample.Repo,
  adapter: Ecto.Adapters.QuackDB,
  uri: System.get_env("QUACKDB_URI"),
  token: System.get_env("QUACKDB_TOKEN", "")
)

defmodule EctoAnalyticsExample.Repo do
  use Ecto.Repo,
    otp_app: :quackdb,
    adapter: Ecto.Adapters.QuackDB
end

defmodule EctoAnalyticsExample.Queries do
  use QuackDB.Ecto

  def summary(table) do
    from(event in table,
      group_by: [date_part(:hour, event.occurred_at), selected_as(:tier)],
      order_by: [date_part(:hour, event.occurred_at), selected_as(:tier)],
      select: %{
        hour: date_part(:hour, event.occurred_at),
        tier:
          selected_as(
            case_when do
              event.score >= 90 -> "high"
              event.score >= 50 and event.score <= 89 -> "medium"
              true -> "low"
            end,
            :tier
          ),
        events: count(),
        distinct_events: count(event.id, :distinct),
        high_events: filter(count(event.id), event.score >= 90),
        scores: list(event.score, order_by: [desc_nulls_last: event.score]),
        average_score: coalesce(avg(event.score), 0),
        score_stddev: stddev(event.score),
        score_histogram: histogram(event.score)
      }
    )
  end
end

%{server: server} = QuackDBDemo.start_connection()

repo_options =
  if server do
    [uri: QuackDB.Server.uri(server), token: "super_secret"]
  else
    [uri: System.fetch_env!("QUACKDB_URI"), token: System.get_env("QUACKDB_TOKEN", "")]
  end

{:ok, _repo} = EctoAnalyticsExample.Repo.start_link(repo_options)

table = "ecto_analytics_events_#{System.unique_integer([:positive])}"

EctoAnalyticsExample.Repo.query!(
  QuackDB.DDL.create_table(
    table,
    id: :integer,
    score: :integer,
    occurred_at: :timestamp
  )
)

EctoAnalyticsExample.Repo.query!(
  QuackDB.DML.insert_into(table, [
    [id: 1, score: 95, occurred_at: ~N[2024-01-01 09:00:00]],
    [id: 2, score: 96, occurred_at: ~N[2024-01-01 09:15:00]],
    [id: 3, score: 72, occurred_at: ~N[2024-01-01 10:00:00]],
    [id: 4, score: 88, occurred_at: ~N[2024-01-01 10:30:00]]
  ])
)

EctoAnalyticsExample.Repo.all(EctoAnalyticsExample.Queries.summary(table))
|> IO.inspect(label: "analytics", charlists: :as_lists)

EctoAnalyticsExample.Repo.query!(QuackDB.Analytics.summarize(table)).rows
|> IO.inspect(label: "profile", charlists: :as_lists)
