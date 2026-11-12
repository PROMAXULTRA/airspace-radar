"""Pack Natural Earth coastline, river and lake linework for the offline radar."""

import argparse
import gzip
from pathlib import Path
import struct
from zipfile import ZipFile


def lake_centerlines(attributes):
    records, start, width = struct.unpack_from("<IHH", attributes, 4)
    column = 1  # DBF records start with a deletion flag.
    for offset in range(32, start - 1, 32):
        name = attributes[offset:offset + 11].split(b"\0", 1)[0].lower()
        size = attributes[offset + 16]
        if name == b"featurecla":
            return {
                row for row in range(records)
                if attributes[start + row*width + column:start + row*width + column + size].strip(b"\0 ") == b"Lake Centerline"
            }
        column += size
    raise ValueError("River data is missing its feature class field.")


def polylines(data, excluded):
    offset = 100  # Shapefile header.
    index = -1
    while offset < len(data):
        index += 1
        _, length = struct.unpack_from(">2i", data, offset)
        record = memoryview(data)[offset + 8:offset + 8 + 2 * length]
        offset += 8 + 2 * length
        if index in excluded:
            continue
        if struct.unpack_from("<i", record)[0] not in (3, 5):
            raise ValueError("Expected a PolyLine or Polygon shapefile.")
        parts, points = struct.unpack_from("<2i", record, 36)
        breaks = (*struct.unpack_from(f"<{parts}i", record, 44), points)
        coordinates = list(struct.iter_unpack("<2d", record[44 + 4 * parts:]))
        for begin, end in zip(breaks, breaks[1:]):
            if end - begin >= 2:
                yield coordinates[begin:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, nargs="+")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent / "data" / "airspace-coast.gz")
    args = parser.parse_args()
    lines = []
    for source in args.source:
        with ZipFile(source) as archive:
            name = source.stem
            excluded = lake_centerlines(archive.read(name + ".dbf")) if name == "ne_10m_rivers_lake_centerlines" else set()
            lines.extend(polylines(archive.read(name + ".shp"), excluded))
    data = bytearray(struct.pack("<4si", b"CST1", len(lines)))
    for line in lines:
        data.extend(struct.pack("<i", len(line)))
        for lon, lat in line:
            data.extend(struct.pack("<2i", round(lon*100000), round(lat*100000)))
    args.output.write_bytes(gzip.compress(data, mtime=0))
    print(f"Packed {len(lines)} water lines into {args.output.name}.")


if __name__ == "__main__":
    main()
