defmodule QuackDB.Protocol do
  @moduledoc """
  Quack protocol constants and codec entry point namespace.
  """

  @field_end 0xFFFF
  @optional_index_invalid 0xFFFF_FFFF_FFFF_FFFF
  @quack_version 3

  @message_types %{
    invalid: 0,
    connection_request: 1,
    connection_response: 2,
    prepare_request: 3,
    prepare_response: 4,
    fetch_request: 7,
    fetch_response: 8,
    send_data_request: 9,
    success_response: 10,
    disconnect_message: 11,
    cancel_request: 12,
    send_data_response: 14,
    acknowledgement: 15,
    heartbeat_request: 16,
    error_response: 100
  }

  @spec field_end() :: 0xFFFF
  def field_end, do: @field_end

  @spec optional_index_invalid() :: 0xFFFF_FFFF_FFFF_FFFF
  def optional_index_invalid, do: @optional_index_invalid

  @doc "Returns the Quack wire protocol version this client speaks (DuckDB 2.0)."
  @spec quack_version() :: 3
  def quack_version, do: @quack_version

  @spec message_type(atom()) :: non_neg_integer()
  def message_type(name), do: Map.fetch!(@message_types, name)

  @spec message_types() :: %{atom() => non_neg_integer()}
  def message_types, do: @message_types
end
