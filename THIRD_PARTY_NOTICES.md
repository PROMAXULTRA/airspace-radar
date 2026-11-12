# Third-party notices

The MIT license applies to original project code. The following materials and runtime services have their own licenses or terms.

## Font and display libraries

The bitmap font in `tools/data/airspace-assets.json` comes from Adafruit GFX. Its full BSD license is retained in [Adafruit-GFX-LICENSE.txt](tools/data/Adafruit-GFX-LICENSE.txt). Preserve that notice when distributing source or binaries containing the font.

The firmware depends on Adafruit GFX, Adafruit ST7735 and ST7789 Library, Adafruit BusIO, and Espressif Arduino ESP32. Users install these dependencies through Arduino IDE. Their source and license files are maintained upstream.

- [Adafruit GFX](https://github.com/adafruit/Adafruit-GFX-Library)
- [Adafruit ST7735 / ST7789](https://github.com/adafruit/Adafruit-ST7735-Library)
- [Adafruit BusIO](https://github.com/adafruit/Adafruit_BusIO)
- [Arduino ESP32](https://github.com/espressif/arduino-esp32)

## Airports, runways and navaids

`tools/data/desktop-airports.tsv`, `tools/data/new-york-reference.json`, and the runway and navaid fields in `airspace-assets.json` contain locally processed OurAirports data. The upstream repository publishes its data under the Unlicense. Some subsets record a retrieval date, but the existing files do not retain a complete history of original download versions.

- [OurAirports data repository](https://github.com/davidmegginson/ourairports-data)
- [Upstream license](https://github.com/davidmegginson/ourairports-data/blob/main/LICENSE)

## Coastlines, rivers and lakes

`tools/data/airspace-coast.gz` and `tools/data/airspace-inland.gz` are processed from Natural Earth 1:10m coastlines, river centerlines and lake boundaries. Natural Earth declares its map data to be in the public domain.

Made with Natural Earth.

- [Terms of use](https://www.naturalearthdata.com/about/terms-of-use/)
- [Coastlines](https://www.naturalearthdata.com/downloads/10m-physical-vectors/10m-coastline/)
- [Rivers and lake centerlines](https://www.naturalearthdata.com/downloads/10m-physical-vectors/10m-rivers-lake-centerlines/)
- [Lakes](https://www.naturalearthdata.com/downloads/10m-physical-vectors/10m-lakes/)

The packing tool is `tools/Pack-AirspaceCoast.py`. Ready-to-use offline data is included. Original shapefile versions and retrieval dates were not fully recorded.

## OpenSky Network

The app requests live state vectors from OpenSky at runtime. Packaged demo screenshots use local simulated data. Access to, use of, and redistribution of OpenSky data are governed by OpenSky's terms. The project MIT license does not replace those terms.

The official documentation describes the live API as intended for research and non-commercial use. Contact OpenSky about commercial data use. Quotas and authentication requirements can change, so consult its current documentation.

- [OpenSky API](https://openskynetwork.github.io/opensky-api/)
- [Citation and terms of use](https://openskynetwork.github.io/opensky-api/index.html#citation-and-terms-of-use)

When publishing websites, papers or presentations using OpenSky data, follow its citation requirements for the following paper.

Matthias Schäfer, Martin Strohmeier, Vincent Lenders, Ivan Martinovic and Matthias Wilhelm. “Bringing Up OpenSky: A Large-scale ADS-B Sensor Network for Research.” IPSN, 2014, pp. 83–94.
