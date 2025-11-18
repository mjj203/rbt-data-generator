# MapProxy APIs

MapProxy is an open source proxy for geospatial data that caches, accelerates and transforms data from existing map services. This API documentation describes the available endpoints and services.

## Supported Services

- **WMS** (Web Map Service) 1.0.0-1.3.0
- **WMTS** (Web Map Tile Service) 1.0.0

## API Documentation

<swagger-ui src="../mapproxy_openapi.yaml"/>

## Quick Links

### Service Endpoints

- **WMS Capabilities**: `/service?SERVICE=WMS&REQUEST=GetCapabilities&VERSION=1.3.0`
- **WMTS Capabilities**: `/wmts?SERVICE=WMTS&REQUEST=GetCapabilities&VERSION=1.0.0`
- **Demo Interface**: `/demo`

### Example Requests

#### WMS GetMap Request

```text
/service?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap&LAYERS=layer_name&CRS=EPSG:4326&BBOX=minx,miny,maxx,maxy&WIDTH=256&HEIGHT=256&FORMAT=image/png
```

#### WMTS Tile Request (RESTful)

```text
/wmts/{layer}/GLOBAL_MERCATOR/{z}/{x}/{y}.png
```

## Configuration

For detailed configuration options and deployment instructions, refer to the [MapProxy documentation](https://mapproxy.org).
