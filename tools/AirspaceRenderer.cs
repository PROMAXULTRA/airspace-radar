using System;
using System.IO;
using System.IO.Compression;
using System.Drawing;
using System.Collections.Generic;

public sealed class AirspaceTarget {
    public string Id, Identity;
    public double Latitude, Longitude;
    public int Altitude = Int32.MinValue, Track = -1;
    public long PositionTime;
    public bool HasPreviousPosition;
    public double PreviousLatitude, PreviousLongitude;
    public int PreviousAltitude = Int32.MinValue;
    public int PreviousTrack = -1;
    public double X, Y;
    internal PointF Ground;
    public int LabelX, LabelY;
    public string[] Lines;
    public ushort Color;
}

public sealed class AirspaceSceneNavaid {
    public readonly string Id;
    public readonly double Longitude, Latitude;
    public AirspaceSceneNavaid(string id, double longitude, double latitude) {
        Id = id; Longitude = longitude; Latitude = latitude;
    }
}

// Advance only on successful source updates, never merely because another
// identical USB frame is rendered. Store values, not mutable target objects.
public sealed class AirspaceTrailHistory {
    private sealed class Sample {
        internal double Latitude, Longitude;
        internal int Altitude, Track;
        internal long Time;
        internal bool HasPrevious;
        internal double PreviousLatitude, PreviousLongitude;
        internal int PreviousAltitude, PreviousTrack;
    }
    private Dictionary<string, Sample> latest = new Dictionary<string, Sample>();
    private readonly int maximumGapSeconds;
    public AirspaceTrailHistory(int maximumGapSeconds = 120) {
        this.maximumGapSeconds = Math.Max(1, maximumGapSeconds);
    }
    public void Observe(AirspaceTarget[] targets, long sourceTime) {
        Dictionary<string, Sample> next = new Dictionary<string, Sample>();
        foreach (AirspaceTarget target in targets) {
            target.HasPreviousPosition = false;
            string key = String.IsNullOrWhiteSpace(target.Identity) ? target.Id : target.Identity;
            if (String.IsNullOrWhiteSpace(key)) continue;
            long time = target.PositionTime > 0 ? target.PositionTime : sourceTime;
            Sample sample = new Sample { Latitude = target.Latitude, Longitude = target.Longitude, Altitude = target.Altitude, Track = target.Track, Time = time };
            Sample previous;
            if (latest.TryGetValue(key, out previous)) {
                if (time == previous.Time && target.Latitude == previous.Latitude && target.Longitude == previous.Longitude) {
                    // A cached observation retains the last real segment.
                    sample.HasPrevious = previous.HasPrevious;
                    sample.PreviousLatitude = previous.PreviousLatitude;
                    sample.PreviousLongitude = previous.PreviousLongitude;
                    sample.PreviousAltitude = previous.PreviousAltitude;
                    sample.PreviousTrack = previous.PreviousTrack;
                } else if (time >= previous.Time && time - previous.Time <= maximumGapSeconds) {
                    sample.HasPrevious = true;
                    sample.PreviousLatitude = previous.Latitude;
                    sample.PreviousLongitude = previous.Longitude;
                    sample.PreviousAltitude = previous.Altitude;
                    sample.PreviousTrack = previous.Track;
                }
            }
            target.HasPreviousPosition = sample.HasPrevious;
            target.PreviousLatitude = sample.PreviousLatitude;
            target.PreviousLongitude = sample.PreviousLongitude;
            target.PreviousAltitude = sample.PreviousAltitude;
            target.PreviousTrack = sample.PreviousTrack;
            next[key] = sample;
        }
        // Disappearing aircraft lose their segment; a later reappearance starts fresh.
        latest = next;
    }
}

// Owned by the running viewer, so replacing the pixel renderer does not cause
// existing labels to choose a different side of their aircraft on every frame.
public sealed class AirspaceLabelLayout {
    internal sealed class Anchor {
        internal int Dx, Dy;
        internal DateTime LastSeen;
    }
    internal readonly Dictionary<string, Anchor> Anchors = new Dictionary<string, Anchor>();
    internal void Prune() {
        DateTime cutoff = DateTime.UtcNow.AddMinutes(-10);
        List<string> expired = new List<string>();
        foreach (KeyValuePair<string, Anchor> item in Anchors)
            if (item.Value.LastSeen < cutoff) expired.Add(item.Key);
        foreach (string key in expired) Anchors.Remove(key);
    }
}

// Desktop RGB565 preview. The small screen renders the same inputs locally.
public sealed class AirspaceRenderer {
    public const int Width = 240, Height = 240, FrameBytes = 115200;
    public const int MapRight = 214;
    private readonly ushort[] pixels = new ushort[Width * Height];
    private readonly byte[] font;
    private readonly ushort[] plane;
    private readonly double lat0, lon0, scale;
    private readonly AirspaceLabelLayout layout;
    private readonly List<Rectangle> obstacles = new List<Rectangle>();
    public readonly List<AirspaceTarget> Targets = new List<AirspaceTarget>();
    public readonly List<Rectangle> LabelBounds = new List<Rectangle>();
    public int TrailCount { get; private set; }
    public bool ShowTrails = true;
    public bool TiltedView;
    private const ushort White = 0xFFFF, Gray = 0xAD55;
    private const ushort WaterColor = 0x2925;
    public static readonly ushort RunwayColor = Color565(105, 193, 209);
    public static readonly ushort NavaidColor = Color565(214, 185, 118);

    public AirspaceRenderer(byte[] fontBytes, ushort[] planeRows, double longitude, double latitude, double spanKm)
        : this(fontBytes, planeRows, longitude, latitude, spanKm, new AirspaceLabelLayout()) { }

