defmodule SpatialWmsWeb.Router do
  use Plug.Router

  alias SpatialWms.Places

  @supported_formats ["application/geo+json", "application/json", "geojson"]

  plug(:fetch_query_params)
  plug(:match)
  plug(:dispatch)

  get "/" do
    params = normalize_params(conn.query_params)

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
    with :ok <- require_layer(params),
         :ok <- require_supported_format(params),
         {:ok, bbox} <- parse_bbox(params["bbox"]) do
      features =
        bbox
        |> Places.by_bbox()
        |> Enum.map(&feature/1)

      body = Jason.encode!(%{type: "FeatureCollection", features: features})

      conn
      |> put_resp_content_type("application/geo+json")
      |> send_resp(200, body)
    else
      {:error, code, message} -> service_exception(conn, code, message)
    end
  end

  defp feature(place) do
    %{
      type: "Feature",
      id: place.id,
      properties: %{name: place.name},
      geometry: place.geometry
    }
  end

  defp send_capabilities(conn) do
    conn
    |> put_resp_content_type("text/xml")
    |> send_resp(200, capabilities_xml(conn))
  end

  defp require_layer(%{"layers" => layer}) do
    if layer == Places.layer() do
      :ok
    else
      {:error, "LayerNotDefined", "Unsupported LAYERS=#{layer}. Try LAYERS=#{Places.layer()}"}
    end
  end

  defp require_layer(_params), do: {:error, "MissingParameterValue", "Missing LAYERS parameter"}

  defp require_supported_format(%{"format" => format}) when format in @supported_formats, do: :ok

  defp require_supported_format(%{"format" => "application/geo json"}), do: :ok

  defp require_supported_format(%{"format" => _format}) do
    {:error, "InvalidFormat", "This GeoJSON WMS profile supports FORMAT=application/geo+json"}
  end

  defp require_supported_format(_params), do: :ok

  defp parse_bbox(nil), do: {:error, "MissingParameterValue", "Missing BBOX parameter"}

  defp parse_bbox(value) do
    case value |> String.split(",") |> Enum.map(&Float.parse/1) do
      [{min_x, ""}, {min_y, ""}, {max_x, ""}, {max_y, ""}] when min_x < max_x and min_y < max_y ->
        {:ok, {min_x, min_y, max_x, max_y}}

      _other ->
        {:error, "InvalidParameterValue", "BBOX must be minx,miny,maxx,maxy"}
    end
  end

  defp capabilities_xml(conn) do
    url = Plug.Conn.request_url(conn)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <WMS_Capabilities version="1.3.0" xmlns="http://www.opengis.net/wms">
      <Service>
        <Name>WMS</Name>
        <Title>QuackDB Spatial GeoJSON WMS Example</Title>
      </Service>
      <Capability>
        <Request>
          <GetCapabilities><Format>text/xml</Format><DCPType><HTTP><Get><OnlineResource href="#{url}" /></Get></HTTP></DCPType></GetCapabilities>
          <GetMap><Format>application/geo+json</Format><DCPType><HTTP><Get><OnlineResource href="#{url}" /></Get></HTTP></DCPType></GetMap>
        </Request>
        <Layer queryable="1">
          <Name>#{Places.layer()}</Name>
          <Title>Sample places from DuckDB Spatial</Title>
          <CRS>EPSG:4326</CRS>
          <EX_GeographicBoundingBox>
            <westBoundLongitude>-180</westBoundLongitude>
            <eastBoundLongitude>180</eastBoundLongitude>
            <southBoundLatitude>-90</southBoundLatitude>
            <northBoundLatitude>90</northBoundLatitude>
          </EX_GeographicBoundingBox>
        </Layer>
      </Capability>
    </WMS_Capabilities>
    """
  end

  defp service_exception(conn, code, message) do
    body = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ServiceExceptionReport version="1.3.0">
      <ServiceException code="#{code}">#{message}</ServiceException>
    </ServiceExceptionReport>
    """

    conn
    |> put_resp_content_type("text/xml")
    |> send_resp(400, body)
  end

  defp normalize_params(params) do
    Map.new(params, fn {key, value} -> {String.downcase(key), normalize_value(value)} end)
  end

  defp normalize_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_value(value), do: value
end
