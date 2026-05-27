if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.Predicates do
    @moduledoc false

    defmacro contains(left, right) do
      if text_contains?(left, right, __CALLER__) do
        quote do
          fragment("contains(?, ?)", unquote(left), unquote(right))
        end
      else
        quote do
          fragment("ST_Contains(?, ?)", unquote(left), unquote(right))
        end
      end
    end

    defp text_contains?(left, right, caller) do
      not expands_to_spatial?(left, caller) and not expands_to_spatial?(right, caller) and
        binary_literal?(right)
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
