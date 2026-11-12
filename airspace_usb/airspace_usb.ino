// XIAO ESP32C6 + ST7789 240x240: render ADS-B scene data locally over USB CDC.
// Board: XIAO_ESP32C6, USB CDC On Boot: Enabled.
#include <Arduino.h>
#include <SPI.h>
#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>
#include <esp_timer.h>
#include "AirspaceSceneRenderer.h"

#if !ARDUINO_USB_CDC_ON_BOOT
#error "Enable Tools > USB CDC On Boot before compiling the USB display sketch."
#endif

constexpr int8_t TFT_SCK = 19;   // D8
constexpr int8_t TFT_MOSI = 18;  // D10
constexpr int8_t TFT_RST = 21;   // D3
constexpr int8_t TFT_DC = 2;     // D2
constexpr int8_t TFT_BL = 1;     // D1
constexpr uint8_t BACKLIGHT_ON = HIGH;
constexpr uint8_t TFT_SPI_MODE = SPI_MODE3;
constexpr uint32_t FRAME_BYTES = 240UL * 240UL * 2;
constexpr uint32_t RECEIVE_TIMEOUT_MS = 5000;
constexpr uint32_t CHUNK_BYTES = 1024;  // Stop-and-wait: below the RX queue size.
constexpr uint32_t MAP_SWEEP_MS = 2000;
constexpr int MAP_STRIP_ROWS = 3;
Adafruit_ST7789 tft(&SPI, -1, TFT_DC, TFT_RST);

// LCD keeps the previous picture visible while this buffer receives a new one.
// Payload: 57,600 RGB565 words in little-endian order (no pre-swapping).
alignas(4) uint16_t frame[240 * 240];
alignas(4) uint16_t displayedFrame[240 * 240];
AirspaceSceneRenderer renderer(frame);
bool haveDisplayedFrame = false;
uint32_t updatedPixels = 0;
uint16_t updatedWindows = 0;
uint32_t updateMicros = 0;
uint8_t header[16];
size_t headerUsed = 0;
uint64_t headerReceivedUs = 0;
uint8_t *scenePayload = nullptr;
uint32_t payloadLength = 0;
uint32_t payloadUsed = 0;
uint32_t lastByteMillis = 0;
bool receiving = false;
bool localAgeEnabled = false;
bool forceOld = false;
uint32_t ageAtReceiptMs = 0;
uint64_t ageAnchorUs = 0;
uint32_t drawnAgeSeconds = 0;

