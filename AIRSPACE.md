# Airspace Radar user guide

The Windows app obtains aircraft states from OpenSky and sends coordinates, altitude, ground track, callsigns and map settings to the XIAO ESP32C6 over USB. The board projects the scene and renders it at 240 × 240 pixels. The desktop preview is rendered independently.

## Display behavior

The default view is an oblique 3D projection. Runways, coastlines, rivers, lakes and navaids remain on the ground plane. Aircraft and their trails are raised according to altitude. Vertical scale is exaggerated for readability: 12,000 m corresponds to 42 pixels. Unknown altitude is shown in gray at ground reference height.

Disable **3D view**, or pass `-TopDown`, for a top-down view. **Water outlines** is independent of the camera mode. Water geometry comes from offline Natural Earth data. Runways and navaids provide reference points where water outlines are unavailable.

The top bar contains the map label, aircraft count, scale, data age, remaining API credits and north indicator. Each aircraft has a small callsign label. The altitude colors are orange at 0 m, yellow at 1,000 m, green at 3,000 m, cyan at 6,000 m, blue at 9,000 m and purple at 12,000 m and above, with continuous interpolation between stops. The right-hand legend shows only `12k` at the top and `0` at the bottom. Values use meters, and `k` means one thousand. Unknown altitude is gray.

All valid aircraft inside the map viewport are rendered. Aircraft beneath the reserved legend area are excluded from the displayed count. Callsigns keep their relative label position when space permits. They may move to avoid collisions, or be omitted if no label position fits.

### Trails

Aircraft are matched between observations by ICAO address. A trail connects the tail-center anchor at the previous position to the current tail-center anchor. Cubic Bezier tangents follow the previous and current ground-track angles. Missing track angles use a straight connection. Color interpolates altitude along curve length, with gray at an endpoint whose altitude is unknown.

The line approximates movement between two observations. It is not an exact recorded flight path or a flight-plan route. A first observation has no trail. Repeated rendering between API requests and repeated position timestamps preserve the current trail. A successful response that omits the aircraft resets its history. Backward timestamps or gaps longer than `max(120 seconds, 2 × PollSeconds)` break the connection. Only the latest observation pair is retained.

## Hardware and firmware

Use a Seeed Studio XIAO ESP32C6 and a 240 × 240 ST7789 SPI module with seven pins and no CS pin.

| Display | XIAO ESP32C6 | GPIO |
| --- | --- | --- |
| GND | GND | — |
| VCC | 3V3 | — |
| SCL / SCK / CLK | D8 | 19 |
| SDA / MOSI / DIN | D10 | 18 |
| RES / RST | D3 | 21 |
| DC | D2 | 2 |
| BLK / BL | D1 | 1 |

The module's SDA/SCL labels refer to SPI. MISO is unused. D3 is GPIO21. Backlight control assumes an active-high control input on the module. Check the module's electrical requirements before connecting BLK.

In Arduino IDE, install Espressif's `esp32` 3.x board package and the Adafruit ST7735 and ST7789 Library, Adafruit GFX Library and Adafruit BusIO dependency. Open `airspace_usb/airspace_usb.ino`, select **XIAO_ESP32C6**, enable **USB CDC On Boot**, select the board's port, then upload.

After boot, the display shows `AIRSPACE USB / Waiting for PC frames...`. Close the serial monitor so the desktop app can open the same port. The firmware uses 180° rotation, 10 MHz SPI and `SPI_MODE3` by default. Change the constants or initialization in the sketch if your panel needs another configuration.

## Desktop app

