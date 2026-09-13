defmodule QuackDB.DDL.Check do
  @moduledoc """
  An inline CHECK constraint built by `QuackDB.DDL.check/1`.

  Pass one value or a list of values to `QuackDB.DDL.create_table/3`.
  The expression representation is internal; use the macro to construct checks.
  """

  @enforce_keys [:expression]
  defstruct [:expression]

  @type t :: %__MODULE__{expression: tuple()}

  @doc false
  def expression_ast!({operator, _, [left, right]}) when operator in [:and, :or] do
    left = expression_ast!(left)
    right = expression_ast!(right)
    quote do: {unquote(operator), unquote(left), unquote(right)}
  end

  def expression_ast!({:not, _, [expression]}) do
    expression = expression_ast!(expression)
    quote do: {:not, unquote(expression)}
  end

  def expression_ast!({:is_nil, _, [value]}) do
    value = operand_ast!(value)
    quote do: {:is_null, unquote(value)}
  end

  def expression_ast!({operator, _, [left, right]})
      when operator in [:==, :!=, :>, :>=, :<, :<=] do
    if is_nil(left) or is_nil(right) do
      raise ArgumentError,
            "CHECK comparisons with nil are not supported; use is_nil/1 or null: false"
    end

    left = operand_ast!(left)
    right = operand_ast!(right)
    quote do: {:compare, unquote(operator), unquote(left), unquote(right)}
  end

  def expression_ast!(other) do
    raise ArgumentError, "unsupported CHECK expression: #{Macro.to_string(other)}"
  end

  defp operand_ast!({:^, _, [value]}), do: quote(do: {:value, unquote(value)})

  defp operand_ast!({:field, _, [name]}) when is_atom(name) or is_binary(name),
    do: quote(do: {:column, unquote(name)})

  defp operand_ast!({:field, _, [{:^, _, [name]}]}),
    do: quote(do: {:column, unquote(name)})

  defp operand_ast!({name, _, context}) when is_atom(name) and is_atom(context),
    do: quote(do: {:column, unquote(name)})

  defp operand_ast!({:-, _, [number]}) when is_number(number),
    do: quote(do: {:value, unquote(-number)})

  defp operand_ast!(value) when is_number(value) or is_binary(value) or is_boolean(value),
    do: quote(do: {:value, unquote(value)})

  defp operand_ast!(nil), do: quote(do: {:value, nil})

  defp operand_ast!(other) do
    raise ArgumentError,
          "unsupported CHECK operand: #{Macro.to_string(other)}; pin runtime values with ^"
  end
end
