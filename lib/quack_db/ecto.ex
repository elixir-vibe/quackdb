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
    - `QuackDB.Ecto.List`.
    - `QuackDB.Ecto.Map`.
    - `QuackDB.Ecto.Struct`.
    - `QuackDB.Ecto.Series`.
    - `QuackDB.Ecto.Star`.
    - `QuackDB.Ecto.WindowFrames`.

    `QuackDB.Ecto.Conditionals.case_when/1` is also imported for multi-branch
    DuckDB `CASE WHEN` expressions using Elixir clause syntax.

    Imports can be disabled individually. When spatial and text helpers are both
    enabled, shared `contains/2` dispatches obvious text calls to DuckDB
    `contains` and spatial helper calls to `ST_Contains`. Ambiguous calls raise;
    use `contains_text/2` or `st_contains/2` when intent is not obvious.

        use QuackDB.Ecto, spatial: false
        use QuackDB.Ecto, full_text_search: false
        use QuackDB.Ecto, analytics: false
        use QuackDB.Ecto, regex: false
        use QuackDB.Ecto, text: false
        use QuackDB.Ecto, list: false
        use QuackDB.Ecto, map: false
        use QuackDB.Ecto, struct: false
        use QuackDB.Ecto, series: false
        use QuackDB.Ecto, star: false
        use QuackDB.Ecto, window_frames: false
        use QuackDB.Ecto, query: false
    """

    @doc """
    Returns the sequence name QuackDB migrations use for serial columns.

        QuackDB.Ecto.serial_sequence_name("fragments", :id)
        #=> "fragments_id_seq"

        QuackDB.Ecto.serial_sequence_name({"main", "fragments"}, :id)
        #=> "main_fragments_id_seq"
    """
    @spec serial_sequence_name(
            atom() | String.t() | {atom() | String.t(), atom() | String.t()},
            atom() | String.t()
          ) :: String.t()
    def serial_sequence_name({prefix, table}, field) do
      [prefix, table, field, "seq"]
      |> Enum.map_join("_", &to_string/1)
    end

    def serial_sequence_name(table, field) do
      [table, field, "seq"]
      |> Enum.map_join("_", &to_string/1)
    end

    @doc false
    defmacro __using__(options) do
      enabled? = fn key -> Keyword.get(options, key, true) end
      shared_predicates? = enabled?.(:predicates) and enabled?.(:spatial) and enabled?.(:text)

      imports =
        [
          maybe_import(enabled?.(:query), Ecto.Query),
          maybe_import(enabled?.(:analytics), QuackDB.Ecto.Analytics),
          spatial_import(enabled?.(:spatial), shared_predicates?),
          maybe_import(enabled?.(:full_text_search), QuackDB.Ecto.FTS),
          maybe_import(enabled?.(:series), QuackDB.Ecto.Series),
          maybe_import(enabled?.(:star), QuackDB.Ecto.Star),
          maybe_import(enabled?.(:list), QuackDB.Ecto.List, except: [contains: 2]),
          maybe_import(enabled?.(:map), QuackDB.Ecto.Map,
            except: [contains: 2, extract: 2, values: 1, concat: 2]
          ),
          maybe_import(enabled?.(:struct), QuackDB.Ecto.Struct,
            except: [contains: 2, extract: 2, values: 1, position: 2, concat: 2]
          ),
          maybe_import(enabled?.(:window_frames), QuackDB.Ecto.WindowFrames),
          maybe_import(enabled?.(:regex), QuackDB.Ecto.Regex),
          text_import(enabled?.(:text), shared_predicates?),
          maybe_import(shared_predicates?, QuackDB.Ecto.Predicates),
          maybe_import(enabled?.(:conditionals), QuackDB.Ecto.Conditionals)
        ]
        |> Enum.reject(&is_nil/1)

      quote do
        (unquote_splicing(imports))
      end
    end

    defp spatial_import(false, _shared_predicates?), do: nil

    defp spatial_import(true, true),
      do: import_quoted(QuackDB.Ecto.Spatial, except: [contains: 2])

    defp spatial_import(true, false), do: import_quoted(QuackDB.Ecto.Spatial)

    defp text_import(false, _shared_predicates?), do: nil
    defp text_import(true, true), do: import_quoted(QuackDB.Ecto.Text, except: [contains: 2])
    defp text_import(true, false), do: import_quoted(QuackDB.Ecto.Text)

    defp maybe_import(enabled?, module, options \\ [])
    defp maybe_import(false, _module, _options), do: nil
    defp maybe_import(true, module, options), do: import_quoted(module, options)

    defp import_quoted(module, options \\ [])
    defp import_quoted(module, []), do: quote(do: import(unquote(module)))

    defp import_quoted(module, options),
      do: quote(do: import(unquote(module), unquote(options)))
  end
end