The Windows package on [Releases](https://github.com/PROMAXULTRA/airspace-radar/releases) includes a precompiled `AirspaceRadar.exe`. Extract the full archive and double-click the EXE. It loads the bundled scripts and map data, so keep the package directory structure intact.

From the project root, run the following command or double-click `Start-AirspaceRadar.cmd`.

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tools\Start-AirspaceDesktop.ps1
```

The command file builds the console-free `AirspaceRadar.exe` launcher from source if it is missing. Closing the desktop window stops its background worker.

The app initially shows an offline demo. Click **Change airport** to search by code, name or city, or enter a custom latitude and longitude. View width accepts 5–1,000 km. **Fetch interval (s)** controls OpenSky requests. **Render interval (s)** controls desktop redraws using the latest received data.

Choose **OpenSky live** or **Offline demo**, then click **Apply and start**. For the physical display, enable **Send to USB display** and choose the COM port. Runways, navaids, trails, 3D view and water outlines have separate controls. The firmware must support `IPSW` to display water outlines in 2D.

Settings are stored locally in `.local/airspace-desktop/settings.json`. Airport search uses the bundled OurAirports catalog. Original local-name search aliases are retained alongside English airport names.

## Command-line usage

Run commands from the project root. Replace `COM4` with the actual port. Press Ctrl+C to stop a continuous task.

```powershell
# Offline demo on the USB display, centered on New York JFK
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Start-Airspace.ps1 -Port COM4

# Shenzhen, 100 km view
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Start-Airspace.ps1 -Port COM4 -Region Shenzhen -SpanKm 100

# Guangzhou Baiyun, 20 km view
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Start-Airspace.ps1 -Port COM4 -Region Baiyun -SpanKm 20

# An airport from the catalog, top-down, with water outlines hidden
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Start-Airspace.ps1 -Port COM4 -AirportIdent EDDM -TopDown -HideWaterLines

# Custom center, desktop only
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Start-Airspace.ps1 -PreviewOnly -CenterLatitude 22.6394 -CenterLongitude 113.8033 -SpanKm 100
```

`-Region` accepts `Airport` (Shanghai Pudong), `City` (Shanghai), `Nearby` (near Shanghai), `Guangzhou`, `Baiyun`, `Shenzhen`, `NewYork` and `JFK`. `JFK` aliases `NewYork`. The default is JFK with a 100 km view and a two-second render interval.

Use `-AirportIdent` for a catalog airport, or `-CenterLatitude` and `-CenterLongitude` for a custom center. `-SpanKm 0` selects the region default. `-HideRunways`, `-HideNavaids`, `-HideTrails` and `-HideWaterLines` disable individual layers. The legacy `-MaxAircraft` argument is accepted for compatibility and does not limit rendering.

## Live data

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Start-Airspace.ps1 -Port COM4 -Mode Live -Region NewYork -PollSeconds 30 -RenderSeconds 2
```

Live mode queries OpenSky `/states/all` with a geographic bounding box. It excludes on-ground states and initially received positions older than 60 seconds. Altitude coloring prefers barometric altitude, with geometric altitude as a fallback. `true_track` controls aircraft orientation and represents ground track. Missing altitude is gray.

The CLI defaults to polling every 10 seconds and rendering every two seconds. The USB display receives a new scene after observations or query state change. Between polls, the board updates its own data-age counter. The preview preserves the most recently observed aircraft positions.

Successful requests log `OpenSky update #...`, raw state count, fresh airborne count and API age. Frame logs include the next-request countdown and successful query count. An empty response displays `NO ADS-B DATA`, which describes API coverage rather than proving that an area has no aircraft.

OpenSky credits depend on the account, query area and current service rules. Anonymous credits are shared by public IP. Increase `-PollSeconds` to reduce requests. HTTP 429 triggers backoff based on the server's retry headers. Consult the [current API documentation](https://openskynetwork.github.io/opensky-api/rest.html) for quota rules.

### Authentication

Create an API Client in your OpenSky account, then run the credential helper.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Set-OpenSkyCredential.ps1
```

It prompts for the Client ID and a hidden Client Secret. Windows DPAPI protects the saved `%LOCALAPPDATA%\XiaoAirspace\opensky.credential.xml`, which can be decrypted by the same Windows user.

OpenSky's downloaded `credentials.json` is also supported. Accepted fields are `clientId` / `clientSecret` or `client_id` / `client_secret`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Start-Airspace.ps1 -Port COM4 -Mode Live -Region Shenzhen -CredentialPath .\airspace_usb\credentials.json
```

Both `OPENSKY_CLIENT_ID` and `OPENSKY_CLIENT_SECRET` environment variables may be used together and take precedence. Otherwise, an explicit `-CredentialPath` is used. With no explicit path, discovery checks `airspace_usb/credentials.json`, root `credentials.json`, `.local/opensky.credential.xml`, then the user's LocalApplicationData and profile-based XiaoAirspace paths.

An explicit missing or invalid file stops startup. With no supplied credentials, anonymous access is allowed. Startup reports `authenticated=True/False` and the credential source, without printing secret values. `True` means credentials were loaded. A successful authenticated request confirms server acceptance. OAuth tokens are obtained and renewed automatically and kept in process memory.

Credential files are local and excluded by `.gitignore`.

### Status bar

| Text | Meaning |
| --- | --- |
| `D+20s` | Demo running for 20 seconds |
| `L 5s` | Live response is five seconds old |
| `OLD90s` | Data is over 60 seconds old, or the most recent query failed |
| `ERR` | No successful live response yet |
| `Q3998` | API reported 3,998 credits remaining |
| `Q--` | Remaining-credit header was unavailable |
| `Q0` | API reported zero credits, highlighted in orange |
| `Q9k+` | Small-screen abbreviation for a value greater than 9,999 |

Credits come from `X-Rate-Limit-Remaining`, updated after actual requests. Full values remain in logs and JSON. A request with no HTTP response preserves the last received value. While powered, the board keeps aging its last scene after the PC task exits.

## Preview files

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Start-Airspace.ps1 -PreviewOnly -Once -DemoSeconds 0
```

This generates `previews/airspace-latest.png`, a diagnostic pixel packet `airspace-latest.ips`, and metadata `airspace-latest.json`. Use `-OutputDirectory` to choose another location. Desktop and board rendering share the same map configuration, though callsign placement may differ slightly.

Snapshot files are written to temporary files and replaced after completion. The UI reads with sharing enabled. Transient sharing conflicts are retried. A persistent preview lock skips that snapshot update while polling and USB output continue.

## Scene protocol and refresh

Normal radar operation uses **IPS4 scene packets**. `IPS?` queries basic top-down support, `IPST` queries 3D support, and `IPSW` queries top-down water support.

| Bytes | Content |
| --- | --- |
| 0–3 | ASCII `IPS4` |
| 4–7 | Payload length, little-endian uint32 |
| 8–11 | Sequence number, little-endian uint32 |
| 12–15 | Payload CRC-32/IEEE, little-endian uint32 |
| 16 onward | 32-byte scene configuration, then runway, navaid and aircraft records |

Runway records use 16 bytes, navaid records 12 bytes and aircraft records 36 bytes. Coordinates use integer millionths of a degree. Aircraft records include identity, callsign, previous and current coordinates, altitude and track.

The host sends a header, waits for `READY <sequence> 1024`, then sends acknowledged chunks of at most 1,024 bytes. The board validates the packet before rendering.

Flag `0x04` enables 3D. Flag `0x08` marks a top-down scene with water geometry. These packets append a uint16 water-segment count after aircraft records, followed by 16 bytes per segment containing endpoint coordinates. Coastlines, rivers and lake boundaries use the same segment representation. Plain top-down packets retain their earlier length.

The first scene appears immediately. Later map changes sweep from top to bottom over about two seconds, writing changed horizontal strips. The top bar refreshes independently. The live-age counter updates a 48 × 8 region once per second without new USB data. The backlight stays on.

Completed transfers return a `DRAW` diagnostic line and `OK <sequence>`. Incomplete packets, CRC failures or allocation failures preserve the last valid picture. Legacy IPS2 pixel packets remain supported for diagnostics.

## Verification

Run the offline checks from the project root.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Airspace.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-AirspaceTrails.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-AirspaceFiles.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-OpenSkyCredentials.ps1
```

They cover projection, altitude colors, label placement, CRC, framing, parsing, trails, credential handling and concurrent snapshot files using local fixtures.

For hardware diagnostics, generate the diagnostic preview packet first, close the main app and serial monitor, and run the following command after flashing the firmware.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Start-Airspace.ps1 -PreviewOnly -Once -DemoSeconds 0
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Airspace-Hardware.ps1 -Port COM4
```

The hardware test sends the saved IPS2 frame three times and waits for validation and display acknowledgments. Add `-CheckDirtyUpdates` to check unchanged frames, changed blocks, strip merging and CRC-failure recovery. The test restores the original frame.

## Troubleshooting

- **Port busy** — Close other tasks and serial monitors using that COM port.
- **No USB scene support** — Upload `airspace_usb/airspace_usb.ino` with USB CDC enabled.
- **No aircraft** — Check raw and fresh counts, API age, view width, coverage and quota in the log.
- **Old data** — Check connectivity, authentication errors and HTTP 429 backoff. The previous scene remains visible.
- **Preview file locked** — Allow the next update to retry and close tools that keep preview files exclusively open.
- **Backlight but no image** — Check wiring and the panel's required SPI mode. The sketch defaults to `SPI_MODE3`.
- **Inverted colors** — Check the display inversion setting for your panel.

## Data sources

The bundled catalog and reference subsets come from OurAirports. The map renderer uses offline Natural Earth coastlines, rivers and lakes. Some runway and navaid subsets cover New York JFK, LaGuardia and Newark, Shenzhen, Guangzhou, and Shanghai. Missing runway endpoints are omitted. The project does not supply complete airways or flight-plan routes.

See [third-party notices](THIRD_PARTY_NOTICES.md) for licenses, source links and provenance limitations.
