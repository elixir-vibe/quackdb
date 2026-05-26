if Code.ensure_loaded?(Ecto.Query) do
  defmodule QuackDB.Ecto do
    @moduledoc """
    Convenience imports for Ecto-based QuackDB query modules.

    Use this in modules that build DuckDB analytical, spatial, series, or
    full-text search Ecto queries and want the standard Ecto query DSL together with
    QuackDB's Ecto helper macros:

        defmodule MyApp.Analytics do
          use QuackDB.Ecto

          def category_scores do
            from event in "events",
              group_by: event.category,
              select: %{
                category: event.category,
                median_score: median(event.score),
                fts_score: search_score("fts_main_events", event.id, ^"duckdb")
              }
          end
        end

    The macro imports:

    - `Ecto.Query`.
    - `QuackDB.Ecto.Analytics`.
    - `QuackDB.Ecto.Spatial`.
    - `QuackDB.Ecto.FTS`.
    - `QuackDB.Ecto.Series`.

    Pass `conditionals: true` to opt into `QuackDB.Ecto.Conditionals`, which
    replaces Kernel's `if/2` in the caller so `if ... do ... else ... end` can
    be used as a DuckDB `CASE WHEN` expression inside Ecto queries.

    Imports can be disabled individually:

        use QuackDB.Ecto, spatial: false
        use QuackDB.Ecto, full_text_search: false
        use QuackDB.Ecto, analytics: false
        use QuackDB.Ecto, series: false
        use QuackDB.Ecto, query: false
        use QuackDB.Ecto, conditionals: true
    """

    @doc false
    defmacro __using__(options) do
      query? = Keyword.get(options, :query, true)
      analytics? = Keyword.get(options, :analytics, true)
      spatial? = Keyword.get(options, :spatial, true)
      full_text_search? = Keyword.get(options, :full_text_search, true)
      series? = Keyword.get(options, :series, true)
      conditionals? = Keyword.get(options, :conditionals, false)

      imports = []
      imports = if query?, do: [quote(do: import(Ecto.Query)) | imports], else: imports

      imports =
        if analytics?, do: [quote(do: import(QuackDB.Ecto.Analytics)) | imports], else: imports

      imports =
        if spatial?, do: [quote(do: import(QuackDB.Ecto.Spatial)) | imports], else: imports

      imports =
        if full_text_search?,
          do: [quote(do: import(QuackDB.Ecto.FTS)) | imports],
          else: imports

      imports = if series?, do: [quote(do: import(QuackDB.Ecto.Series)) | imports], else: imports

      imports =
        if conditionals?,
          do: [quote(do: use(QuackDB.Ecto.Conditionals)) | imports],
          else: imports

      quote do
        (unquote_splicing(Enum.reverse(imports)))
      end
    end
  end
end
