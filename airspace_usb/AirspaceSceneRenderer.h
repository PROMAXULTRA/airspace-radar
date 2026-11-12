#pragma once

#include <Adafruit_GFX.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

namespace SceneWire {
constexpr size_t HeaderBytes = 32, RunwayBytes = 16, NavaidBytes = 12, TargetBytes = 36;
enum Mode : uint8_t { Demo, Live, Error };
constexpr uint8_t Trails = 1, ForceOld = 2, Tilted = 4, WaterLines = 8;

inline bool hasWaterTrailer(uint8_t flags) {
  return (flags & (Tilted | WaterLines)) != 0;
}

inline uint16_t u16(const uint8_t *p) {
  return uint16_t(p[0]) | uint16_t(p[1]) << 8;
}
inline uint32_t u32(const uint8_t *p) {
  return uint32_t(u16(p)) | uint32_t(u16(p + 2)) << 16;
}
inline int16_t i16(const uint8_t *p) { return static_cast<int16_t>(u16(p)); }
inline int32_t i32(const uint8_t *p) { return static_cast<int32_t>(u32(p)); }
inline bool valid(const uint8_t *data, uint32_t length) {
  if (length < HeaderBytes || data[14] > Error || u16(data + 12) < 5 || u16(data + 12) > 1000)
    return false;
  const uint64_t expected = HeaderBytes + RunwayBytes * u16(data + 24) +
      NavaidBytes * u16(data + 26) + uint64_t(TargetBytes) * u32(data + 28);
  if (!hasWaterTrailer(data[15])) return expected == length;
  if (expected + 2 > length) return false;
  return expected + 2 + RunwayBytes * u16(data + size_t(expected)) == length;
}
}

class AirspaceSceneRenderer : public Adafruit_GFX {
public:
  static constexpr int Width = 240, Height = 240, MapRight = 214, MapTop = 24;
  static constexpr int AgeX = 130, AgeY = 8, AgeWidth = 48, AgeHeight = 8;
  static constexpr uint16_t Gray = 0xAD55;

  explicit AirspaceSceneRenderer(uint16_t *pixels) : Adafruit_GFX(Width, Height), pixels(pixels) {
    setTextWrap(false);
  }

  void drawPixel(int16_t x, int16_t y, uint16_t color) override {
    if (x >= 0 && x < Width && y >= 0 && y < Height) pixels[y * Width + x] = color;
  }

  void render(const uint8_t *data, uint32_t ageSeconds) {
    using namespace SceneWire;
    const int span = u16(data + 12);
    const double lat = toRadians(i32(data + 8) / 1000000.0);
    latitudeSin = sin(lat);
    latitudeCos = cos(lat);
    longitude = toRadians(i32(data + 4) / 1000000.0);
    scale = 232.0 / span;
    const bool nextTilted = (data[15] & Tilted) != 0;
    if (nextTilted != tilted) anchorCount = 0;
    tilted = nextTilted;

    memset(pixels, 0, Width * Height * sizeof(uint16_t));
    memset(occupied, 0, sizeof(occupied));
    nextAnchorCount = 0;

    const uint8_t *runway = data + HeaderBytes;
    const uint8_t *navaid = runway + RunwayBytes * u16(data + 24);
    const uint8_t *targets = navaid + NavaidBytes * u16(data + 26);
    const uint32_t count = u32(data + 28);
    if (hasWaterTrailer(data[15])) {
      const uint8_t *water = targets + size_t(count) * TargetBytes;
      const uint16_t lines = u16(water);
      water += 2;
      for (uint16_t i = 0; i < lines; ++i, water += RunwayBytes)
        mapLine(displayPoint(project(water)), displayPoint(project(water + 8)), 0x2925);
    }
    for (; runway < navaid; runway += RunwayBytes) {
      const Point a = displayPoint(project(runway)), b = displayPoint(project(runway + 8));
      mapLine(a, b, color565(105, 193, 209));
      mapLine({a.x + 1, a.y}, {b.x + 1, b.y}, tilted ? 0x4B70 : color565(105, 193, 209));
    }
    for (; navaid < targets; navaid += NavaidBytes) drawNavaid(navaid);

    uint32_t visible = 0;
    for (uint32_t i = 0; i < count; ++i) {
      const uint8_t *target = targets + i * TargetBytes;
      const Point flat = project(target + 12);
      if (!inView(flat)) continue;
      const Point point = displayPoint(flat, lift(i16(target + 20)));
      ++visible;
      reserve(pixel(point.x) - 10, pixel(point.y) - 10, 20, 20);
      if ((data[15] & Trails) && i16(target + 34) != -2) drawTrail(target, flat);
    }

    // First reuse unobstructed positions from the previous frame, then find
    // room for other callsigns. All visible icons are drawn regardless.
    for (uint32_t i = 0; i < count; ++i) {
      const uint8_t *target = targets + i * TargetBytes;
      const uint32_t key = u32(target);
      const int saved = findAnchor(anchors, anchorCount, key);
      if (saved < 0) continue;
      const Point flat = project(target + 12);
      if (inView(flat)) placeLabel(target, displayPoint(flat, lift(i16(target + 20))), anchors[saved].offset);
    }
    for (uint32_t i = 0; i < count; ++i) {
      const uint8_t *target = targets + i * TargetBytes;
      const Point flat = project(target + 12);
      if (!inView(flat)) continue;
      const Point point = displayPoint(flat, lift(i16(target + 20)));
      if (findAnchor(nextAnchors, nextAnchorCount, u32(target)) < 0) {
        int best = -1;
        double closest = 1e9;
        for (int option = 0; option < 10; ++option) {
          int x, y;
          labelPosition(point, option, x, y);
          if (!fits(x, y)) continue;
          const double dx = x + LabelWidth / 2.0 - point.x;
          const double dy = y + LabelHeight / 2.0 - point.y;
          const double distance = dx * dx + dy * dy;
          if (distance < closest) { closest = distance; best = option; }
        }
        if (best >= 0) placeLabel(target, point, best);
      }
    }
    drawAircraft(targets, count, visible);
    anchorCount = nextAnchorCount;
    memcpy(anchors, nextAnchors, anchorCount * sizeof(Anchor));

    if (!visible) text(70, 110, data[14] == Error ? "FETCH FAILED" : "NO ADS-B DATA", Gray);
    drawLegend();
    drawTop(data, visible, span, ageSeconds);
  }

