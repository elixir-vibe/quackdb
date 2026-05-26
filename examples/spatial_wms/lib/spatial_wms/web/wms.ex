defmodule SpatialWMS.Web.WMS do
  @moduledoc false

  alias SpatialWMS.Places

  @supported_formats ["application/geo+json", "application/json", "geojson"]

  def normalize_params(params) do
    Map.new(params, fn {key, value} -> {String.downcase(key), normalize_value(value)} end)
  end

  def validate_map_request(params) do
    with :ok <- require_layer(params),
         :ok <- require_supported_format(params),
         {:ok, bbox} <- parse_bbox(params["bbox"]) do
      {:ok, bbox}
    end
  end

  def capabilities_xml(url) do
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

  def exception_xml(code, message) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ServiceExceptionReport version="1.3.0">
      <ServiceException code="#{code}">#{message}</ServiceException>
    </ServiceExceptionReport>
    """
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

  defp normalize_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_value(value), do: value
end
