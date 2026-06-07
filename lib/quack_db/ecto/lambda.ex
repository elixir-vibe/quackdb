if Code.ensure_loaded?(Ecto.Query.API) do
  defmodule QuackDB.Ecto.Lambda do
    @moduledoc false

    @binary_operators %{
      +: "+",
      -: "-",
      *: "*",
      /: "/",
      ==: "=",
      !=: "!=",
      >: ">",
      <: "<",
      >=: ">=",
      <=: "<=",
      and: "AND",
      or: "OR"
    }

    @supported_expression_message "Supported expressions are literals, pinned values, lambda variables, arithmetic, comparisons, boolean operators, rem/2, is_nil/1, and case_when/1"

    @type option :: {:function, atom()} | {:arities, [non_neg_integer()]}

    @spec to_sql!(Macro.t(), [option()]) :: {String.t(), [Macro.t()]}
    def to_sql!(lambda_ast, options) do
      function = Keyword.fetch!(options, :function)
      arities = Keyword.fetch!(options, :arities)

      case lambda_ast do
        {:fn, _meta, [{:->, _arrow_meta, [args, body]}]} when is_list(args) ->
          validate_arity!(function, args, arities)
          vars = lambda_vars!(function, args)
          var_names = Enum.map(vars, &Atom.to_string/1)
          {body_sql, params} = expr(body, vars, function)

          {["lambda ", Enum.join(var_names, ", "), " : ", body_sql] |> IO.iodata_to_binary(),
           params}

        _other ->
          raise ArgumentError,
                "expected #{function} lambda as `fn x -> expr end`, got: #{Macro.to_string(lambda_ast)}"
      end
    end

    defp validate_arity!(function, args, arities) do
      arity = length(args)

      unless arity in arities do
        expected = arities |> Enum.map_join(" or ", &Integer.to_string/1)

        raise ArgumentError,
              "unsupported #{function} lambda arity #{arity}; expected #{expected} parameters"
      end
    end

    defp lambda_vars!(function, args) do
      Enum.map(args, fn
        {name, _meta, context} when is_atom(name) and is_atom(context) ->
          if QuackDB.Identifier.valid?(name) do
            name
          else
            raise ArgumentError,
                  "invalid DuckDB lambda parameter `#{name}` in #{function}; parameters must be simple variables"
          end

        other ->
          raise ArgumentError,
                "invalid DuckDB lambda parameter in #{function}: #{Macro.to_string(other)}"
      end)
    end

    defp expr({op, _meta, [left, right]}, vars, function)
         when is_map_key(@binary_operators, op) do
      {left_sql, left_params} = expr(left, vars, function)
      {right_sql, right_params} = expr(right, vars, function)

      {["(", left_sql, " ", Map.fetch!(@binary_operators, op), " ", right_sql, ")"],
       left_params ++ right_params}
    end

    defp expr({:-, _meta, [value]}, vars, function) do
      {value_sql, params} = expr(value, vars, function)
      {["(-", value_sql, ")"], params}
    end

    defp expr({:not, _meta, [{:is_nil, _nil_meta, [value]}]}, vars, function) do
      {value_sql, params} = expr(value, vars, function)
      {["(", value_sql, " IS NOT NULL)"], params}
    end

    defp expr({:not, _meta, [value]}, vars, function) do
      {value_sql, params} = expr(value, vars, function)
      {["(NOT ", value_sql, ")"], params}
    end

    defp expr({:is_nil, _meta, [value]}, vars, function) do
      {value_sql, params} = expr(value, vars, function)
      {["(", value_sql, " IS NULL)"], params}
    end

    defp expr({:rem, _meta, [left, right]}, vars, function) do
      {left_sql, left_params} = expr(left, vars, function)
      {right_sql, right_params} = expr(right, vars, function)
      {["(", left_sql, " % ", right_sql, ")"], left_params ++ right_params}
    end

    defp expr({:case_when, _meta, [[do: clauses]]}, vars, function) do
      {when_clauses, else_expression} = QuackDB.Ecto.Conditionals.__split_clauses__!(clauses)

      {when_sql, when_param_groups} =
        Enum.map_reduce(when_clauses, [], fn {condition, expression}, param_groups ->
          {condition_sql, condition_params} = expr(condition, vars, function)
          {expression_sql, expression_params} = expr(expression, vars, function)

          {["WHEN ", condition_sql, " THEN ", expression_sql, " "],
           [expression_params, condition_params | param_groups]}
        end)

      {else_sql, else_params} = expr(else_expression, vars, function)
      when_params = when_param_groups |> Enum.reverse() |> List.flatten()
      {["CASE ", when_sql, "ELSE ", else_sql, " END"], when_params ++ else_params}
    end

    defp expr({:^, _meta, [_value]} = pinned, _vars, _function), do: {"?", [pinned]}

    defp expr({name, _meta, context}, vars, function) when is_atom(name) and is_atom(context) do
      if name in vars do
        {Atom.to_string(name), []}
      else
        raise ArgumentError,
              "unknown DuckDB lambda variable `#{name}` in #{function}; use a lambda parameter or pin external values with ^#{name}"
      end
    end

    defp expr(nil, _vars, _function), do: {"NULL", []}
    defp expr(true, _vars, _function), do: {"TRUE", []}
    defp expr(false, _vars, _function), do: {"FALSE", []}
    defp expr(value, _vars, _function) when is_integer(value), do: {Integer.to_string(value), []}

    defp expr(value, _vars, _function) when is_float(value) do
      {value |> QuackDB.SQL.literal!() |> IO.iodata_to_binary(), []}
    end

    defp expr(value, _vars, _function) when is_binary(value) do
      {value |> QuackDB.SQL.literal!() |> IO.iodata_to_binary(), []}
    end

    defp expr(other, _vars, function) do
      raise ArgumentError,
            "unsupported DuckDB lambda expression in #{function}: #{Macro.to_string(other)}. #{@supported_expression_message}"
    end
  end
end