    public AirspaceRenderer(byte[] fontBytes, ushort[] planeRows, double longitude, double latitude, double spanKm, AirspaceLabelLayout labelLayout) {
        if (fontBytes.Length != 1280 || planeRows.Length != 16) throw new ArgumentException("Invalid bitmap assets");
        if (spanKm < 5 || spanKm > 2000) throw new ArgumentOutOfRangeException("spanKm");
        font = fontBytes; plane = planeRows;
        layout = labelLayout ?? new AirspaceLabelLayout();
        lat0 = latitude * Math.PI / 180; lon0 = longitude * Math.PI / 180;
        scale = 232 / spanKm;
        obstacles.Add(new Rectangle(0, 0, 240, 26));
        obstacles.Add(new Rectangle(MapRight + 1, 24, Width - MapRight - 1, Height - 24));
    }

    public static ushort Color565(int r, int g, int b) {
        return (ushort)(((r & 248) << 8) | ((g & 252) << 3) | (b >> 3));
    }

    // Altitude in metres. A local, bright-on-black palette inspired by the
    // OpenSky map, rather than a claim to reproduce its exact colour stops.
    private static readonly int[] AltitudeStops = { 0, 1000, 3000, 6000, 9000, 12000 };
    private static readonly int[,] AltitudeRgb = {
        {255,152,0}, {255,230,0}, {120,255,50},
        {0,223,217}, {102,140,255}, {231,102,255}
    };
    public static ushort AltitudeColor(int metres) {
        if (metres == Int32.MinValue) return Gray;
        int altitude = Math.Max(0, Math.Min(12000, metres));
        for (int i = 1; i < AltitudeStops.Length; i++) {
            if (altitude > AltitudeStops[i]) continue;
            double t = (double)(altitude - AltitudeStops[i-1]) / (AltitudeStops[i] - AltitudeStops[i-1]);
            int r = (int)Math.Round(AltitudeRgb[i-1,0] + t * (AltitudeRgb[i,0] - AltitudeRgb[i-1,0]));
            int g = (int)Math.Round(AltitudeRgb[i-1,1] + t * (AltitudeRgb[i,1] - AltitudeRgb[i-1,1]));
            int b = (int)Math.Round(AltitudeRgb[i-1,2] + t * (AltitudeRgb[i,2] - AltitudeRgb[i-1,2]));
            return Color565(r, g, b);
        }
        return Color565(231,102,255);
    }

    public PointF Project(double longitude, double latitude) {
        double p = latitude * Math.PI / 180, d = longitude * Math.PI / 180 - lon0;
        double c = Math.Acos(Math.Max(-1, Math.Min(1, Math.Sin(lat0) * Math.Sin(p) + Math.Cos(lat0) * Math.Cos(p) * Math.Cos(d))));
        double k = c < 1e-9 ? 1 : c / Math.Sin(c);
        double east = 6371.0088 * k * Math.Cos(p) * Math.Sin(d);
        double north = 6371.0088 * k * (Math.Cos(lat0) * Math.Sin(p) - Math.Sin(lat0) * Math.Cos(p) * Math.Cos(d));
        return new PointF((float)(120 + east * scale), (float)(132 - north * scale));
    }

    // Oblique orthographic camera. Altitude is exaggerated for a 240px view.
    private const double CameraCos = 0.978147600734, CameraSin = 0.207911690818;
    private static double Lift(int altitude) { return Math.Max(0, Math.Min(12000, altitude)) * 0.0035; }
    private static double CameraDepth(PointF p) { return -CameraSin * (p.X - 106.5) + CameraCos * (p.Y - 132); }
    private PointF DisplayPoint(PointF p, double lift) {
        if (!TiltedView) return p;
        return new PointF((float)(107 + 0.83 * (CameraCos * (p.X - 106.5) + CameraSin * (p.Y - 132))),
            (float)(151 + 0.62 * CameraDepth(p) - lift));
    }

    public PointF ProjectOnDisplay(double longitude, double latitude, int altitude) {
        return DisplayPoint(Project(longitude, latitude), Lift(altitude));
    }

    public static double[][] LoadCoastlines(string path, double longitude, double latitude, double span) {
        return LoadWaterLines(new[] {path}, longitude, latitude, span);
    }

    public static double[][] LoadWaterLines(string[] paths, double longitude, double latitude, double span) {
        const int budget = 384; // Bound decorative geometry independently of aircraft.
        double latRange = span / 111.0;
        double longitudeScale = Math.Cos(latitude * Math.PI / 180);
        double lonRange = Math.Min(180, latRange / Math.Max(.01, longitudeScale));
        var segments = new List<double[]>();
        foreach (string path in paths) {
            ReadWaterLines(path,longitude,latitude,lonRange,latRange,longitudeScale,segments);
        }
        if (segments.Count > budget) {
            segments.Sort((a,b) => b[4].CompareTo(a[4]));
            segments.RemoveRange(budget, segments.Count-budget);
        }
        return segments.ToArray();
    }