  static void ageText(char (&label)[9], uint8_t mode, bool forceOld, uint32_t seconds) {
    if (seconds > 9999) seconds = 9999;
    if (mode == SceneWire::Error) {
      strcpy(label, "ERR");
    } else {
      const char *format = mode == SceneWire::Demo ? "D+%lus" :
          forceOld || seconds > 60 ? "OLD%lus" : "L %lus";
      snprintf(label, sizeof(label), format, static_cast<unsigned long>(seconds));
    }
  }

  void drawAge(uint8_t mode, bool old, uint32_t seconds) {
    char label[9];
    ageText(label, mode, old, seconds);
    fillRect(AgeX, AgeY, AgeWidth, AgeHeight, 0);
    text(AgeX, AgeY, label, Gray);
  }

private:
  struct Point { double x, y; };
  struct Anchor { uint32_t key; uint8_t offset; };
  struct PlaneOrder { const uint8_t *target; Point flat; double depth; };
  static constexpr int LabelWidth = 50, LabelHeight = 8;
  // The screen area bounds the number of non-overlapping labels, not aircraft.
  static constexpr int MaxAnchors = Width * Height / (LabelWidth * LabelHeight);
  uint16_t *pixels;
  uint8_t occupied[Width * Height / 8];
  Anchor anchors[MaxAnchors], nextAnchors[MaxAnchors];
  int anchorCount = 0, nextAnchorCount = 0;
  bool tilted = false;
  double latitudeSin = 0, latitudeCos = 1, longitude = 0, scale = 1;

