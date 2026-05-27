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
    - `QuackDB.Ecto.Regex`.
    - `QuackDB.Ecto.Text`.
    - `QuackDB.Ecto.Predicates`.
    - `QuackDB.Ecto.Series`.

    `QuackDB.Ecto.Conditionals.case_when/1` is also imported for multi-branch
    DuckDB `CASE WHEN` expressions using Elixir clause syntax.

    Imports can be disabled individually. When spatial and text helpers are both
    enabled, `contains/2` is provided by `QuackDB.Ecto.Predicates` and dispatches
    obvious text calls to DuckDB `contains` and spatial calls to `ST_Contains`.

        use QuackDB.Ecto, spatial: false
        use QuackDB.Ecto, full_text_search: false
        use QuackDB.Ecto, analytics: false
        use QuackDB.Ecto, regex: false
        use QuackDB.Ecto, text: false
        use QuackDB.Ecto, series: false
        use QuackDB.Ecto, query: false
    """

    @doc false
    defmacro __using__(options) do
      query? = Keyword.get(options, :query, true)
      analytics? = Keyword.get(options, :analytics, true)
      spatial? = Keyword.get(options, :spatial, true)
      full_text_search? = Keyword.get(options, :full_text_search, true)
      series? = Keyword.get(options, :series, true)
      regex? = Keyword.get(options, :regex, true)
      text? = Keyword.get(options, :text, true)
      conditionals? = Keyword.get(options, :conditionals, true)
      predicates? = Keyword.get(options, :predicates, true)

      imports = []
      imports = if query?, do: [quote(do: import(Ecto.Query)) | imports], else: imports

      shared_predicates? = predicates? and spatial? and text?

      imports =
        if analytics?, do: [quote(do: import(QuackDB.Ecto.Analytics)) | imports], else: imports

      imports =
        if spatial? and shared_predicates?,
          do: [quote(do: import(QuackDB.Ecto.Spatial, except: [contains: 2])) | imports],
          else: imports

      imports =
        if spatial? and not shared_predicates?,
          do: [quote(do: import(QuackDB.Ecto.Spatial)) | imports],
          else: imports

      imports =
        if full_text_search?,
          do: [quote(do: import(QuackDB.Ecto.FTS)) | imports],
          else: imports

      imports = if series?, do: [quote(do: import(QuackDB.Ecto.Series)) | imports], else: imports
      imports = if regex?, do: [quote(do: import(QuackDB.Ecto.Regex)) | imports], else: imports

      imports =
        if text? and shared_predicates?,
          do: [quote(do: import(QuackDB.Ecto.Text, except: [contains: 2])) | imports],
          else: imports

      imports =
        if text? and not shared_predicates?,
          do: [quote(do: import(QuackDB.Ecto.Text)) | imports],
          else: imports

      imports =
        if shared_predicates?,
          do: [quote(do: import(QuackDB.Ecto.Predicates)) | imports],
          else: imports

      imports =
        if conditionals?,
          do: [quote(do: import(QuackDB.Ecto.Conditionals)) | imports],
          else: imports

      quote do
        (unquote_splicing(Enum.reverse(imports)))
      end
    end
  end
end