    private static void ReadWaterLines(string path, double longitude, double latitude, double lonRange,
            double latRange, double longitudeScale, List<double[]> segments) {
        using (var stream = new GZipStream(File.OpenRead(path), CompressionMode.Decompress))
        using (var reader = new BinaryReader(stream)) {
            if (reader.ReadUInt32() != 0x31545343u) throw new InvalidDataException("Invalid map line data.");
            int lines = reader.ReadInt32();
            for (int line = 0; line < lines; ++line) {
                int points = reader.ReadInt32();
                double previousLon = 0, previousLat = 0;
                for (int i = 0; i < points; ++i) {
                    double lon = reader.ReadInt32() / 100000.0, lat = reader.ReadInt32() / 100000.0;
                    double relative = Math.IEEERemainder(lon - longitude, 360);
                    double previous = Math.IEEERemainder(previousLon - longitude, 360);
                    if (i > 0 && Math.Abs(relative - previous) < 180 &&
                        Math.Min(relative, previous) <= lonRange && Math.Max(relative, previous) >= -lonRange &&
                        Math.Min(lat, previousLat) <= latitude + latRange && Math.Max(lat, previousLat) >= latitude - latRange) {
                        double dx = (relative - previous) * longitudeScale, dy = lat - previousLat;
                        segments.Add(new[] {previousLon, previousLat, lon, lat, dx*dx + dy*dy});
                    }
                    previousLon = lon;
                    previousLat = lat;
                }
            }
        }
    }

    public static double[] Offset(double longitude, double latitude, double eastKm, double northKm) {
        double bearing = Math.Atan2(eastKm, northKm), distance = Math.Sqrt(eastKm * eastKm + northKm * northKm) / 6371.0088;
        double p = latitude * Math.PI / 180, l = longitude * Math.PI / 180;
        double q = Math.Asin(Math.Sin(p) * Math.Cos(distance) + Math.Cos(p) * Math.Sin(distance) * Math.Cos(bearing));
        double next = l + Math.Atan2(Math.Sin(bearing) * Math.Sin(distance) * Math.Cos(p), Math.Cos(distance) - Math.Sin(p) * Math.Sin(q));
        return new double[] { next * 180 / Math.PI, q * 180 / Math.PI };
    }

    private void Pixel(int x, int y, ushort color) {
        if (x >= 0 && x < Width && y >= 0 && y < Height) pixels[y * Width + x] = color;
    }

    private void Rect(int x, int y, int w, int h, ushort color) {
        for (int yy = Math.Max(0, y); yy < Math.Min(Height, y + h); yy++)
            for (int xx = Math.Max(0, x); xx < Math.Min(Width, x + w); xx++) Pixel(xx, yy, color);
    }

    private void Line(int x0, int y0, int x1, int y1, ushort color, bool mapOnly) {
        int dx = Math.Abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
        int dy = -Math.Abs(y1 - y0), sy = y0 < y1 ? 1 : -1, err = dx + dy;
        // Reference points are local; avoid accidental unbounded loops on bad input.
        if (dx > 10000 || -dy > 10000) return;
        for (;;) {
            if (!mapOnly || y0 >= 24) Pixel(x0, y0, color);
            if (x0 == x1 && y0 == y1) break;
            int twice = 2 * err;
            if (twice >= dy) { err += dy; x0 += sx; }
            if (twice <= dx) { err += dx; y0 += sy; }
        }
    }

    private void Text(string value, int x, int y, ushort color) {
        foreach (char raw in value) {
            int ch = raw == '\u00b0' ? 248 : (raw < 256 ? raw : 63);
            for (int col = 0; col < 5; col++) {
                byte bits = font[ch * 5 + col];
                for (int row = 0; row < 8; row++) if ((bits & (1 << row)) != 0) Pixel(x + col, y + row, color);
            }
            x += 6;
        }
    }

    public void Runway(double lon1, double lat1, double lon2, double lat2) {
        PointF a = ProjectOnDisplay(lon1, lat1, 0), b = ProjectOnDisplay(lon2, lat2, 0);
        if (TiltedView) {
            MapLine(a, b, RunwayColor);
            MapLine(new PointF(a.X + 1, a.Y), new PointF(b.X + 1, b.Y), 0x4B70);
            return;
        }
        Line((int)Math.Round(a.X), (int)Math.Round(a.Y), (int)Math.Round(b.X), (int)Math.Round(b.Y), RunwayColor, true);
        Line((int)Math.Round(a.X) + 1, (int)Math.Round(a.Y), (int)Math.Round(b.X) + 1, (int)Math.Round(b.Y), RunwayColor, true);
    }

    public void WaterLine(double lon1, double lat1, double lon2, double lat2) {
        MapLine(ProjectOnDisplay(lon1, lat1, 0), ProjectOnDisplay(lon2, lat2, 0), WaterColor);
    }

    public void Navaid(string id, double longitude, double latitude) {
        PointF p = ProjectOnDisplay(longitude, latitude, 0); int x = (int)Math.Round(p.X), y = (int)Math.Round(p.Y);
        if (x < 12 || x > (TiltedView ? MapRight - 5 : 216) || y < 35 || y > 226) return;
        Line(x, y - 3, x + 3, y, NavaidColor, true); Line(x + 3, y, x, y + 3, NavaidColor, true);
        Line(x, y + 3, x - 3, y, NavaidColor, true); Line(x - 3, y, x, y - 3, NavaidColor, true);
        Text(id, x + 5, y - 9, NavaidColor);
        obstacles.Add(new Rectangle(x + 4, y - 10, id.Length * 6 + 2, 10));
    }

    private static bool InViewport(PointF p) {
        return !Single.IsNaN(p.X) && !Single.IsNaN(p.Y) && p.X >= 9 && p.X <= MapRight - 10 && p.Y >= 33 && p.Y <= 231;
    }

    public bool IsVisible(double longitude, double latitude) {
        return InViewport(Project(longitude, latitude));
    }