  static double toRadians(double degrees) { return degrees * 0.017453292519943295; }
  static int pixel(double value) { return int(lround(value)); }
  static int clamp(int value, int low, int high) {
    return value < low ? low : value > high ? high : value;
  }
  // Same camera as the desktop. At maximum legend altitude the lift is 42 px.
  static constexpr double CameraCos = 0.978147600734, CameraSin = 0.207911690818;
  static double lift(int altitude) { return clamp(altitude, 0, 12000) * 0.0035; }
  static double cameraDepth(Point p) { return -CameraSin * (p.x - 106.5) + CameraCos * (p.y - 132); }
  Point displayPoint(Point p, double height = 0) const {
    if (!tilted) return p;
    return {107 + 0.83 * (CameraCos * (p.x - 106.5) + CameraSin * (p.y - 132)),
            151 + 0.62 * cameraDepth(p) - height};
  }
  static uint16_t color565(int r, int g, int b) {
    return uint16_t(((r & 248) << 8) | ((g & 252) << 3) | (b >> 3));
  }
  static uint16_t altitudeColor(int altitude) {
    if (altitude == INT16_MIN) return Gray;
    static const int stops[] = {0, 1000, 3000, 6000, 9000, 12000};
    static const uint8_t rgb[][3] = {{255,152,0},{255,230,0},{120,255,50},
                                     {0,223,217},{102,140,255},{231,102,255}};
    altitude = clamp(altitude, 0, 12000);
    int i = 1;
    while (altitude > stops[i]) ++i;
    const double t = double(altitude - stops[i - 1]) / (stops[i] - stops[i - 1]);
    return color565(pixel(rgb[i-1][0] + t * (rgb[i][0] - rgb[i-1][0])),
                    pixel(rgb[i-1][1] + t * (rgb[i][1] - rgb[i-1][1])),
                    pixel(rgb[i-1][2] + t * (rgb[i][2] - rgb[i-1][2])));
  }
  static uint16_t trailColor(int from, int to, double t) {
    if (from != INT16_MIN && to != INT16_MIN)
      return altitudeColor(pixel(from + (to - from) * t));
    const uint16_t a = altitudeColor(from), b = altitudeColor(to);
    const int r = pixel(((a >> 11) & 31) * (1-t) + ((b >> 11) & 31) * t);
    const int g = pixel(((a >> 5) & 63) * (1-t) + ((b >> 5) & 63) * t);
    const int blue = pixel((a & 31) * (1-t) + (b & 31) * t);
    return uint16_t((r << 11) | (g << 5) | blue);
  }
  void text(int x, int y, const char *label, uint16_t color) {
    setTextColor(color);
    setCursor(x, y);
    print(label);
  }
  Point project(const uint8_t *coord) const {
    const double p = toRadians(SceneWire::i32(coord + 4) / 1000000.0);
    const double d = toRadians(SceneWire::i32(coord) / 1000000.0) - longitude;
    const double sp = sin(p), cp = cos(p), cd = cos(d);
    const double dot = latitudeSin * sp + latitudeCos * cp * cd;
    const double c = acos(dot < -1 ? -1 : dot > 1 ? 1 : dot);
    const double k = c < 1e-9 ? 1 : c / sin(c);
    const double factor = 6371.0088 * k * scale;
    return {120 + factor * cp * sin(d), 132 - factor * (latitudeCos * sp - latitudeSin * cp * cd)};
  }
  static bool inView(Point p) {
    return p.x >= 9 && p.x <= MapRight - 10 && p.y >= 33 && p.y <= 231;
  }
  static bool clipEdge(double p, double q, double &enter, double &leave) {
    if (p == 0) return q >= 0;
    const double t = q / p;
    if (p < 0) { if (t > leave) return false; if (t > enter) enter = t; }
    else { if (t < enter) return false; if (t < leave) leave = t; }
    return true;
  }
  static bool clip(Point a, Point b, double &enter, double &leave) {
    const double dx = b.x - a.x, dy = b.y - a.y;
    return clipEdge(-dx, a.x, enter, leave) && clipEdge(dx, MapRight-a.x, enter, leave) &&
           clipEdge(-dy, a.y-MapTop, enter, leave) && clipEdge(dy, Height-1-a.y, enter, leave);
  }
  void mapLine(Point a, Point b, uint16_t color) {
    double enter = 0, leave = 1;
    if (!clip(a, b, enter, leave)) return;
    const double dx = b.x-a.x, dy = b.y-a.y;
    drawLine(pixel(a.x+dx*enter), pixel(a.y+dy*enter),
             pixel(a.x+dx*leave), pixel(a.y+dy*leave), color);
  }
  void drawNavaid(const uint8_t *navaid) {
    const Point p = displayPoint(project(navaid));
    if (!(p.x >= 12 && p.x <= MapRight - 5 && p.y >= 35 && p.y <= 226)) return;
    const int x = pixel(p.x), y = pixel(p.y);
    const uint16_t color = color565(214, 185, 118);
    mapLine({p.x,p.y-3}, {p.x+3,p.y}, color);
    mapLine({p.x+3,p.y}, {p.x,p.y+3}, color);
    mapLine({p.x,p.y+3}, {p.x-3,p.y}, color);
    mapLine({p.x-3,p.y}, {p.x,p.y-3}, color);
    char id[5] = {};
    memcpy(id, navaid + 8, 4);
    text(x + 5, y - 9, id, color);
    reserve(x + 4, y - 10, int(strlen(id)) * 6 + 2, 10);
  }
  void reserve(int left, int top, int width, int height) {
    for (int y = clamp(top, 0, Height); y < clamp(top + height, 0, Height); ++y) {
      for (int x = clamp(left, 0, Width); x < clamp(left + width, 0, Width); ++x) {
        const int bit = y * Width + x;
        occupied[bit >> 3] |= uint8_t(1u << (bit & 7));
      }
    }
  }
  bool fits(int left, int top) const {
    for (int y = top - 1; y <= top + LabelHeight; ++y) {
      for (int x = left - 1; x <= left + LabelWidth; ++x) {
        const int bit = y * Width + x;
        if (occupied[bit >> 3] & (1u << (bit & 7))) return false;
      }
    }
    return true;
  }
  static int findAnchor(const Anchor *list, int count, uint32_t key) {
    for (int i = 0; i < count; ++i) if (list[i].key == key) return i;
    return -1;
  }
  static void labelPosition(Point point, int offset, int &x, int &y) {
    static const int8_t options[][2] = {{12,-11},{12,4},{-62,-11},{-62,4},{-25,-21},
                                       {-25,13},{18,-4},{-68,-4},{12,17},{-62,17}};
    x = clamp(pixel(point.x) + options[offset][0], 2, MapRight - LabelWidth);
    y = clamp(pixel(point.y) + options[offset][1], 27, 238 - LabelHeight);
  }
  void placeLabel(const uint8_t *target, Point point, int offset) {
    int x, y;
    labelPosition(point, offset, x, y);
    if (!fits(x, y)) return;
    char label[9] = {};
    memcpy(label, target + 4, 8);
    reserve(x, y, LabelWidth, LabelHeight);
    text(x + 1, y, label, altitudeColor(SceneWire::i16(target + 20)));
    if (nextAnchorCount < MaxAnchors)
      nextAnchors[nextAnchorCount++] = {SceneWire::u32(target), uint8_t(offset)};
  }
  void drawPlane(Point center, int track, uint16_t color) {
    // Same north-facing 16x16 silhouette as the desktop preview.
    static const uint16_t mask[16] = {384, 384, 384, 384, 960, 2016, 8184, 32766, 57735, 384, 384, 384, 960, 4080, 3504, 384};
    const double angle = toRadians(track < 0 ? 0 : track);
    const double c = cos(angle), s = sin(angle);
    const int cx = pixel(center.x), cy = pixel(center.y);
    for (int y = -12; y <= 12; ++y) {
      for (int x = -12; x <= 12; ++x) {
        // The mask's centerline is between columns 7 and 8. Sample both sides
        // at the same distance from it so the fuselage rotates around its axis.
        const int sx = int(floor(fabs(c*x+s*y)+7.5));
        // Keep mirrored samples on the same row at floating-point boundaries.
        const int sy = int(floor(-s*x+c*y+8+1e-9));
        if (sx >= 0 && sx < 16 && sy >= 0 && sy < 16 &&
            (mask[sy] & (1u << (15-sx))) && cy+y >= MapTop)
          drawPixel(cx+x, cy+y, color);
      }
    }
  }
  static uint16_t shade(uint16_t color, int percent) {
    const int r = color >> 11, g = (color >> 5) & 63, b = color & 31;
    if (percent < 100) return uint16_t((r*percent/100 << 11) | (g*percent/100 << 5) | b*percent/100);
    const int light = percent-100;
    return uint16_t(((r+(31-r)*light/100) << 11) | ((g+(63-g)*light/100) << 5) | (b+(31-b)*light/100));
  }
  void drawPlane3D(Point flat, int track, int altitude, uint16_t color) {
    // Local right, forward and up coordinates. Large faces are painted before
    // the fuselage and vertical fin, using four shades of the altitude colour.
    static constexpr float mesh[][3] = {
      {0,9,0},{-1.55,4,0},{0,4,2.2},{1.55,4,0},{-1.2,-3,0},{0,-3,1.65},{1.2,-3,0},{0,-7,0},
      {-9.4,-2.4,0},{-8.6,-4.1,0},{9.4,-2.4,0},{8.6,-4.1,0},{-4.6,-6.5,0},{-3.9,-8,0},
      {4.6,-6.5,0},{3.9,-8,0},{0,-6,4.1},{-1.25,1.5,0},{1.25,1.5,0},{0,-4.1,1}
    };
    static constexpr uint8_t faces[][4] = {
      {17,8,9,2},{17,9,4,2},{18,10,11,0},{18,11,6,0},
      {4,12,13,2},{4,13,7,2},{6,14,15,0},{6,15,7,0},
      {0,1,2,3},{0,2,3,1},{1,4,5,3},{1,5,2,3},
      {2,5,6,1},{2,6,3,1},{4,7,5,2},{5,7,6,1},{19,7,16,3}
    };
    struct Vertex { int16_t x, y; } vertices[sizeof(mesh)/sizeof(mesh[0])];
    const double angle = toRadians(max(0,track)), s = sin(angle), c = cos(angle);
    for (size_t i = 0; i < sizeof(mesh)/sizeof(mesh[0]); ++i) {
      const double x = mesh[i][0], y = mesh[i][1], z = mesh[i][2];
      const Point point = displayPoint({flat.x+c*x+s*y,flat.y+s*x-c*y},lift(altitude)+z*.76);
      vertices[i] = {int16_t(pixel(point.x)),int16_t(pixel(point.y))};
    }
    const uint16_t colors[] = {shade(color,62),color,shade(color,84),shade(color,124)};
    for (const auto &face : faces) {
      const Vertex a = vertices[face[0]], b = vertices[face[1]], c = vertices[face[2]];
      fillTriangle(a.x,a.y,b.x,b.y,c.x,c.y,colors[face[3]]);
    }
    drawPixel(vertices[7].x,vertices[7].y,color);
  }
  void drawAircraft(const uint8_t *targets, uint32_t count, uint32_t visible) {
    if (!visible) return;
    auto *ordered = tilted ? static_cast<PlaneOrder *>(malloc(visible * sizeof(PlaneOrder))) : nullptr;
    uint32_t used = 0;
    for (uint32_t i = 0; i < count; ++i) {
      const uint8_t *target = targets + i * SceneWire::TargetBytes;
      const Point flat = project(target + 12);
      if (!inView(flat)) continue;
      const int track = SceneWire::i16(target + 22), altitude = SceneWire::i16(target + 20);
      if (ordered) ordered[used++] = {target,flat,cameraDepth(flat)+lift(altitude)};
      else if (tilted) drawPlane3D(flat,track,altitude,altitudeColor(altitude));
      else drawPlane(flat,track,altitudeColor(altitude));
    }
    if (!ordered) return;
    qsort(ordered,used,sizeof(PlaneOrder),[](const void *left, const void *right) {
      const auto &a = *static_cast<const PlaneOrder *>(left), &b = *static_cast<const PlaneOrder *>(right);
      if (a.depth != b.depth) return a.depth < b.depth ? -1 : 1;
      return a.target < b.target ? -1 : a.target > b.target ? 1 : 0;
    });
    for (uint32_t i = 0; i < used; ++i) {
      const uint8_t *target = ordered[i].target;
      const int altitude = SceneWire::i16(target+20);
      drawPlane3D(ordered[i].flat,SceneWire::i16(target+22),altitude,altitudeColor(altitude));
    }
    free(ordered);
  }
  Point tail(Point center, int track) const {
    const double a = toRadians(track < 0 ? 0 : track);
    return {(tilted ? center.x : pixel(center.x))-sin(a)*7, (tilted ? center.y : pixel(center.y))+cos(a)*7};
  }
  void trailEndpoint(Point p, int altitude) {
    const int x = pixel(p.x), y = pixel(p.y);
    if (x >= 0 && x <= MapRight && y >= MapTop && y < Height) drawPixel(x,y,altitudeColor(altitude));
  }
  void trailPiece(Point a, Point b, int from, int to, double t0, double t1) {
    double enter = 0, leave = 1;
    if (!clip(a, b, enter, leave)) return;
    const double dx = b.x-a.x, dy = b.y-a.y;
    const int x0 = pixel(a.x+dx*enter), y0 = pixel(a.y+dy*enter);
    const int x1 = pixel(a.x+dx*leave), y1 = pixel(a.y+dy*leave);
    const int steps = max(abs(x1-x0), abs(y1-y0));
    for (int i = 0; i <= steps; ++i) {
      const double f = steps ? double(i)/steps : 1;
      drawPixel(pixel(x0+(x1-x0)*f), pixel(y0+(y1-y0)*f),
                trailColor(from, to, t0 + (t1-t0)*(enter+(leave-enter)*f)));
    }
  }
  void drawTrail(const uint8_t *target, Point center) {
    using SceneWire::i16;
    const int oldTrack = i16(target + 34), track = i16(target + 22);
    const int from = i16(target + 32), to = i16(target + 20);
    const Point a = tail(project(target + 24), oldTrack), b = tail(center, track);
    const double dx = b.x-a.x, dy = b.y-a.y, distance = hypot(dx, dy);
    const double oldLift = lift(from), newLift = lift(to);
    const Point start = displayPoint(a,oldLift), end = displayPoint(b,newLift);
    if (!(hypot(end.x-start.x,end.y-start.y) >= 0.5) && !(distance >= 0.5)) return;
    if (distance < 0.5 || oldTrack < 0 || track < 0) {
      trailPiece(start,end,from,to,0,1);
      trailEndpoint(start,from); trailEndpoint(end,to);
      return;
    }
    const double p = toRadians(oldTrack), q = toRadians(track), handle = min(80.0, distance*0.4);
    const Point c = {a.x+sin(p)*handle, a.y-cos(p)*handle};
    const Point d = {b.x-sin(q)*handle, b.y+cos(q)*handle};
    const int segments = clamp(int(ceil((2*handle+hypot(d.x-c.x, d.y-c.y))/2)), 8, 64);
    Point samples[65];
    double lengths[65];
    samples[0] = a;
    lengths[0] = 0;
    for (int i = 1; i <= segments; ++i) {
      const double t = double(i)/segments, u = 1-t;
      samples[i] = {u*u*u*a.x+3*u*u*t*c.x+3*u*t*t*d.x+t*t*t*b.x,
                    u*u*u*a.y+3*u*u*t*c.y+3*u*t*t*d.y+t*t*t*b.y};
      lengths[i] = lengths[i-1] + hypot(samples[i].x-samples[i-1].x, samples[i].y-samples[i-1].y);
    }
    const double length = lengths[segments];
    if (length < 0.5) return;
    Point last = start;
    double lastProgress = 0;
    for (int i = 1; i <= segments; ++i) {
      const double progress = lengths[i]/length;
      const Point next = displayPoint(samples[i],oldLift+(newLift-oldLift)*progress);
      trailPiece(last,next,from,to,lastProgress,progress);
      last = next;
      lastProgress = progress;
    }
    trailEndpoint(start,from); trailEndpoint(end,to);
  }
  void drawLegend() {
    constexpr int top = 48, bottom = 216;
    drawFastVLine(216, 28, 208, 0x2104);
    for (int y = top; y <= bottom; ++y)
      drawFastHLine(232, y, 6, altitudeColor(pixel((bottom - y) * 12000.0 / (bottom - top))));
    text(221, 36, "12k", 0xFFFF);
    text(232, 222, "0", 0xFFFF);
  }
  void drawTop(const uint8_t *data, uint32_t visible, int span, uint32_t seconds) {
    fillRect(0, 0, Width, MapTop, 0);
    drawFastHLine(0, 23, Width, 0x528A);
    char region[5] = {};
    memcpy(region, data, 4);
    text(4, 8, region, 0xFFFF);
    char count[16];
    snprintf(count, sizeof(count), "%luAC", static_cast<unsigned long>(visible));
    text(35, 8, count, 0xFFFF);
    double km = 0.5;
    static const int steps[] = {1, 2, 5, 10, 20, 50, 100};
    for (int candidate : steps) if (candidate <= span / 10.0) km = candidate;
    const int width = pixel(km * scale * (tilted ? 0.83 : 1));
    drawFastVLine(73, 8, 7, 0xFFFF);
    drawFastHLine(73, 14, width + 1, 0xFFFF);
    drawFastVLine(73 + width, 8, 7, 0xFFFF);
    char scaleText[8];
    if (km == 0.5) strcpy(scaleText, "0.5km");
    else snprintf(scaleText, sizeof(scaleText), "%dkm", int(km));
    text(100, 8, scaleText, 0xFFFF);
    drawAge(data[14], data[15] & SceneWire::ForceOld, seconds);
    const int32_t credits = SceneWire::i32(data + 20);
    char quota[8];
    if (credits < 0) strcpy(quota, "Q--");
    else if (credits > 9999) strcpy(quota, "Q9k+");
    else snprintf(quota, sizeof(quota), "Q%ld", static_cast<long>(credits));
    text(180, 8, quota, credits == 0 ? altitudeColor(0) : Gray);
    text(224, 2, "N", 0xFFFF);
    const int northX = tilted ? 224 : 226;
    drawLine(226,20,northX,12,0xFFFF);
    drawLine(northX-3,15,northX,12,0xFFFF);
    drawLine(northX,12,northX+3,tilted ? 14 : 15,0xFFFF);
  }
};
