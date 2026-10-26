defmodule QuackDB.Protocol.Message do
  @moduledoc """
  Quack protocol message structs.
  """

  defmodule Header do
    @moduledoc """
    Message envelope metadata shared by every Quack request and response.
    """

    @type t :: %__MODULE__{
            type: atom(),
            connection_id: String.t(),
            client_query_id: non_neg_integer() | nil
          }

    defstruct type: :invalid, connection_id: "", client_query_id: nil
  end

  defmodule ConnectionRequest do
    @moduledoc """
    Client handshake request sent before issuing queries.
    """

    @type t :: %__MODULE__{
            auth_string: String.t(),
            client_duckdb_version: String.t(),
            client_platform: String.t(),
            min_supported_quack_version: non_neg_integer(),
            max_supported_quack_version: non_neg_integer(),
            client_id: String.t(),
            heartbeat_timeout_seconds: non_neg_integer()
          }

    defstruct auth_string: "",
              client_duckdb_version: "",
              client_platform: "elixir",
              min_supported_quack_version: 3,
              max_supported_quack_version: 3,
              client_id: "",
              heartbeat_timeout_seconds: 60
  end

  defmodule ConnectionResponse do
    @moduledoc """
    Server handshake response with DuckDB and Quack protocol version metadata.
    """

    @type t :: %__MODULE__{
            server_duckdb_version: String.t(),
            server_platform: String.t(),
            quack_version: non_neg_integer(),
            heartbeat_timeout_seconds: non_neg_integer()
          }

    defstruct server_duckdb_version: "",
              server_platform: "",
              quack_version: 0,
              heartbeat_timeout_seconds: 0
  end

  defmodule PrepareRequest do
    @moduledoc """
    Request to prepare and execute a SQL statement on the remote DuckDB server.

    `query_uuid` identifies the query for fetches, cancellation, and
    acknowledgement; zero is reserved for internal server traffic. `inline_rows`
    caps the rows the prepare response carries; `0` makes the server answer
    before the statement produces a row, which statements that read client
    data streams need.
    """

    @type t :: %__MODULE__{
            sql_query: String.t(),
            query_uuid: non_neg_integer(),
            inline_rows: non_neg_integer() | nil
          }

    defstruct sql_query: "", query_uuid: 0, inline_rows: nil
  end

  defmodule PrepareResponse do
    @moduledoc """
    Initial query response containing schema metadata, first chunks, and fetch state.
    """

    @type t :: %__MODULE__{
            result_types: [term()],
            result_names: [String.t()],
            needs_more_fetch: boolean(),
            results: [term() | nil],
            query_uuid: integer()
          }

    defstruct result_types: [],
              result_names: [],
              needs_more_fetch: false,
              results: [],
              query_uuid: 0
  end

  defmodule FetchRequest do
    @moduledoc """
    Request for one batch of a query result.

    Batches are numbered densely from 1 after the batches the prepare response
    carried inline. A retry names the same `batch_index`, and `ack_index` tells
    the server that every batch up to it arrived.
    """

    @type t :: %__MODULE__{
            query_uuid: integer(),
            batch_index: non_neg_integer(),
            ack_index: non_neg_integer()
          }

    defstruct query_uuid: 0, batch_index: 0, ack_index: 0
  end

  defmodule FetchResponse do
    @moduledoc """
    Response carrying one result batch.

    The chunks travel as a raw blob after the message body. The terminal
    response carries no chunks and sets `total_batches`.
    """

    @type t :: %__MODULE__{
            results: [term()],
            batch_index: non_neg_integer() | nil,
            total_batches: non_neg_integer() | nil
          }

    defstruct results: [], batch_index: nil, total_batches: nil
  end

  defmodule SendDataRequest do
    @moduledoc """
    One batch of a client data stream read by `scan_data_from_quack_client`.

    The chunks travel as a raw blob after the message body. The stream ends
    with a chunk-less request that sets `total_batches`, so a short stream fails
    instead of inserting fewer rows.
    """

    @type t :: %__MODULE__{
            stream_id: String.t(),
            chunks: [term()],
            batch_index: non_neg_integer() | nil,
            total_batches: non_neg_integer() | nil
          }

    defstruct stream_id: "", chunks: [], batch_index: nil, total_batches: nil
  end

  defmodule SendDataResponse do
    @moduledoc """
    Success reply to a send-data request. `accept_budget` is reserved by the
    server for future flow control; `nil` means unbounded.
    """

    @type t :: %__MODULE__{accept_budget: non_neg_integer() | nil}

    defstruct accept_budget: nil
  end

  defmodule CancelRequest do
    @moduledoc """
    Request to interrupt the running query on a connection. A zero
    `query_uuid` cancels whatever query is running.
    """

    @type t :: %__MODULE__{query_uuid: integer()}

    defstruct query_uuid: 0
  end

  defmodule Acknowledgement do
    @moduledoc """
    Confirms a full result arrived, so a server with reconnects enabled drops
    its cached copy.
    """

    @type t :: %__MODULE__{query_uuid: integer()}

    defstruct query_uuid: 0
  end

  defmodule HeartbeatRequest do
    @moduledoc """
    Renews the connection lease without running a query.
    """

    @type t :: %__MODULE__{}

    defstruct []
  end

  defmodule SuccessResponse do
    @moduledoc """
    Empty success response used by protocol operations without result data.
    """

    @type t :: %__MODULE__{}

    defstruct []
  end

  defmodule Disconnect do
    @moduledoc """
    Request to close a remote Quack connection.
    """

    @type t :: %__MODULE__{}

    defstruct []
  end

  defmodule ErrorResponse do
    @moduledoc """
    Server-side Quack error response.

    `exception_type` is DuckDB's exception type name (for example `"Catalog"`
    or `"Constraint"`), `extra_info` carries the transferable error details, and
    `must_invalidate` reports that the server's database died, so the client
    must stop using the connection.
    """

    @type t :: %__MODULE__{
            message: String.t(),
            exception_type: String.t(),
            extra_info: %{String.t() => String.t()},
            must_invalidate: boolean()
          }

    defstruct message: "", exception_type: "", extra_info: %{}, must_invalidate: false
  end
end