    public bool Add(AirspaceTarget target) {
        PointF flat = Project(target.Longitude, target.Latitude);
        if (!InViewport(flat)) return false;
        PointF p = DisplayPoint(flat, Lift(target.Altitude));
        target.Ground = flat;
        target.X = p.X; target.Y = p.Y;
        string id = String.IsNullOrWhiteSpace(target.Id) ? "UNKNOWN" : target.Id.Trim();
        target.Id = id.Length > 8 ? id.Substring(0, 8) : id;
        target.Lines = new string[] { target.Id };
        target.Color = AltitudeColor(target.Altitude);
        Targets.Add(target); return true;
    }

    private const int LabelWidth = 50, LabelHeight = 8;
    private static readonly Point[] LabelOffsets = {
        new Point(12,-11), new Point(12,4), new Point(-62,-11), new Point(-62,4),
        new Point(-25,-21), new Point(-25,13), new Point(18,-4), new Point(-68,-4),
        new Point(12,17), new Point(-62,17)
    };

    private static void Reserve(bool[] occupied, Rectangle area) {
        for (int y = Math.Max(0, area.Top); y < Math.Min(Height, area.Bottom); y++)
            for (int x = Math.Max(0, area.Left); x < Math.Min(Width, area.Right); x++)
                occupied[y * Width + x] = true;
    }

    private static bool LabelFits(bool[] occupied, Rectangle box) {
        for (int y = box.Top - 1; y <= box.Bottom; y++)
            for (int x = box.Left - 1; x <= box.Right; x++)
                if (occupied[y * Width + x]) return false;
        return true;
    }

    private void DrawLabel(bool[] occupied, AirspaceTarget target, Rectangle box) {
        Reserve(occupied, box);
        target.LabelX = box.X;
        target.LabelY = box.Y;
        LabelBounds.Add(box);
        Text(target.Lines[0], box.X + 1, box.Y, target.Color);
    }

    private void Labels() {
        layout.Prune();
        bool[] occupied = new bool[Width * Height];
        foreach (Rectangle area in obstacles) Reserve(occupied, area);
        foreach (AirspaceTarget f in Targets) {
            f.LabelX = f.LabelY = -1;
            Reserve(occupied, new Rectangle((int)f.X - 10, (int)f.Y - 10, 20, 20));
        }
        List<AirspaceTarget> ordered = new List<AirspaceTarget>(Targets);
        ordered.Sort(delegate(AirspaceTarget a, AirspaceTarget b) { return a.Y.CompareTo(b.Y); });
        DateTime now = DateTime.UtcNow;
        // Keep existing label positions first, while they still have room.
        foreach (AirspaceTarget f in ordered) {
            AirspaceLabelLayout.Anchor anchor;
            if (!layout.Anchors.TryGetValue(LabelKey(f), out anchor)) continue;
            anchor.LastSeen = now;
            Rectangle box = LabelBox(f, anchor.Dx, anchor.Dy);
            if (LabelFits(occupied, box)) DrawLabel(occupied, f, box);
        }
        foreach (AirspaceTarget f in ordered) {
            if (f.LabelX >= 0) continue;
            Rectangle best = Rectangle.Empty;
            Point bestOffset = Point.Empty;
            double nearest = Double.MaxValue;
            foreach (Point offset in LabelOffsets) {
                Rectangle box = LabelBox(f, offset.X, offset.Y);
                if (!LabelFits(occupied, box)) continue;
                double dx = box.X + box.Width / 2.0 - f.X, dy = box.Y + box.Height / 2.0 - f.Y;
                double distance = dx * dx + dy * dy;
                if (distance >= nearest) continue;
                nearest = distance;
                best = box;
                bestOffset = offset;
            }
            // Congestion can hide a callsign, never the aircraft icon.
            if (best.IsEmpty) continue;
            layout.Anchors[LabelKey(f)] = new AirspaceLabelLayout.Anchor {
                Dx = bestOffset.X, Dy = bestOffset.Y, LastSeen = now
            };
            DrawLabel(occupied, f, best);
        }
    }

    private static string LabelKey(AirspaceTarget f) {
        return String.IsNullOrWhiteSpace(f.Identity) ? f.Id : f.Identity;
    }

    private static Rectangle LabelBox(AirspaceTarget f, int dx, int dy) {
        return new Rectangle(Math.Max(2, Math.Min(MapRight - LabelWidth, (int)Math.Round(f.X) + dx)),
            Math.Max(27, Math.Min(238 - LabelHeight, (int)Math.Round(f.Y) + dy)), LabelWidth, LabelHeight);
    }

    private void AltitudeLegend() {
        // Keep a dedicated strip so neither moving labels nor reference data
        // overwrite the scale. Use the same metre-to-colour function as planes.
        const int top = 48, bottom = 216, barX = 232;
        Rect(MapRight + 1, 24, Width - MapRight - 1, Height - 24, 0);
        Line(216, 28, 216, 235, 0x2104, false);
        for (int y = top; y <= bottom; y++) {
            int altitude = (int)Math.Round((bottom - y) * 12000.0 / (bottom - top));
            Rect(barX, y, 6, 1, AltitudeColor(altitude));
        }
        Text("12k", 221, top - 12, White);
        Text("0", barX, bottom + 6, White);
    }

    private static bool ClipTrail(double p, double q, ref double enter, ref double leave) {
        if (p == 0) return q >= 0;
        double t = q / p;
        if (p < 0) { if (t > leave) return false; enter = Math.Max(enter, t); }
        else { if (t < enter) return false; leave = Math.Min(leave, t); }
        return true;
    }

    private static bool ClipMap(PointF a, PointF b, ref double enter, ref double leave) {
        double dx = b.X-a.X, dy = b.Y-a.Y;
        return ClipTrail(-dx, a.X, ref enter, ref leave) && ClipTrail(dx, MapRight-a.X, ref enter, ref leave) &&
            ClipTrail(-dy, a.Y-24, ref enter, ref leave) && ClipTrail(dy, 239-a.Y, ref enter, ref leave);
    }

