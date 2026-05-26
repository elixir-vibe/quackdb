if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.FullTextSearch do
    @moduledoc """
    DuckDB full-text search expression helpers for Ecto queries.

    Create/drop indexes with `QuackDB.FullTextSearch`, then use these macros in
    normal Ecto queries.
    """

    defmacro match_bm25(schema, id, query) when is_binary(schema) do
      quote do
        fragment(unquote(~s|"#{schema}".match_bm25(?, ?)|), unquote(id), unquote(query))
      end
    end

    defmacro match_bm25({:^, _, [schema]}, id, query) do
      quote do
        fragment("?.match_bm25(?, ?)", identifier(^unquote(schema)), unquote(id), unquote(query))
      end
    end

    defmacro match_bm25(id, query, options) do
      fields = Keyword.get(options, :fields)
      k = Keyword.get(options, :k)
      b = Keyword.get(options, :b)
      conjunctive = Keyword.get(options, :conjunctive)

      cond do
        fields && k && b && !is_nil(conjunctive) ->
          quote do
            fragment(
              "match_bm25(?, ?, fields := ?, k := ?, b := ?, conjunctive := ?)",
              unquote(id),
              unquote(query),
              unquote(fields),
              unquote(k),
              unquote(b),
              unquote(conjunctive)
            )
          end

        fields ->
          quote do
            fragment(
              "match_bm25(?, ?, fields := ?)",
              unquote(id),
              unquote(query),
              unquote(fields)
            )
          end

        k || b || !is_nil(conjunctive) ->
          raise ArgumentError,
                "QuackDB.Ecto.FullTextSearch.match_bm25/3 requires :fields when passing BM25 options"

        true ->
          quote do
            fragment("match_bm25(?, ?)", unquote(id), unquote(query))
          end
      end
    end

    defmacro match_bm25(id, query) do
      quote do
        fragment("match_bm25(?, ?)", unquote(id), unquote(query))
      end
    end

    defmacro stem(text) do
      quote do
        fragment("stem(?)", unquote(text))
      end
    end

    defmacro stem(text, stemmer) do
      quote do
        fragment("stem(?, ?)", unquote(text), unquote(stemmer))
      end
    end
  end
end
