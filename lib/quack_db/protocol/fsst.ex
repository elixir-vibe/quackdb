if Code.ensure_loaded?(FSST.Table) do
  defmodule QuackDB.Protocol.FSST do
    @moduledoc """
    Internal bridge to the optional `:fsst` package.

    DuckDB currently flattens FSST vectors before Quack serialization in the
    versions QuackDB targets. This module keeps the package boundary ready for
    future Quack payloads that expose serialized FSST symbols and compressed
    string payloads.
    """

    alias QuackDB.Error

    @spec decompress_values([binary()], [binary()]) :: {:ok, [binary()]} | {:error, Error.t()}
    def decompress_values(symbols, payloads) when is_list(symbols) and is_list(payloads) do
      with {:ok, table} <- table_from_symbols(symbols) do
        decompress_payloads(table, payloads, [])
      end
    end

    def decompress_values(_symbols, _payloads) do
      error(:invalid_fsst_payload, "expected FSST symbols and payloads to be lists")
    end

    defp table_from_symbols(symbols) do
      case FSST.Table.from_symbols(symbols) do
        {:ok, table} ->
          {:ok, table}

        {:error, reason} ->
          error(:invalid_fsst_symbols, "invalid FSST symbol table: #{inspect(reason)}")
      end
    end

    defp decompress_payloads(_table, [], acc), do: {:ok, Enum.reverse(acc)}

    defp decompress_payloads(table, [payload | payloads], acc) when is_binary(payload) do
      case FSST.decompress(table, payload) do
        {:ok, value} ->
          decompress_payloads(table, payloads, [value | acc])

        {:error, reason} ->
          error(:invalid_fsst_payload, "invalid FSST payload: #{inspect(reason)}")
      end
    end

    defp decompress_payloads(_table, [_payload | _payloads], _acc) do
      error(:invalid_fsst_payload, "expected compressed FSST payloads to be binaries")
    end

    defp error(code, message) do
      {:error, Error.new(code, message, source: :protocol)}
    end
  end
end