    private void MapLine(PointF a, PointF b, ushort color) {
        double enter = 0, leave = 1;
        if (!ClipMap(a,b,ref enter,ref leave)) return;
        double dx = b.X-a.X, dy = b.Y-a.Y;
        Line((int)Math.Round(a.X+dx*enter), (int)Math.Round(a.Y+dy*enter),
            (int)Math.Round(a.X+dx*leave), (int)Math.Round(a.Y+dy*leave), color, true);
    }

    private static ushort TrailColor(int fromAltitude, int toAltitude, double t) {
        if (fromAltitude != Int32.MinValue && toAltitude != Int32.MinValue)
            return AltitudeColor((int)Math.Round(fromAltitude + ((double)toAltitude - fromAltitude) * t));
        // An unknown altitude stays neutral at that endpoint, without inventing
        // an altitude. Blend the display colours towards the known endpoint.
        ushort from = AltitudeColor(fromAltitude), to = AltitudeColor(toAltitude);
        int r = (int)Math.Round(((from >> 11) & 31) * (1-t) + ((to >> 11) & 31) * t);
        int g = (int)Math.Round(((from >> 5) & 63) * (1-t) + ((to >> 5) & 63) * t);
        int b = (int)Math.Round((from & 31) * (1-t) + (to & 31) * t);
        return (ushort)((r << 11) | (g << 5) | b);
    }

    // Cubic Bezier tangents use the old and new ground tracks. A missing track
    // falls back to a straight segment instead of inventing a turning direction.
    public static PointF[] TrailCurve(PointF start, PointF end, int previousTrack, int currentTrack) {
        double dx = end.X-start.X, dy = end.Y-start.Y, distance = Math.Sqrt(dx*dx+dy*dy);
        if (distance < 0.5 || previousTrack < 0 || currentTrack < 0) return new PointF[] { start, end };
        double a = previousTrack * Math.PI/180, b = currentTrack * Math.PI/180;
        double ax = Math.Sin(a), ay = -Math.Cos(a), bx = Math.Sin(b), by = -Math.Cos(b);
        // Keep a truly straight, forward flight exactly straight at pixel level.
        if (Math.Abs(ax*dy-ay*dx) < distance*1e-6 && Math.Abs(bx*dy-by*dx) < distance*1e-6 &&
            ax*dx+ay*dy > 0 && bx*dx+by*dy > 0) return new PointF[] { start, end };
        double handle = Math.Min(80, distance*0.4);
        double x1 = start.X+ax*handle, y1 = start.Y+ay*handle;
        double x2 = end.X-bx*handle, y2 = end.Y-by*handle;
        double middle = Math.Sqrt((x2-x1)*(x2-x1)+(y2-y1)*(y2-y1));
        int segments = (int)Math.Min(128, Math.Max(8, Math.Ceiling((2*handle+middle)/2)));
        PointF[] points = new PointF[segments+1];
        points[0] = start; points[segments] = end;
        for (int i = 1; i < segments; i++) {
            double t = (double)i/segments, u = 1-t;
            points[i] = new PointF((float)(u*u*u*start.X+3*u*u*t*x1+3*u*t*t*x2+t*t*t*end.X),
                (float)(u*u*u*start.Y+3*u*u*t*y1+3*u*t*t*y2+t*t*t*end.Y));
        }
        return points;
    }

    private bool TrailPiece(AirspaceTarget f, PointF previous, PointF current, double fromProgress, double toProgress) {
        double dx = current.X-previous.X, dy = current.Y-previous.Y, enter = 0, leave = 1;
        // Clip every sampled piece before rasterizing. Progress is measured
        // over the whole curve, so clipping never restarts its altitude gradient.
        if (!ClipMap(previous,current,ref enter,ref leave)) return false;
        int x0 = (int)Math.Round(Math.Max(0,Math.Min(MapRight,previous.X+dx*enter)));
        int y0 = (int)Math.Round(Math.Max(24,Math.Min(239,previous.Y+dy*enter)));
        int x1 = (int)Math.Round(Math.Max(0,Math.Min(MapRight,previous.X+dx*leave)));
        int y1 = (int)Math.Round(Math.Max(24,Math.Min(239,previous.Y+dy*leave)));
        int steps = Math.Max(Math.Abs(x1-x0), Math.Abs(y1-y0));
        for (int i = 0; i <= steps; i++) {
            double fraction = steps == 0 ? 1 : (double)i / steps;
            int x = (int)Math.Round(x0 + (x1-x0) * fraction), y = (int)Math.Round(y0 + (y1-y0) * fraction);
            double t = fromProgress + (toProgress-fromProgress) * (enter+(leave-enter)*fraction);
            if (x >= 0 && x <= MapRight && y >= 24 && y < Height)
                Pixel(x, y, TrailColor(f.PreviousAltitude, f.Altitude, t));
        }
        return true;
    }

    private void TrailEndpoint(PointF point, ushort color) {
        int x = (int)Math.Round(point.X), y = (int)Math.Round(point.Y);
        if (x >= 0 && x <= MapRight && y >= 24 && y < Height) Pixel(x,y,color);
    }

