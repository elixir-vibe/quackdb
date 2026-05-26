defmodule SpatialWMS.Web.Router do
  use Plug.Router

  alias SpatialWMS.Places.DuckDB
  alias SpatialWMS.Web.{GeoJSON, WMS}

  plug(:fetch_query_params)
  plug(:match)
  plug(:dispatch)

  get "/" do
    params = WMS.normalize_params(conn.query_params)

    case {params["service"], params["request"]} do
      {"WMS", "GetCapabilities"} ->
        send_capabilities(conn)

      {"WMS", "GetMap"} ->
        send_map(conn, params)

      _other ->
        service_exception(
          conn,
          "InvalidRequest",
          "Expected SERVICE=WMS and REQUEST=GetCapabilities or GetMap"
        )
    end
  end

  match _ do
    service_exception(conn, "NotFound", "Only / is served by this example")
  end

  defp send_map(conn, params) do
    case WMS.validate_map_request(params) do
      {:ok, bbox} ->
        body = bbox |> DuckDB.by_bbox() |> GeoJSON.feature_collection() |> Jason.encode!()

        conn
        |> put_resp_content_type("application/geo+json")
        |> send_resp(200, body)

      {:error, code, message} ->
        service_exception(conn, code, message)
    end
  end

  defp send_capabilities(conn) do
    conn
    |> put_resp_content_type("text/xml")
    |> send_resp(200, WMS.capabilities_xml(Plug.Conn.request_url(conn)))
  end

  defp service_exception(conn, code, message) do
    conn
    |> put_resp_content_type("text/xml")
    |> send_resp(400, WMS.exception_xml(code, message))
  end
end