uint32_t readLE32(const uint8_t *p) {
  return uint32_t(p[0]) | (uint32_t(p[1]) << 8) |
         (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}

uint32_t extendCrc32(uint32_t crc, const uint8_t *data, size_t count) {
  while (count--) {
    crc ^= *data++;
    for (uint8_t bit = 0; bit < 8; ++bit) {
      crc = (crc >> 1) ^ ((crc & 1) ? 0xEDB88320UL : 0);
    }
  }
  return crc;
}

void backlight(bool on) {
  digitalWrite(TFT_BL, on ? BACKLIGHT_ON : (BACKLIGHT_ON == HIGH ? LOW : HIGH));
}

void resetReceiver() {
  free(scenePayload);
  scenePayload = nullptr;
  headerUsed = 0;
  payloadLength = 0;
  payloadUsed = 0;
  receiving = false;
}

uint32_t dataAgeSeconds() {
  const uint64_t elapsedMs = (uint64_t(esp_timer_get_time()) - ageAnchorUs) / 1000;
  const uint64_t seconds = (ageAtReceiptMs + elapsedMs) / 1000;
  return seconds > 9999 ? 9999 : uint32_t(seconds);
}

void renderScene() {
  localAgeEnabled = scenePayload[14] == SceneWire::Live;
  forceOld = (scenePayload[15] & SceneWire::ForceOld) != 0;
  ageAtReceiptMs = SceneWire::u32(scenePayload + 16);
  ageAnchorUs = headerReceivedUs;
  drawnAgeSeconds = dataAgeSeconds();
  renderer.render(scenePayload, drawnAgeSeconds);
}

void updateLocalAge() {
  if (!localAgeEnabled || (receiving && !scenePayload)) return;
  const uint32_t seconds = dataAgeSeconds();
  if (seconds == drawnAgeSeconds) return;
  drawnAgeSeconds = seconds;
  renderer.drawAge(SceneWire::Live, forceOld, seconds);
  using Scene = AirspaceSceneRenderer;
  tft.startWrite();
  tft.setAddrWindow(Scene::AgeX, Scene::AgeY, Scene::AgeWidth, Scene::AgeHeight);
  for (int row = 0; row < Scene::AgeHeight; ++row) {
    const size_t at = (Scene::AgeY + row) * Scene::Width + Scene::AgeX;
    tft.writePixels(frame + at, Scene::AgeWidth, true, false);
    memcpy(displayedFrame + at, frame + at, Scene::AgeWidth * sizeof(uint16_t));
  }
  tft.endWrite();
}

void writeChangedRows(int y, int rows) {
  constexpr int width = AirspaceSceneRenderer::Width;
  const size_t offset = y * width;
  const size_t pixels = rows * width;
  const size_t bytes = pixels * sizeof(uint16_t);
  if (memcmp(frame + offset, displayedFrame + offset, bytes) == 0) return;

  tft.startWrite();
  tft.setAddrWindow(0, y, width, rows);
  tft.writePixels(frame + offset, pixels, true, false);
  tft.endWrite();
  memcpy(displayedFrame + offset, frame + offset, bytes);
  updatedPixels += pixels;
  ++updatedWindows;
}

void sweepMap() {
  using Scene = AirspaceSceneRenderer;
  writeChangedRows(0, Scene::MapTop);
  constexpr int mapRows = Scene::Height - Scene::MapTop;
  const size_t mapStart = Scene::MapTop * Scene::Width;
  if (memcmp(frame + mapStart, displayedFrame + mapStart, mapRows * Scene::Width * sizeof(uint16_t)) == 0)
    return;

  const uint32_t started = millis();
  for (int y = Scene::MapTop; y < Scene::Height; y += MAP_STRIP_ROWS) {
    const int rows = min(MAP_STRIP_ROWS, Scene::Height - y);
    const uint32_t due = (y + rows - Scene::MapTop) * MAP_SWEEP_MS / mapRows;
    // Absolute deadlines keep SPI writes from accumulating extra time.
    const uint32_t elapsed = millis() - started;
    if (elapsed < due) delay(due - elapsed);
    writeChangedRows(y, rows);
    updateLocalAge();
  }
}

void showFrame(bool scene) {
  const uint32_t began = micros();
  updatedPixels = 0;
  updatedWindows = 0;
  if (!haveDisplayedFrame) {
    tft.startWrite();
    tft.setAddrWindow(0, 0, 240, 240);
    tft.writePixels(frame, 240UL * 240UL, true, false);
    tft.endWrite();
    memcpy(displayedFrame, frame, sizeof(frame));
    haveDisplayedFrame = true;
    updatedPixels = 240UL * 240UL;
    updatedWindows = 1;
  } else if (scene) {
    sweepMap();
  } else {
    // Exact comparisons: no hash collisions and no partial unverified frames.
    // A changed tile includes both the old and new locations of moving labels.
    constexpr uint16_t TILE = 16;
    bool writing = false;
    for (uint16_t y = 0; y < 240; y += TILE) {
      uint16_t dirty = 0;
      for (uint16_t tile = 0; tile < 15; ++tile) {
        for (uint16_t row = 0; row < TILE; ++row) {
          const size_t at = (y + row) * 240 + tile * TILE;
          if (memcmp(frame + at, displayedFrame + at, TILE * sizeof(uint16_t)) != 0) {
            dirty |= uint16_t(1U << tile);
            break;
          }
        }
      }
      // Merge adjacent changed tiles into one rectangular SPI window.
      for (uint16_t tile = 0; tile < 15;) {
        if (!(dirty & (1U << tile))) { ++tile; continue; }
        const uint16_t first = tile;
        while (tile < 15 && (dirty & (1U << tile))) ++tile;
        const uint16_t x = first * TILE;
        const uint16_t width = (tile - first) * TILE;
        if (!writing) { tft.startWrite(); writing = true; }
        tft.setAddrWindow(x, y, width, TILE);
        for (uint16_t row = 0; row < TILE; ++row) {
          const size_t at = (y + row) * 240 + x;
          tft.writePixels(frame + at, width, true, false);
          memcpy(displayedFrame + at, frame + at, width * sizeof(uint16_t));
        }
        updatedPixels += uint32_t(width) * TILE;
        ++updatedWindows;
      }
    }
    if (writing) tft.endWrite();
  }
  // Backlight stays on. Identical frames perform no LCD writes at all.
  updateMicros = micros() - began;
}

void receiveFrames() {
  static const uint8_t prefix[] = {'I', 'P', 'S'};
  if ((headerUsed || receiving) && millis() - lastByteMillis > RECEIVE_TIMEOUT_MS) {
    const uint32_t sequence = headerUsed == sizeof(header) ? readLE32(header + 8) : 0;
    Serial.printf("ERR TIMEOUT %lu %lu/%lu\n", static_cast<unsigned long>(sequence),
                  static_cast<unsigned long>(payloadUsed), static_cast<unsigned long>(payloadLength));
    resetReceiver();
  }
  while (Serial.available()) {
    lastByteMillis = millis();
    if (!receiving) {
      const int value = Serial.read();
      if (value < 0) break;
      const uint8_t next = uint8_t(value);
      if (headerUsed < sizeof(prefix)) {
        if (next == prefix[headerUsed]) {
          header[headerUsed++] = next;
        } else {
          headerUsed = (next == prefix[0]) ? 1 : 0;
          if (headerUsed) header[0] = next;
        }
      } else if (headerUsed == sizeof(prefix)) {
        if (next == '2' || next == '4') {
          header[headerUsed++] = next;
        } else {
          resetReceiver();
          if (next == '?') Serial.println("CAP IPS4");
          if (next == 'T') Serial.println("CAP IPS4 TILT");
          if (next == 'W') Serial.println("CAP IPS4 WATER");
          if (next == prefix[0]) header[headerUsed++] = next;
        }
      } else {
        header[headerUsed++] = next;
        if (headerUsed == sizeof(header)) {
          const bool scene = header[3] == '4';
          payloadLength = readLE32(header + 4);
          if ((scene && payloadLength < SceneWire::HeaderBytes) ||
              (!scene && payloadLength != FRAME_BYTES)) {
            Serial.println("ERR SIZE");
            resetReceiver();
          } else if (scene && !(scenePayload = static_cast<uint8_t *>(malloc(payloadLength)))) {
            Serial.println("ERR SCENE MEMORY");
            resetReceiver();
          } else {
            headerReceivedUs = esp_timer_get_time();
            receiving = true;
            payloadUsed = 0;
            Serial.printf("READY %lu %lu\n", static_cast<unsigned long>(readLE32(header + 8)),
                          static_cast<unsigned long>(CHUNK_BYTES));
          }
        }
      }
    } else {
      const uint32_t toBoundary = CHUNK_BYTES - (payloadUsed % CHUNK_BYTES);
      const size_t wanted = min(size_t(Serial.available()),
                                min(size_t(payloadLength - payloadUsed), size_t(toBoundary)));
      uint8_t *payload = scenePayload ? scenePayload : reinterpret_cast<uint8_t *>(frame);
      const size_t got = Serial.read(payload + payloadUsed, wanted);
      if (!got) break;
      payloadUsed += got;
      if (payloadUsed == payloadLength) {
        const uint32_t sequence = readLE32(header + 8);
        const uint32_t crc = extendCrc32(0xFFFFFFFFu, payload, payloadLength) ^ 0xFFFFFFFFu;
        if (crc != readLE32(header + 12)) {
          Serial.printf("ERR CRC %lu\n", static_cast<unsigned long>(sequence));
        } else if (scenePayload && !SceneWire::valid(scenePayload, payloadLength)) {
          Serial.printf("ERR SCENE %lu\n", static_cast<unsigned long>(sequence));
        } else {
          const bool scene = scenePayload != nullptr;
          if (scene) renderScene();
          else localAgeEnabled = false;
          showFrame(scene);
          Serial.printf("DRAW %lu %lu %u %lu %u %u\n", static_cast<unsigned long>(sequence),
                        static_cast<unsigned long>(updatedPixels), static_cast<unsigned int>(updatedWindows),
                        static_cast<unsigned long>(updateMicros), ESP.getFreeHeap(), ESP.getMinFreeHeap());
          Serial.printf("OK %lu\n", static_cast<unsigned long>(sequence));
        }
        resetReceiver();
      } else if (payloadUsed % CHUNK_BYTES == 0) {
        Serial.printf("CHUNK %lu %lu\n", static_cast<unsigned long>(readLE32(header + 8)),
                      static_cast<unsigned long>(payloadUsed));
      }
    }
  }
}

void setup() {
  pinMode(TFT_BL, OUTPUT);
  backlight(false);
  Serial.setRxBufferSize(8192);
  Serial.begin(115200);
  SPI.begin(TFT_SCK, -1, TFT_MOSI, -1);
  tft.init(240, 240, TFT_SPI_MODE);
  tft.setSPISpeed(10000000);
  tft.setRotation(2);
  tft.invertDisplay(true);
  tft.fillScreen(ST77XX_BLACK);
  tft.setTextWrap(false);
  tft.setTextSize(2);
  tft.setTextColor(ST77XX_WHITE);
  tft.setCursor(18, 65);
  tft.print("AIRSPACE USB");
  tft.setTextSize(1);
  tft.setCursor(28, 110);
  tft.print("Waiting for PC frames...");
  backlight(true);
  Serial.println("READY IPS4 240 240");
}

void loop() {
  receiveFrames();
  updateLocalAge();
  delay(1);
}