    private void Trail(AirspaceTarget f) {
        if (!f.HasPreviousPosition) return;
        PointF previous = Project(f.PreviousLongitude, f.PreviousLatitude);
        if (Single.IsNaN(previous.X) || Single.IsNaN(previous.Y) || Single.IsInfinity(previous.X) || Single.IsInfinity(previous.Y)) return;
        previous = TiltedView ? GroundTail(previous,f.PreviousTrack) : TailPoint(previous.X,previous.Y,f.PreviousTrack);
        PointF current = TiltedView ? GroundTail(f.Ground,f.Track) : TailPoint(f.X,f.Y,f.Track);
        if (!TiltedView && Math.Abs(current.X-previous.X) < 0.5 && Math.Abs(current.Y-previous.Y) < 0.5) return;
        PointF[] points = TrailCurve(previous,current,f.PreviousTrack,f.Track);
        double[] lengths = new double[points.Length];
        for (int i = 1; i < points.Length; i++) {
            double dx = points[i].X-points[i-1].X, dy = points[i].Y-points[i-1].Y;
            lengths[i] = lengths[i-1]+Math.Sqrt(dx*dx+dy*dy);
        }
        double total = lengths[lengths.Length-1];
        double fromLift = Lift(f.PreviousAltitude), toLift = Lift(f.Altitude);
        if (total < 0.5 && (!TiltedView || Math.Abs(fromLift-toLift) < 0.5)) return;
        bool drawn = false;
        PointF last = DisplayPoint(points[0],fromLift);
        double lastProgress = 0;
        for (int i = 1; i < points.Length; i++) {
            double progress = total < 0.5 ? 1 : lengths[i]/total;
            PointF next = DisplayPoint(points[i],fromLift + (toLift-fromLift)*progress);
            drawn |= TrailPiece(f,last,next,lastProgress,progress);
            last = next;
            lastProgress = progress;
        }
        if (drawn) {
            // Several subpixel pieces can touch the same endpoint pixel.
            TrailEndpoint(DisplayPoint(previous,fromLift),AltitudeColor(f.PreviousAltitude));
            TrailEndpoint(DisplayPoint(current,toLift),AltitudeColor(f.Altitude));
            TrailCount++;
        }
    }

    // The center of the tail is seven pixels behind the rotation origin.
    public static PointF TailPoint(double centerX, double centerY, int track) {
        double angle = (track < 0 ? 0 : track) * Math.PI / 180;
        return new PointF((float)(Math.Round(centerX) - Math.Sin(angle) * 7),
            (float)(Math.Round(centerY) + Math.Cos(angle) * 7));
    }

    private static PointF GroundTail(PointF ground, int track) {
        double angle = Math.Max(0, track) * Math.PI/180;
        return new PointF((float)(ground.X-7*Math.Sin(angle)), (float)(ground.Y+7*Math.Cos(angle)));
    }

    // The mesh is in local pixels: right, forward and up. Order broad
    // surfaces first, then paint the fuselage and the raised vertical fin.
    private static readonly double[,] AircraftMesh = {
        {0,9,0},{-1.55,4,0},{0,4,2.2},{1.55,4,0},{-1.2,-3,0},{0,-3,1.65},{1.2,-3,0},{0,-7,0},
        {-9.4,-2.4,0},{-8.6,-4.1,0},{9.4,-2.4,0},{8.6,-4.1,0},{-4.6,-6.5,0},{-3.9,-8,0},
        {4.6,-6.5,0},{3.9,-8,0},{0,-6,4.1},{-1.25,1.5,0},{1.25,1.5,0},{0,-4.1,1}
    };
    private static readonly int[,] AircraftFaces = {
        {17,8,9,2},{17,9,4,2},{18,10,11,0},{18,11,6,0},
        {4,12,13,2},{4,13,7,2},{6,14,15,0},{6,15,7,0},
        {0,1,2,3},{0,2,3,1},{1,4,5,3},{1,5,2,3},
        {2,5,6,1},{2,6,3,1},{4,7,5,2},{5,7,6,1},{19,7,16,3}
    };

    private static int Edge(Point a, Point b, int x, int y) { return (b.X-a.X)*(y-a.Y)-(b.Y-a.Y)*(x-a.X); }
    private void Triangle(Point a, Point b, Point c, ushort color) {
        if (Edge(a,b,c.X,c.Y) == 0) {
            MapLine(a,b,color); MapLine(b,c,color); MapLine(c,a,color);
            return;
        }
        for (int y = Math.Max(24, Math.Min(a.Y,Math.Min(b.Y,c.Y))); y <= Math.Min(239, Math.Max(a.Y,Math.Max(b.Y,c.Y))); y++)
            for (int x = Math.Max(0, Math.Min(a.X,Math.Min(b.X,c.X))); x <= Math.Min(MapRight, Math.Max(a.X,Math.Max(b.X,c.X))); x++) {
                int p = Edge(a,b,x,y), q = Edge(b,c,x,y), r = Edge(c,a,x,y);
                if ((p >= 0 && q >= 0 && r >= 0) || (p <= 0 && q <= 0 && r <= 0)) Pixel(x,y,color);
            }
    }

    private static ushort Shade(ushort color, int percent) {
        int r = color >> 11, g = (color >> 5) & 63, b = color & 31;
        if (percent < 100) return (ushort)((r*percent/100 << 11) | (g*percent/100 << 5) | b*percent/100);
        int light = percent-100;
        return (ushort)(((r+(31-r)*light/100) << 11) | ((g+(63-g)*light/100) << 5) | (b+(31-b)*light/100));
    }

