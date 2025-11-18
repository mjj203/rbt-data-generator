# Tileserver-GL APIs

TileServer-GL is a Node.js-based server for serving raster and vector map tiles from MBTiles files, with support for static map images, styles, sprites, fonts, and more.

## Key Features

- **Map Styles**: Serve Mapbox GL JS style specifications
- **Rendered Tiles**: Generate PNG/JPG/WebP tiles from vector data
- **Static Maps**: Create static map images with overlays
- **Raw Data**: Serve vector and raster tile data
- **Fonts & Sprites**: Provide map fonts and sprite sheets

## API Documentation

<swagger-ui src="../tileserver_openapi.yaml"/>

## Quick Start

### Essential Endpoints

- **List Styles**: `/styles.json`
- **Get Style**: `/styles/{id}/style.json`
- **Rendered Tiles**: `/styles/{id}/{z}/{x}/{y}.png`
- **Static Map (Center)**: `/styles/{id}/static/{lon},{lat},{zoom}/{width}x{height}.png`
- **Data Tiles**: `/data/{id}/{z}/{x}/{y}.pbf`
- **Health Check**: `/health`

### Example Requests

#### Get a Rendered Tile
```
GET /styles/basic/256/10/512/341@2x.png
```
Returns a 256x256 pixel tile at zoom 10, x:512, y:341 with 2x resolution

#### Generate a Static Map
```
GET /styles/basic/static/2.3,48.8,12/800x600.png
```
Creates an 800x600 static map centered on Paris at zoom 12

#### Static Map with Markers and Path
```
GET /styles/basic/static/auto/800x600.png?path=stroke:blue|width:3|2.3,48.8|2.4,48.9&marker=2.35,48.85|marker-red.png
```
Auto-fits a map with a blue path and red marker

#### Access Vector Tile Data
```
GET /data/openmaptiles/14/8938/5680.pbf
```
Returns raw vector tile data in Mapbox Vector Tile format

## Data Formats

### Supported Tile Formats
- **Vector**: PBF (Protocol Buffer), GeoJSON
- **Raster**: PNG, JPG/JPEG, WebP
- **Metadata**: TileJSON, WMTS Capabilities

### Static Image Options
- Multiple resolutions (1x-4x)
- Path overlays with custom styling
- Marker placement with custom icons
- Auto-fitting to content
- Bounding box specification

## Additional Resources

For more information about TileServer-GL configuration and deployment, visit the [official repository](https://github.com/maptiler/tileserver-gl).
