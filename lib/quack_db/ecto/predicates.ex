if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.Predicates do
    @moduledoc false

    defmacro contains(left, right) do
      cond do
        text_contains?(left, right, __CALLER__) ->
          quote do
            fragment("contains(?, ?)", unquote(left), unquote(right))
          end

        spatial_contains?(left, right, __CALLER__) ->
          quote do
            fragment("ST_Contains(?, ?)", unquote(left), unquote(right))
          end

        true ->
          raise ArgumentError,
                "ambiguous contains/2; use contains_text/2 for DuckDB string containment " <>
                  "or st_contains/2 for DuckDB Spatial containment"
      end
    end

    defp text_contains?(left, right, caller) do
      not spatial_contains?(left, right, caller) and binary_literal?(right)
    end

    defp spatial_contains?(left, right, caller) do
      expands_to_spatial?(left, caller) or expands_to_spatial?(right, caller)
    end

    defp expands_to_spatial?(expression, caller) do
      expression
      |> Macro.expand_once(caller)
      |> spatial_fragment?()
    end

    defp spatial_fragment?({:fragment, _meta, [sql | _args]}) when is_binary(sql),
      do: String.starts_with?(sql, "ST_")

    defp spatial_fragment?(_expression), do: false

    defp binary_literal?(value) when is_binary(value), do: true
    defp binary_literal?({:^, _meta, [_value]}), do: true
    defp binary_literal?(_value), do: false
  end
end