    private void Plane3D(AirspaceTarget f) {
        double angle = Math.Max(0,f.Track) * Math.PI/180, s = Math.Sin(angle), c = Math.Cos(angle);
        var points = new Point[AircraftMesh.GetLength(0)];
        for (int i = 0; i < points.Length; ++i) {
            double x = AircraftMesh[i,0], y = AircraftMesh[i,1], z = AircraftMesh[i,2];
            PointF p = DisplayPoint(new PointF((float)(f.Ground.X+c*x+s*y),(float)(f.Ground.Y+s*x-c*y)),Lift(f.Altitude)+z*.76);
            points[i] = new Point((int)Math.Round(p.X),(int)Math.Round(p.Y));
        }
        ushort[] shades = {Shade(f.Color,62),f.Color,Shade(f.Color,84),Shade(f.Color,124)};
        for (int i = 0; i < AircraftFaces.GetLength(0); ++i)
            Triangle(points[AircraftFaces[i,0]],points[AircraftFaces[i,1]],points[AircraftFaces[i,2]],shades[AircraftFaces[i,3]]);
        Pixel(points[7].X,points[7].Y,f.Color);
    }

    private void Plane(AirspaceTarget f) {
        double angle = (f.Track < 0 ? 0 : f.Track) * Math.PI / 180, c = Math.Cos(angle), s = Math.Sin(angle);
        int centerX = (int)Math.Round(f.X), centerY = (int)Math.Round(f.Y);
        for (int y = -12; y <= 12; y++) for (int x = -12; x <= 12; x++) {
            // Sample both sides at the same distance from the mask's centerline.
            int sx = (int)Math.Floor(Math.Abs(c * x + s * y) + 7.5);
            // Keep mirrored samples on the same row at floating-point boundaries.
            int sy = (int)Math.Floor(-s * x + c * y + 8 + 1e-9);
            if (sx >= 0 && sx < 16 && sy >= 0 && sy < 16 && (plane[sy] & (1 << (15 - sx))) != 0)
                if (centerY + y >= 24) Pixel(centerX + x, centerY + y, f.Color);
        }
    }

    public void Finish(string region, string mode, int ageSeconds, int total, double spanKm) {
        Finish(region, mode, ageSeconds, total, spanKm, -1);
    }

    public void Finish(string region, string mode, int ageSeconds, int total, double spanKm, int remainingCredits) {
        TrailCount = 0;
        if (ShowTrails) foreach (AirspaceTarget f in Targets) Trail(f);
        Labels();
        if (TiltedView) {
            var ordered = new List<AirspaceTarget>(Targets);
            ordered.Sort((a,b) => (CameraDepth(a.Ground)+Lift(a.Altitude)).CompareTo(CameraDepth(b.Ground)+Lift(b.Altitude)));
            foreach (AirspaceTarget f in ordered) Plane3D(f);
        } else foreach (AirspaceTarget f in Targets) Plane(f);
        if (Targets.Count == 0) Text(mode == "ERR" ? "FETCH FAILED" : "NO ADS-B DATA", 70, 110, Gray);
        AltitudeLegend();
        Rect(0, 0, 240, 24, 0); Line(0, 23, 239, 23, 0x528A, false);
        string shortRegion = region == "SHANGHAI" ? "SHA" : region.Length > 4 ? region.Substring(0, 4) : region;
        Text(shortRegion, 4, 8, White);
        string count = Targets.Count == total ? Targets.Count + "AC" : Targets.Count + "/" + Math.Min(total, 999);
        Text(count, 35, 8, White);
        double scaleKm = 0.5;
        foreach (int candidate in new[] { 1, 2, 5, 10, 20, 50, 100 })
            if (candidate <= spanKm / 10) scaleKm = candidate;
        int length = (int)Math.Round(scaleKm * 232 / spanKm * (TiltedView ? 0.83 : 1));
        Line(73, 8, 73, 14, White, false); Line(73, 14, 73 + length, 14, White, false); Line(73 + length, 14, 73 + length, 8, White, false);
        Text(scaleKm.ToString("0.#", System.Globalization.CultureInfo.InvariantCulture) + "km", 100, 8, White);
        string status = mode == "DEMO" ? "D+" + ageSeconds + "s" : mode == "LIVE" ? "L " + Math.Min(ageSeconds, 9999) + "s" : mode == "ERR" ? "ERR" : "OLD" + Math.Min(ageSeconds, 9999) + "s";
        Text(status, 130, 8, Gray);
        string quota = remainingCredits < 0 ? "Q--" : remainingCredits > 9999 ? "Q9k+" : "Q" + remainingCredits;
        Text(quota, 180, 8, remainingCredits == 0 ? AltitudeColor(0) : Gray);
        int northX = TiltedView ? 224 : 226;
        Text("N", 224, 2, White); Line(226, 20, northX, 12, White, false);
        Line(northX-3, 15, northX, 12, White, false); Line(northX, 12, northX+3, TiltedView ? 14 : 15, White, false);
    }

    public byte[] Raw() {
        byte[] raw = new byte[FrameBytes];
        for (int i = 0; i < pixels.Length; i++) { raw[i * 2] = (byte)(pixels[i] & 255); raw[i * 2 + 1] = (byte)(pixels[i] >> 8); }
        return raw;
    }

