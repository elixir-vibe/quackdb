if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.Regex do
    @moduledoc """
    DuckDB regular-expression helpers for Ecto queries.

    DuckDB uses RE2 regular expressions. Elixir's `Regex` uses Erlang/OTP `:re`,
    so only the shared regex subset is portable. Literal `~r/.../` patterns are
    accepted for convenience and their compatible modifiers are translated to
    DuckDB options.

        import Ecto.Query
        import QuackDB.Ecto.Regex

        from event in "events",
          where: regexp_matches(event.name, ~r/^duck/i),
          select: %{
            year: regexp_extract(event.name, ~r/(\\d{4})/, 1),
            slug: regexp_replace(event.name, ~r/\\s+/, "-", "g"),
            parts: regexp_split_to_array(event.name, ~r/\\s*,\\s*/)
          }

    Compatible `~r` modifiers are translated to DuckDB option strings: `i`, `m`,
    and `s`. Elixir's Unicode modifier is ignored; unsupported modifiers raise at
    macro expansion time.
    """

    @regex_helpers [
      %{name: :regexp_escape, arities: [1]},
      %{name: :regexp_extract, arities: [2, 3, 4]},
      %{name: :regexp_extract_all, arities: [2, 3, 4]},
      %{name: :regexp_full_match, arities: [2, 3]},
      %{name: :regexp_matches, arities: [2, 3]},
      %{name: :regexp_replace, arities: [3, 4]},
      %{name: :regexp_split_to_array, arities: [2, 3]}
    ]

    @doc false
    def __regex_helpers__, do: @regex_helpers

    defmacro regexp_escape(string) do
      regex_fragment("regexp_escape", [string])
    end

    defmacro regexp_extract(string, pattern) do
      regex_fragment("regexp_extract", [string], pattern, [])
    end

    defmacro regexp_extract(string, pattern, group_or_names) do
      regex_fragment("regexp_extract", [string], pattern, [group_or_names])
    end

    defmacro regexp_extract(string, pattern, group_or_names, options) do
      regex_fragment("regexp_extract", [string], pattern, [group_or_names, options], true)
    end

    defmacro regexp_extract_all(string, pattern) do
      regex_fragment("regexp_extract_all", [string], pattern, [])
    end

    defmacro regexp_extract_all(string, pattern, group_or_names) do
      regex_fragment("regexp_extract_all", [string], pattern, [group_or_names])
    end

    defmacro regexp_extract_all(string, pattern, group_or_names, options) do
      regex_fragment("regexp_extract_all", [string], pattern, [group_or_names, options], true)
    end

    defmacro regexp_full_match(string, pattern) do
      regex_fragment("regexp_full_match", [string], pattern, [])
    end

    defmacro regexp_full_match(string, pattern, options) do
      regex_fragment("regexp_full_match", [string], pattern, [options], true)
    end

    defmacro regexp_matches(string, pattern) do
      regex_fragment("regexp_matches", [string], pattern, [])
    end

    defmacro regexp_matches(string, pattern, options) do
      regex_fragment("regexp_matches", [string], pattern, [options], true)
    end

    defmacro regexp_replace(string, pattern, replacement) do
      regex_fragment("regexp_replace", [string], pattern, [replacement])
    end

    defmacro regexp_replace(string, pattern, replacement, options) do
      regex_fragment("regexp_replace", [string], pattern, [replacement, options], true)
    end

    defmacro regexp_split_to_array(string, pattern) do
      regex_fragment("regexp_split_to_array", [string], pattern, [])
    end

    defmacro regexp_split_to_array(string, pattern, options) do
      regex_fragment("regexp_split_to_array", [string], pattern, [options], true)
    end

    defp regex_fragment(function, arguments) do
      quote do
        fragment(unquote(call_sql(function, length(arguments))), unquote_splicing(arguments))
      end
    end

    defp regex_fragment(
           function,
           leading_arguments,
           pattern,
           trailing_arguments,
           explicit_options? \\ false
         ) do
      {pattern, pattern_options} = regex_pattern(pattern)
      arguments = leading_arguments ++ [pattern] ++ trailing_arguments

      arguments =
        if pattern_options == nil or explicit_options? do
          arguments
        else
          [pattern_options | Enum.reverse(arguments)] |> Enum.reverse()
        end

      regex_fragment(function, arguments)
    end

    defp regex_pattern({:sigil_r, _meta, [{:<<>>, _string_meta, [source]}, modifiers]})
         when is_binary(source) and is_list(modifiers) do
      options = duckdb_regex_options!(modifiers)
      {source, options}
    end

    defp regex_pattern(
           {:%, _meta,
            [
              {:__aliases__, _alias_meta, [:Regex]},
              {:%{}, _map_meta, fields}
            ]}
         )
         when is_list(fields) do
      source = Keyword.fetch!(fields, :source)
      options = fields |> Keyword.get(:opts, "") |> to_charlist() |> duckdb_regex_options!()
      {source, options}
    end

    defp regex_pattern(pattern), do: {pattern, nil}

    defp duckdb_regex_options!(modifiers) do
      modifiers
      |> Enum.reduce([], fn
        ?i, options ->
          [?i | options]

        ?m, options ->
          [?m | options]

        ?s, options ->
          [?s | options]

        ?u, options ->
          options

        modifier, _options ->
          raise ArgumentError, "unsupported DuckDB regex modifier: #{<<modifier>>}"
      end)
      |> Enum.reverse()
      |> case do
        [] -> nil
        options -> to_string(options)
      end
    end

    defp call_sql(function, arity) do
      [function, "(", Enum.map_join(1..arity, ", ", fn _ -> "?" end), ")"]
      |> IO.iodata_to_binary()
    end
  end
end
