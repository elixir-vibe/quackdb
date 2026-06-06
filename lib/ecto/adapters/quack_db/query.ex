if Code.ensure_loaded?(Ecto.Query) do
  defmodule Ecto.Adapters.QuackDB.Query do
    @moduledoc """
    Read-oriented Ecto query SQL generation for QuackDB.

    This module turns supported `Ecto.Query` ASTs into DuckDB SQL iodata.
    Unsupported analytical shapes raise explicit `QuackDB.Error` values so the
    adapter does not emit misleading SQL.
    """

    @spec all(Ecto.Query.t()) :: iodata()
    def all(%Ecto.Query{} = query) do
      all(query, root_context(query))
    end

    @spec all_literal(Ecto.Query.t()) :: iodata()
    def all_literal(%Ecto.Query{} = query) do
      all(query, %{root_context(query) | literal_tagged?: true})
    end

    defp all(%Ecto.Query{} = query, context) do
      assert_read_only_query!(query)

      [
        with_ctes(query.with_ctes),
        select(query.select, query.distinct, query, context),
        " FROM ",
        source(query.from, 0, context),
        joins(query.joins, context),
        wheres(query.wheres, context),
        group_bys(query.group_bys, context),
        havings(query.havings, context),
        windows(query.windows, context),
        order_bys(query.order_bys, context),
        limit(query.limit, context),
        offset(query.offset, context),
        combinations(query.combinations),
        lock(query.lock)
      ]
    end

    @spec update_all(Ecto.Query.t()) :: iodata()
    def update_all(%Ecto.Query{} = query) do
      assert_mutation_query!(query)

      [
        with_ctes(query.with_ctes),
        "UPDATE ",
        source(query.from, 0),
        " SET ",
        updates(query.updates),
        update_from(query.joins),
        mutation_wheres(query),
        mutation_rowid_filter(query)
      ]
    end

    @spec delete_all(Ecto.Query.t()) :: iodata()
    def delete_all(%Ecto.Query{} = query) do
      assert_mutation_query!(query)

      [
        with_ctes(query.with_ctes),
        "DELETE FROM ",
        source(query.from, 0),
        delete_using(query.joins),
        mutation_wheres(query),
        mutation_rowid_filter(query)
      ]
    end

    defp assert_read_only_query!(%Ecto.Query{}), do: :ok

    defp assert_mutation_query!(%Ecto.Query{} = query) do
      cond do
        query.windows != [] ->
          unsupported!(
            :mutation_query,
            "windowed Ecto update_all/delete_all is unsupported; use Repo.query/3"
          )

        query.combinations != [] ->
          unsupported!(
            :combinations,
            "Ecto combinations are unsupported for update_all/delete_all; use Repo.query/3"
          )

        true ->
          :ok
      end
    end

    defp with_ctes(nil), do: []

    defp with_ctes(%Ecto.Query.WithExpr{queries: queries, recursive: recursive}) do
      ctes =
        Enum.map(queries, fn
          {name, %{operation: :all}, %Ecto.Query{} = query} ->
            [quote_name(name), " AS (", all(query), ")"]

          {name, operation, %Ecto.Query{}} ->
            unsupported!(
              :cte,
              "unsupported Ecto CTE operation for #{name}: #{inspect(operation)}"
            )
        end)

      ["WITH ", recursive(recursive), Enum.intersperse(ctes, ", "), " "]
    end

    defp recursive(true), do: "RECURSIVE "
    defp recursive(false), do: []

    defp select(nil, distinct, _query, _context), do: ["SELECT ", distinct(distinct), "*"]

    defp select(
           %Ecto.Query.SelectExpr{expr: {:&, _meta, [binding]}, take: take},
           distinct,
           query,
           context
         )
         when is_integer(binding) do
      [
        "SELECT ",
        distinct(distinct),
        source_fields(query, binding, Map.get(take, binding), context)
      ]
    end

    defp select(%Ecto.Query.SelectExpr{expr: expr, fields: fields}, distinct, query, context)
         when is_list(fields) and fields != [] do
      if contains_full_source?(expr) do
        expressions =
          fields |> Enum.map(&select_value_expr(&1, query, context)) |> Enum.intersperse(", ")

        ["SELECT ", distinct(distinct), expressions]
      else
        ["SELECT ", distinct(distinct), select_expr(expr, query, context)]
      end
    end

    defp select(%Ecto.Query.SelectExpr{expr: expr}, distinct, query, context) do
      ["SELECT ", distinct(distinct), select_expr(expr, query, context)]
    end

    defp distinct(nil), do: []
    defp distinct(%{expr: true}), do: "DISTINCT "

    defp distinct(%{expr: expressions}) when is_list(expressions) do
      expressions =
        expressions
        |> Enum.map(fn {_direction, expression} -> expr(expression) end)
        |> Enum.intersperse(", ")

      ["DISTINCT ON (", expressions, ") "]
    end

    defp distinct(%{expr: expression}), do: ["DISTINCT ON (", expr(expression), ") "]

    defp source_fields(query, binding, nil, context),
      do: schema_fields(binding_source(query, binding), binding, context)

    defp source_fields(_query, binding, {_shape, fields}, context),
      do: selected_fields(binding, fields, context)

    defp selected_fields(binding, fields, context) do
      fields
      |> Enum.map(fn field -> [binding_alias(binding, context), ".", quote_name(field)] end)
      |> Enum.intersperse(", ")
    end

    defp schema_fields(%{source: {_table, schema}}, binding, context) when is_atom(schema) do
      schema
      |> schema_select_fields(binding, context)
      |> Enum.intersperse(", ")
    end

    defp schema_fields(%{source: %Ecto.SubQuery{} = subquery}, binding, context) do
      case subquery_select_fields(subquery) do
        fields when is_list(fields) ->
          fields
          |> Enum.map(fn field ->
            [binding_alias(binding, context), ".", quote_name(field)]
          end)
          |> Enum.intersperse(", ")

        _other ->
          unsupported!(:select, "full-source Ecto selects require a schema-backed source")
      end
    end

    defp schema_fields(_from, _binding, _context),
      do: unsupported!(:select, "full-source Ecto selects require a schema-backed source")

    defp schema_select_fields(schema, binding, context) do
      schema.__schema__(:fields)
      |> Enum.map(fn field ->
        source = schema.__schema__(:field_source, field)
        field = schema_field(schema, field, binding, source, context)

        if field.alias? do
          [field.expression, " AS ", quote_name(field.name)]
        else
          field.expression
        end
      end)
    end

    defp subquery_select_fields(%Ecto.SubQuery{
           select: {:source, {_table, _schema}, _select, fields}
         })
         when is_list(fields),
         do: Keyword.keys(fields)

    defp subquery_select_fields(%Ecto.SubQuery{query: %{from: %{source: {_table, schema}}}})
         when is_atom(schema) and not is_nil(schema),
         do: schema.__schema__(:fields)

    defp subquery_select_fields(_subquery), do: nil

    defp schema_field(schema, field, binding, source, context) do
      expression = [binding_alias(binding, context), ".", quote_name(source)]

      case schema.__schema__(:type, field) do
        :binary_id ->
          %{
            name: field,
            expression: ["from_hex(replace(CAST(", expression, " AS VARCHAR), '-', ''))"],
            alias?: true
          }

        _type ->
          %{name: field, expression: expression, alias?: source != field}
      end
    end

    defp select_expr({:%{}, _meta, fields}, from, context) do
      fields
      |> Enum.map(fn
        {_alias_name, {:selected_as, _meta, [expression, name]}} ->
          [select_value_expr(expression, from, context), " AS ", quote_name(name)]

        {alias_name, expression} ->
          [select_value_expr(expression, from, context), " AS ", quote_name(alias_name)]
      end)
      |> Enum.intersperse(", ")
    end

    defp select_expr({:{}, _meta, fields}, from, context) do
      fields |> Enum.map(&select_value_expr(&1, from, context)) |> Enum.intersperse(", ")
    end

    defp select_expr(fields, from, context) when is_list(fields) do
      fields |> Enum.map(&select_value_expr(&1, from, context)) |> Enum.intersperse(", ")
    end

    defp select_expr(expression, from, context), do: select_value_expr(expression, from, context)

    defp select_value_expr({:%{}, meta, fields}, from, context) do
      select_expr({:%{}, meta, fields}, from, context)
    end

    defp select_value_expr({:{}, meta, fields}, from, context) do
      select_expr({:{}, meta, fields}, from, context)
    end

    defp select_value_expr({:&, _meta, [binding]}, query, context) when is_integer(binding) do
      source_fields(query, binding, nil, context)
    end

    defp select_value_expr(
           {{:., _, [{:&, _, [binding]}, field]}, _, []} = expression,
           query,
           context
         )
         when is_integer(binding) do
      case binding_source(query, binding) do
        %{source: {_table, schema}} when is_atom(schema) and not is_nil(schema) ->
          case schema_field_for_select(schema, field) do
            nil ->
              expr(expression, context)

            schema_field_name ->
              source = schema.__schema__(:field_source, schema_field_name)
              schema_field(schema, schema_field_name, binding, source, context).expression
          end

        _other ->
          expr(expression, context)
      end
    end

    defp select_value_expr(expression, _from, context), do: expr(expression, context)

    defp schema_field_for_select(schema, field) do
      Enum.find(schema.__schema__(:fields), fn schema_field ->
        schema_field == field or schema.__schema__(:field_source, schema_field) == field
      end)
    end

    defp binding_source(%Ecto.Query{from: from}, 0), do: from

    defp binding_source(%Ecto.Query{joins: joins}, binding) when binding > 0 do
      Enum.at(joins, binding - 1)
    end

    defp source(from, index), do: source(from, index, root_context(%Ecto.Query{}))

    defp source(%{source: {table, nil}}, index, context) when is_binary(table) do
      [source_name(table), " AS ", binding_alias(index, context)]
    end

    defp source(%{source: {table, schema}}, index, context)
         when is_binary(table) and is_atom(schema) do
      [source_name(table), " AS ", binding_alias(index, context)]
    end

    defp source(%{source: %Ecto.SubQuery{query: query}}, index, context) do
      subquery_context = subquery_context(query, context, index)
      ["(", all(query, subquery_context), ") AS ", binding_alias(index, context)]
    end

    defp source(%{source: {:fragment, _meta, parts}}, index, context) do
      [fragment(parts, context), " AS ", binding_alias(index, context)]
    end

    defp source(_from, _index, _context) do
      unsupported!(
        :source,
        "only table, source helper, fragment, and subquery sources are supported in Ecto queries"
      )
    end

    defp root_context(%Ecto.Query{} = query) do
      %{
        prefix: "",
        aliases: query.aliases || %{},
        parent: nil,
        subqueries: [],
        literal_tagged?: false
      }
    end

    defp subquery_context(%Ecto.Query{} = query, parent, index) do
      prefix = if contains_parent_as?(query), do: ["s", to_string(index), "_"], else: ""

      %{
        prefix: prefix,
        aliases: query.aliases || %{},
        parent: parent,
        subqueries: [],
        literal_tagged?: parent.literal_tagged?
      }
    end

    defp context_with_subqueries(context, %{subqueries: subqueries}) when is_list(subqueries),
      do: %{context | subqueries: subqueries}

    defp context_with_subqueries(context, _expr), do: context

    defp binding_alias(binding, context), do: [context.prefix, "q", to_string(binding)]

    defp parent_binding_alias(alias, %{parent: nil}) do
      unsupported!(:expression, "unknown Ecto parent_as binding: #{inspect(alias)}")
    end

    defp parent_binding_alias(alias, %{parent: parent}) do
      case Map.fetch(parent.aliases, alias) do
        {:ok, binding} when is_integer(binding) ->
          binding_alias(binding, parent)

        :error ->
          parent_binding_alias(alias, parent)
      end
    end

    defp contains_full_source?({:&, _meta, [binding]}) when is_integer(binding), do: true

    defp contains_full_source?(
           {{:., _meta, [{:&, _binding_meta, [_binding]}, _field]}, _call_meta, []}
         ),
         do: false

    defp contains_full_source?(tuple) when is_tuple(tuple),
      do: tuple |> Tuple.to_list() |> contains_full_source?()

    defp contains_full_source?(list) when is_list(list),
      do: Enum.any?(list, &contains_full_source?/1)

    defp contains_full_source?(_other), do: false

    defp contains_parent_as?({:parent_as, _meta, [_alias]}), do: true

    defp contains_parent_as?(tuple) when is_tuple(tuple) do
      tuple |> Tuple.to_list() |> contains_parent_as?()
    end

    defp contains_parent_as?(list) when is_list(list), do: Enum.any?(list, &contains_parent_as?/1)

    defp contains_parent_as?(%_struct{} = struct) do
      struct |> Map.from_struct() |> contains_parent_as?()
    end

    defp contains_parent_as?(map) when is_map(map),
      do: map |> Map.values() |> contains_parent_as?()

    defp contains_parent_as?(_other), do: false

    defp source_name(table) do
      if QuackDB.Source.source?(table) do
        table
      else
        quote_name(table)
      end
    end

    defp update_from([]), do: []

    defp update_from(joins) do
      [
        " FROM ",
        joins
        |> Enum.with_index(1)
        |> Enum.map(fn {join, index} -> source(join, index) end)
        |> Enum.intersperse(", ")
      ]
    end

    defp delete_using([]), do: []

    defp delete_using(joins) do
      [
        " USING ",
        joins
        |> Enum.with_index(1)
        |> Enum.map(fn {join, index} -> source(join, index) end)
        |> Enum.intersperse(", ")
      ]
    end

    defp joins(joins), do: joins(joins, root_context(%Ecto.Query{}))

    defp joins(joins, context) do
      joins
      |> Enum.with_index(1)
      |> Enum.map(fn {join, index} ->
        [
          " ",
          join_qualifier(join.qual),
          " ",
          source(join, index, context),
          " ON ",
          expr(join.on.expr, context)
        ]
      end)
    end

    defp join_qualifier(:inner), do: "INNER JOIN"
    defp join_qualifier(:left), do: "LEFT OUTER JOIN"
    defp join_qualifier(:right), do: "RIGHT OUTER JOIN"
    defp join_qualifier(:full), do: "FULL OUTER JOIN"
    defp join_qualifier(:cross), do: "CROSS JOIN"
    defp join_qualifier(:inner_lateral), do: "INNER JOIN LATERAL"
    defp join_qualifier(:left_lateral), do: "LEFT OUTER JOIN LATERAL"

    defp join_qualifier(qualifier) do
      unsupported!(:join, "unsupported Ecto join qualifier: #{inspect(qualifier)}")
    end

    defp updates([]),
      do: unsupported!(:schema_updates, "Ecto update_all requires update expressions")

    defp updates(updates) do
      updates
      |> Enum.flat_map(&update_expr/1)
      |> Enum.intersperse(", ")
    end

    defp update_expr(%Ecto.Query.QueryExpr{expr: expressions}) do
      Enum.flat_map(expressions, fn
        {:set, fields} ->
          Enum.map(fields, fn {field, expression} ->
            [quote_name(field), " = ", expr(expression)]
          end)

        {:inc, fields} ->
          Enum.map(fields, fn {field, expression} ->
            quoted = quote_name(field)
            [quoted, " = ", quoted, " + ", expr(expression)]
          end)

        {operation, _fields} ->
          unsupported!(
            :schema_updates,
            "Ecto update operation #{inspect(operation)} is unsupported"
          )
      end)
    end

    defp mutation_wheres(%Ecto.Query{} = query) do
      predicates = Enum.map(query.joins, & &1.on.expr) ++ Enum.map(query.wheres, & &1.expr)

      case predicates do
        [] -> []
        expressions -> [" WHERE ", expressions |> Enum.map(&expr/1) |> Enum.intersperse(" AND ")]
      end
    end

    defp mutation_rowid_filter(%Ecto.Query{
           order_bys: [],
           limit: nil,
           offset: nil,
           group_bys: [],
           havings: []
         }),
         do: []

    defp mutation_rowid_filter(%Ecto.Query{} = query) do
      [
        if(query.wheres == [] and query.joins == [], do: " WHERE ", else: " AND "),
        "q0.rowid IN (",
        mutation_rowid_subquery(query),
        ")"
      ]
    end

    defp mutation_rowid_subquery(%Ecto.Query{group_bys: [], havings: []} = query) do
      [
        "SELECT q0.rowid FROM ",
        source(query.from, 0),
        joins(query.joins),
        wheres(query.wheres),
        order_bys(query.order_bys),
        limit(query.limit),
        offset(query.offset)
      ]
    end

    defp mutation_rowid_subquery(%Ecto.Query{} = query) do
      [
        "SELECT rowid FROM (SELECT q0.rowid AS rowid FROM ",
        source(query.from, 0),
        joins(query.joins),
        wheres(query.wheres),
        group_bys(query.group_bys),
        havings(query.havings),
        ") AS quackdb_mutation_rows"
      ]
    end

    defp wheres(wheres), do: wheres(wheres, root_context(%Ecto.Query{}))
    defp wheres([], _context), do: []

    defp wheres(wheres, context) do
      expressions =
        Enum.map(wheres, fn %{expr: expression} = where ->
          expr(expression, context_with_subqueries(context, where))
        end)

      [" WHERE ", Enum.intersperse(expressions, " AND ")]
    end

    defp group_bys(group_bys), do: group_bys(group_bys, root_context(%Ecto.Query{}))
    defp group_bys([], _context), do: []

    defp group_bys(group_bys, context) do
      expressions =
        group_bys
        |> Enum.flat_map(& &1.expr)
        |> Enum.map(&expr(&1, context))

      [" GROUP BY ", Enum.intersperse(expressions, ", ")]
    end

    defp havings(havings), do: havings(havings, root_context(%Ecto.Query{}))
    defp havings([], _context), do: []

    defp havings(havings, context) do
      expressions =
        Enum.map(havings, fn %{expr: expression} = having ->
          expr(expression, context_with_subqueries(context, having))
        end)

      [" HAVING ", Enum.intersperse(expressions, " AND ")]
    end

    defp windows([], _context), do: []

    defp windows(windows, context) do
      definitions =
        Enum.map(windows, fn {name, window} ->
          [quote_name(name), " AS (", window_expr(window.expr, context), ")"]
        end)

      [" WINDOW ", Enum.intersperse(definitions, ", ")]
    end

    defp window_expr(parts), do: window_expr(parts, root_context(%Ecto.Query{}))

    defp window_expr(parts, context) do
      parts
      |> Enum.map(fn
        {:partition_by, expressions} ->
          ["PARTITION BY ", expressions |> Enum.map(&expr(&1, context)) |> Enum.intersperse(", ")]

        {:order_by, expressions} ->
          ["ORDER BY ", order_by_exprs(expressions, context)]

        {:frame, expression} ->
          expr(expression, context)
      end)
      |> Enum.intersperse(" ")
    end

    defp order_bys(order_bys), do: order_bys(order_bys, root_context(%Ecto.Query{}))
    defp order_bys([], _context), do: []

    defp order_bys(order_bys, context) do
      expressions = order_bys |> Enum.flat_map(& &1.expr) |> order_by_exprs(context)
      [" ORDER BY ", expressions]
    end

    defp order_by_exprs(expressions, context) do
      expressions
      |> Enum.map(fn {direction, expression} ->
        [expr(expression, context), " ", order_direction(direction)]
      end)
      |> Enum.intersperse(", ")
    end

    defp limit(limit), do: limit(limit, root_context(%Ecto.Query{}))
    defp limit(nil, _context), do: []
    defp limit(%{expr: expression}, context), do: [" LIMIT ", expr(expression, context)]

    defp offset(offset), do: offset(offset, root_context(%Ecto.Query{}))
    defp offset(nil, _context), do: []
    defp offset(%{expr: expression}, context), do: [" OFFSET ", expr(expression, context)]

    defp combinations([]), do: []

    defp combinations(combinations) do
      Enum.map(combinations, fn {operation, query} ->
        [" ", combination_operator(operation), " ", all(query)]
      end)
    end

    defp combination_operator(:union), do: "UNION"
    defp combination_operator(:union_all), do: "UNION ALL"
    defp combination_operator(:except), do: "EXCEPT"
    defp combination_operator(:except_all), do: "EXCEPT ALL"
    defp combination_operator(:intersect), do: "INTERSECT"
    defp combination_operator(:intersect_all), do: "INTERSECT ALL"

    defp lock(nil), do: []
    defp lock(lock) when is_binary(lock), do: [" ", lock]

    defp expr({{:., _meta, [{:&, _binding_meta, [binding]}, field]}, _call_meta, []}, context)
         when is_integer(binding) and is_atom(field) do
      [binding_alias(binding, context), ".", quote_name(field)]
    end

    defp expr(
           {{:., _meta, [{:parent_as, _parent_meta, [alias]}, field]}, _call_meta, []},
           context
         )
         when is_atom(alias) and is_atom(field) do
      [parent_binding_alias(alias, context), ".", quote_name(field)]
    end

    defp expr({op, _meta, [left, right]}, context) when op in [:==, :!=, :>, :<, :>=, :<=] do
      ["(", expr(left, context), " ", operator(op), " ", expr(right, context), ")"]
    end

    defp expr({op, _meta, [left, right]}, context) when op in [:and, :or] do
      [
        "(",
        expr(left, context),
        " ",
        op |> Atom.to_string() |> String.upcase(),
        " ",
        expr(right, context),
        ")"
      ]
    end

    defp expr({:not, _meta, [{:is_nil, _is_nil_meta, [expression]}]}, context) do
      ["(", expr(expression, context), " IS NOT NULL)"]
    end

    defp expr({:not, _meta, [expression]}, context), do: ["(NOT ", expr(expression, context), ")"]

    defp expr({:is_nil, _meta, [expression]}, context),
      do: ["(", expr(expression, context), " IS NULL)"]

    defp expr({:fragment, _meta, parts}, context), do: fragment(parts, context)
    defp expr({:in, _meta, [left, right]}, context), do: in_expr(left, right, context)
    defp expr({:subquery, index}, context), do: subquery_expr(index, context)

    defp expr({:type, _meta, [expression, type]}, context) do
      ["CAST(", expr(expression, context), " AS ", ecto_cast_type!(type), ")"]
    end

    defp expr({:^, _meta, [_index]}, _context), do: "?"
    defp expr({:^, _meta, [_index, _count]}, _context), do: "?"

    defp expr(%Ecto.Query.Tagged{value: value, type: type}, context),
      do: typed_expr(value, type, context)

    defp expr(other, _context), do: expr(other)

    defp expr({{:., _meta, [{:&, _binding_meta, [binding]}, field]}, _call_meta, []})
         when is_integer(binding) and is_atom(field) do
      ["q", to_string(binding), ".", quote_name(field)]
    end

    defp expr({aggregate, _meta, [expression]})
         when aggregate in [:count, :avg, :sum, :min, :max] do
      [aggregate |> Atom.to_string() |> String.upcase(), "(", expr(expression), ")"]
    end

    defp expr({:count, _meta, [expression, :distinct]}) do
      ["COUNT(DISTINCT ", expr(expression), ")"]
    end

    defp expr({:count, _meta, []}), do: "COUNT(*)"

    defp expr({:coalesce, _meta, [left, right]}) do
      ["coalesce(", expr(left), ", ", expr(right), ")"]
    end

    defp expr({window_function, _meta, []})
         when window_function in [:row_number, :rank, :dense_rank, :percent_rank, :cume_dist] do
      [window_function |> Atom.to_string() |> String.upcase(), "()"]
    end

    defp expr({window_function, _meta, [expression]})
         when window_function in [:lag, :lead, :first_value, :last_value] do
      [window_function |> Atom.to_string(), "(", expr(expression), ")"]
    end

    defp expr({window_function, _meta, [expression, offset]})
         when window_function in [:lag, :lead] do
      [window_function |> Atom.to_string(), "(", expr(expression), ", ", expr(offset), ")"]
    end

    defp expr({window_function, _meta, [expression, offset, default]})
         when window_function in [:lag, :lead] do
      [
        window_function |> Atom.to_string(),
        "(",
        expr(expression),
        ", ",
        expr(offset),
        ", ",
        expr(default),
        ")"
      ]
    end

    defp expr({:nth_value, _meta, [expression, nth]}) do
      ["nth_value(", expr(expression), ", ", expr(nth), ")"]
    end

    defp expr({:over, _meta, [expression, window]}) do
      [expr(expression), " OVER ", over_expr(window)]
    end

    defp expr({:filter, _meta, [aggregate, predicate]}) do
      [expr(aggregate), " FILTER (WHERE ", expr(predicate), ")"]
    end

    defp expr({:json_extract_path, _meta, [expression, path]}) when is_list(path) do
      ["json_extract_string(", expr(expression), ", ", literal(json_path!(path)), ")"]
    end

    defp expr({:fragment, _meta, parts}), do: fragment(parts)

    defp expr({:selected_as, _meta, [name]}) when is_atom(name), do: quote_name(name)

    defp expr({:selected_as, _meta, [expression, name]}) when is_atom(name),
      do: [expr(expression), " AS ", quote_name(name)]

    defp expr({:type, _meta, [expression, type]}) do
      ["CAST(", expr(expression), " AS ", ecto_cast_type!(type), ")"]
    end

    defp expr({op, _meta, [left, right]}) when op in [:==, :!=, :>, :<, :>=, :<=] do
      ["(", expr(left), " ", operator(op), " ", expr(right), ")"]
    end

    defp expr({op, _meta, [left, right]}) when op in [:and, :or] do
      ["(", expr(left), " ", op |> Atom.to_string() |> String.upcase(), " ", expr(right), ")"]
    end

    defp expr({op, _meta, [left, right]}) when op in [:+, :-, :*, :/] do
      ["(", expr(left), " ", operator(op), " ", expr(right), ")"]
    end

    defp expr({:in, _meta, [left, right]}) do
      in_expr(left, right)
    end

    defp expr({:not, _meta, [{:is_nil, _is_nil_meta, [expression]}]}) do
      ["(", expr(expression), " IS NOT NULL)"]
    end

    defp expr({:not, _meta, [expression]}) do
      ["(NOT ", expr(expression), ")"]
    end

    defp expr({:like, _meta, [left, right]}) do
      ["(", expr(left), " LIKE ", expr(right), ")"]
    end

    defp expr({:ilike, _meta, [left, right]}) do
      ["(", expr(left), " ILIKE ", expr(right), ")"]
    end

    defp expr({:is_nil, _meta, [expression]}) do
      ["(", expr(expression), " IS NULL)"]
    end

    defp expr({:identifier, _meta, [value]}) when is_binary(value), do: quote_name(value)
    defp expr({:^, _meta, [_index]}), do: "?"
    defp expr({:^, _meta, [_index, _count]}), do: "?"

    defp expr(%Ecto.Query.Tagged{value: value, type: type}),
      do: typed_expr(value, type, root_context(%Ecto.Query{}))

    defp expr(value) when is_binary(value), do: literal(value)
    defp expr(value) when is_integer(value) or is_float(value), do: to_string(value)
    defp expr(value) when is_boolean(value), do: if(value, do: "TRUE", else: "FALSE")
    defp expr(nil), do: "NULL"

    defp expr(other) do
      unsupported!(:expression, "unsupported Ecto query expression: #{inspect(other)}")
    end

    defp over_expr(window) when is_atom(window), do: quote_name(window)
    defp over_expr(window) when is_list(window), do: ["(", window_expr(window), ")"]

    defp fragment(parts), do: fragment(parts, root_context(%Ecto.Query{}))

    defp fragment(parts, context) do
      Enum.map(parts, fn
        {:raw, value} -> value
        {:expr, expression} -> expr(expression, context)
      end)
    end

    defp json_path!(path) do
      ["$", Enum.map(path, &json_path_segment!/1)]
      |> IO.iodata_to_binary()
    end

    defp json_path_segment!(segment) when is_atom(segment),
      do: json_path_segment!(Atom.to_string(segment))

    defp json_path_segment!(segment) when is_binary(segment) do
      if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, segment) do
        [".", segment]
      else
        ["[", QuackDB.SQL.literal!(segment), "]"]
      end
    end

    defp json_path_segment!(segment) when is_integer(segment) and segment >= 0 do
      ["[", Integer.to_string(segment), "]"]
    end

    defp json_path_segment!(segment) do
      unsupported!(:expression, "unsupported JSON path segment: #{inspect(segment)}")
    end

    defp in_expr(left, expression), do: in_expr(left, expression, root_context(%Ecto.Query{}))

    defp in_expr(left, %Ecto.Query.Tagged{value: values}, context) when is_list(values),
      do: in_expr(left, values, context)

    defp in_expr(left, {:^, _meta, [_index, count]}, context)
         when is_integer(count) and count > 0 do
      [
        "(",
        expr(left, context),
        " IN (",
        1..count |> Enum.map(fn _ -> "?" end) |> Enum.intersperse(", "),
        "))"
      ]
    end

    defp in_expr(left, values, context) when is_list(values) do
      [
        "(",
        expr(left, context),
        " IN (",
        values |> Enum.map(&expr(&1, context)) |> Enum.intersperse(", "),
        "))"
      ]
    end

    defp in_expr(left, expression, context),
      do: ["(", expr(left, context), " IN ", expr(expression, context), ")"]

    defp subquery_expr(index, %{subqueries: subqueries} = context) when is_integer(index) do
      case Enum.at(subqueries, index) do
        %Ecto.SubQuery{query: %Ecto.Query{} = query} ->
          ["(", all(query, subquery_context(query, context, index)), ")"]

        _other ->
          unsupported!(:expression, "unknown Ecto subquery reference: #{inspect(index)}")
      end
    end

    defp typed_expr(value, {source_index, field}, %{literal_tagged?: true})
         when is_integer(source_index) and is_atom(field),
         do: literal(value)

    defp typed_expr(_value, {source_index, field}, _context)
         when is_integer(source_index) and is_atom(field),
         do: "?"

    defp typed_expr(
           {{:., _meta, [{:&, _binding_meta, [_binding]}, _field]}, _call_meta, []} = value,
           type,
           context
         ),
         do: ["CAST(", expr(value, context), " AS ", ecto_cast_type!(type), ")"]

    defp typed_expr({:^, _meta, [_index]} = value, type, context),
      do: ["CAST(", expr(value, context), " AS ", ecto_cast_type!(type), ")"]

    defp typed_expr({:^, _meta, [_index, _count]} = value, type, context),
      do: ["CAST(", expr(value, context), " AS ", ecto_cast_type!(type), ")"]

    defp typed_expr(value, type, context) when is_tuple(value),
      do: ["CAST(", expr(value, context), " AS ", ecto_cast_type!(type), ")"]

    defp typed_expr(_value, type, _context), do: ["CAST(? AS ", ecto_cast_type!(type), ")"]

    defp literal(value) when is_binary(value), do: ["'", String.replace(value, "'", "''"), "'"]
    defp literal(%Date{} = value), do: ["DATE '", Date.to_iso8601(value), "'"]

    defp literal(%NaiveDateTime{} = value),
      do: ["TIMESTAMP '", NaiveDateTime.to_iso8601(value), "'"]

    defp literal(%DateTime{} = value), do: ["TIMESTAMPTZ '", DateTime.to_iso8601(value), "'"]
    defp literal(%Decimal{} = value), do: Decimal.to_string(value)
    defp literal(value), do: expr(value)

    defp operator(:==), do: "="
    defp operator(:!=), do: "<>"
    defp operator(op), do: Atom.to_string(op)

    defp ecto_cast_type!(:id), do: QuackDB.Type.to_sql(:bigint)
    defp ecto_cast_type!(:binary_id), do: QuackDB.Type.to_sql(:uuid)
    defp ecto_cast_type!(:integer), do: QuackDB.Type.to_sql(:integer)
    defp ecto_cast_type!(:float), do: QuackDB.Type.to_sql(:double)
    defp ecto_cast_type!(:boolean), do: QuackDB.Type.to_sql(:boolean)
    defp ecto_cast_type!(:string), do: QuackDB.Type.to_sql(:varchar)
    defp ecto_cast_type!(:binary), do: QuackDB.Type.to_sql(:blob)
    defp ecto_cast_type!(:decimal), do: QuackDB.Type.to_sql(:decimal)
    defp ecto_cast_type!(:date), do: QuackDB.Type.to_sql(:date)
    defp ecto_cast_type!(:time), do: QuackDB.Type.to_sql(:time)
    defp ecto_cast_type!(:time_usec), do: QuackDB.Type.to_sql(:time)
    defp ecto_cast_type!(:naive_datetime), do: QuackDB.Type.to_sql(:timestamp)
    defp ecto_cast_type!(:naive_datetime_usec), do: QuackDB.Type.to_sql(:timestamp)
    defp ecto_cast_type!(:utc_datetime), do: QuackDB.Type.to_sql(:timestamptz)
    defp ecto_cast_type!(:utc_datetime_usec), do: QuackDB.Type.to_sql(:timestamptz)
    defp ecto_cast_type!(:map), do: QuackDB.Type.to_sql(:json)

    defp ecto_cast_type!({:array, type}),
      do: QuackDB.Type.to_sql({:list, ecto_cast_type_spec!(type)})

    defp ecto_cast_type!(type) do
      unsupported!(:expression, "unsupported Ecto cast type: #{inspect(type)}")
    end

    defp ecto_cast_type_spec!(:id), do: :bigint
    defp ecto_cast_type_spec!(:binary_id), do: :uuid
    defp ecto_cast_type_spec!(:integer), do: :integer
    defp ecto_cast_type_spec!(:float), do: :double
    defp ecto_cast_type_spec!(:boolean), do: :boolean
    defp ecto_cast_type_spec!(:string), do: :varchar
    defp ecto_cast_type_spec!(:binary), do: :blob
    defp ecto_cast_type_spec!(:decimal), do: :decimal
    defp ecto_cast_type_spec!(:date), do: :date
    defp ecto_cast_type_spec!(:time), do: :time
    defp ecto_cast_type_spec!(:time_usec), do: :time
    defp ecto_cast_type_spec!(:naive_datetime), do: :timestamp
    defp ecto_cast_type_spec!(:naive_datetime_usec), do: :timestamp
    defp ecto_cast_type_spec!(:utc_datetime), do: :timestamptz
    defp ecto_cast_type_spec!(:utc_datetime_usec), do: :timestamptz
    defp ecto_cast_type_spec!(:map), do: :json
    defp ecto_cast_type_spec!({:array, type}), do: {:list, ecto_cast_type_spec!(type)}

    defp ecto_cast_type_spec!(type),
      do: unsupported!(:expression, "unsupported Ecto cast type: #{inspect(type)}")

    defp order_direction(:asc), do: "ASC"
    defp order_direction(:desc), do: "DESC"
    defp order_direction(:asc_nulls_last), do: "ASC NULLS LAST"
    defp order_direction(:asc_nulls_first), do: "ASC NULLS FIRST"
    defp order_direction(:desc_nulls_last), do: "DESC NULLS LAST"
    defp order_direction(:desc_nulls_first), do: "DESC NULLS FIRST"

    defp quote_name(name) when is_atom(name), do: name |> Atom.to_string() |> quote_name()

    defp quote_name(name) when is_binary(name) do
      if String.contains?(name, "\"") do
        raise ArgumentError, "bad literal/field/table name #{inspect(name)} (\" is not permitted)"
      end

      [?\", name, ?\"]
    end

    defp unsupported!(feature, message) do
      raise QuackDB.Error.new(:ecto_feature_not_supported, message,
              source: :client,
              metadata: %{feature: feature}
            )
    end
  end
end