    public void SavePng(string path) {
        using (Bitmap bitmap = new Bitmap(Width, Height)) {
            for (int y = 0; y < Height; y++) for (int x = 0; x < Width; x++) {
                int p = pixels[y * Width + x], r = (p >> 11) & 31, g = (p >> 5) & 63, b = p & 31;
                bitmap.SetPixel(x, y, Color.FromArgb((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)));
            }
            bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
    }

    public static uint Crc32(byte[] data) {
        return Crc32(data, 0, data.Length);
    }

    private static uint Crc32(byte[] data, int offset, int length) {
        uint crc = 0xFFFFFFFF;
        for (int at = offset; at < offset + length; at++) {
            crc ^= data[at];
            for (int bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xEDB88320u : 0);
        }
        return crc ^ 0xFFFFFFFF;
    }

    public static byte[] Packet(byte[] raw, uint sequence) {
        if (raw.Length != FrameBytes) throw new ArgumentException("Frame must be 240x240 RGB565");
        using (MemoryStream stream = new MemoryStream()) using (BinaryWriter writer = new BinaryWriter(stream)) {
            writer.Write(new byte[] { 73,80,83,50 }); writer.Write((uint)raw.Length); writer.Write(sequence); writer.Write(Crc32(raw)); writer.Write(raw); return stream.ToArray();
        }
    }

    private static void WriteAscii(BinaryWriter writer, string value, int width) {
        value = value ?? "";
        for (int i = 0; i < width; i++) {
            char ch = i < value.Length ? value[i] : '\0';
            writer.Write(ch == 0 || (ch >= 32 && ch < 127) ? (byte)ch : (byte)'?');
        }
    }

    private static void WritePosition(BinaryWriter writer, double lon, double lat) {
        writer.Write(checked((int)Math.Round(lon * 1000000)));
        writer.Write(checked((int)Math.Round(lat * 1000000)));
    }

    private static short WireAltitude(int altitude) {
        return altitude == Int32.MinValue ? Int16.MinValue :
            (short)Math.Max(Int16.MinValue + 1, Math.Min(Int16.MaxValue, altitude));
    }

    private static uint SceneIdentity(AirspaceTarget target) {
        uint id;
        if (UInt32.TryParse(target.Identity, System.Globalization.NumberStyles.HexNumber,
            System.Globalization.CultureInfo.InvariantCulture, out id) && id < 0x1000000u) return id;
        unchecked {
            uint hash = 2166136261u;
            foreach (char ch in target.Identity ?? target.Id ?? "UNKNOWN") hash = (hash ^ ch) * 16777619u;
            return hash | 0x80000000u;
        }
    }

    // IPS4 sends geographic inputs. The display projects and renders them.
    public static byte[] ScenePacket(uint sequence, string region, double lon, double lat, int span,
            string mode, int ageMs, bool forceOld, int credits, bool trails, double[][] runways,
            AirspaceSceneNavaid[] navaids, AirspaceTarget[] targets) {
        return ScenePacket(sequence,region,lon,lat,span,mode,ageMs,forceOld,credits,trails,runways,navaids,targets,false,null);
    }

    public static byte[] ScenePacket(uint sequence, string region, double lon, double lat, int span,
            string mode, int ageMs, bool forceOld, int credits, bool trails, double[][] runways,
            AirspaceSceneNavaid[] navaids, AirspaceTarget[] targets, bool tilted, double[][] waterLines) {
        int waterCount = waterLines == null ? 0 : waterLines.Length;
        bool topDownWater = !tilted && waterCount != 0;
        int waterBytes = (tilted || topDownWater) ? checked(2 + 16 * waterCount) : 0;
        int payloadBytes = checked(32 + 16 * runways.Length + 12 * navaids.Length + 36 * targets.Length + waterBytes);
        using (MemoryStream stream = new MemoryStream(16 + payloadBytes))
        using (BinaryWriter writer = new BinaryWriter(stream)) {
            writer.Write(new byte[] { (byte)'I', (byte)'P', (byte)'S', (byte)'4' });
            writer.Write((uint)payloadBytes);
            writer.Write(sequence);
            writer.Write(0u); // CRC, written once the payload is complete.
            WriteAscii(writer, region == "SHANGHAI" ? "SHA" : region, 4);
            WritePosition(writer, lon, lat);
            writer.Write((ushort)span);
            writer.Write((byte)(mode == "DEMO" ? 0 : mode == "ERR" ? 2 : 1));
            writer.Write((byte)((trails ? 1 : 0) | (forceOld ? 2 : 0) | (tilted ? 4 : 0) | (topDownWater ? 8 : 0)));
            writer.Write(Math.Max(0, Math.Min(9999999, ageMs)));
            writer.Write(credits);
            writer.Write(checked((ushort)runways.Length));
            writer.Write(checked((ushort)navaids.Length));
            writer.Write((uint)targets.Length);
            foreach (double[] runway in runways) {
                WritePosition(writer, runway[0], runway[1]);
                WritePosition(writer, runway[2], runway[3]);
            }
            foreach (AirspaceSceneNavaid navaid in navaids) {
                WritePosition(writer, navaid.Longitude, navaid.Latitude);
                WriteAscii(writer, navaid.Id, 4);
            }
            foreach (AirspaceTarget target in targets) {
                writer.Write(SceneIdentity(target));
                WriteAscii(writer, String.IsNullOrWhiteSpace(target.Id) ? "UNKNOWN" : target.Id.Trim(), 8);
                WritePosition(writer, target.Longitude, target.Latitude);
                writer.Write(WireAltitude(target.Altitude));
                writer.Write((short)target.Track);
                WritePosition(writer, target.PreviousLongitude, target.PreviousLatitude);
                writer.Write(WireAltitude(target.PreviousAltitude));
                writer.Write((short)(target.HasPreviousPosition ? target.PreviousTrack : -2));
            }
            if (waterBytes != 0) {
                writer.Write(checked((ushort)waterCount));
                for (int i = 0; i < waterCount; ++i) {
                    double[] segment = waterLines[i];
                    WritePosition(writer, segment[0], segment[1]);
                    WritePosition(writer, segment[2], segment[3]);
                }
            }
            writer.Flush();
            byte[] packet = stream.ToArray();
            Buffer.BlockCopy(BitConverter.GetBytes(Crc32(packet, 16, payloadBytes)), 0, packet, 12, 4);
            return packet;
        }
    }
}
