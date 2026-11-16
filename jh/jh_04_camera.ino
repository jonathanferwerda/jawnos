// ---- camera: one JPEG on request, posted to the house ----------------------
// There is no viewfinder on a hat. The camera fires on jh.snap (BLE) or on a
// wake-word turn, and the frame leaves for the house. The intended destination
// is the Camera app's unclaimed-media upload, the same pool /manager/unclaimed
// lists and /manager/unclaimed/claim files onto an appointment; the exact
// route and the field names are phase-0 follow-up work, so the URL is a config
// value (jh_house_url) rather than a literal here.
//
// The XIAO ESP32S3 Sense camera connector, as Seeed's CameraWebServer example
// wires it. If a frame comes back garbled, compare this table with the board's
// schematic before changing anything else.
#define JH_CAM_PWDN    -1
#define JH_CAM_RESET   -1
#define JH_CAM_XCLK    10
#define JH_CAM_SIOD    40
#define JH_CAM_SIOC    39
#define JH_CAM_Y9      48
#define JH_CAM_Y8      11
#define JH_CAM_Y7      12
#define JH_CAM_Y6      14
#define JH_CAM_Y5      16
#define JH_CAM_Y4      18
#define JH_CAM_Y3      17
#define JH_CAM_Y2      15
#define JH_CAM_VSYNC   38
#define JH_CAM_HREF    47
#define JH_CAM_PCLK    13

static bool jh_camera_up = false;
static volatile bool jh_camera_busy = false;
static char jh_camera_error[96] = "";

static void camera_set_error(const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  vsnprintf(jh_camera_error, sizeof(jh_camera_error), fmt, args);
  va_end(args);
  jh_log("[cam] %s", jh_camera_error);
}

void camera_init() {
  if (jh_camera_up) {
    return;
  }
  camera_config_t cfg = {};
  cfg.pin_pwdn = JH_CAM_PWDN;
  cfg.pin_reset = JH_CAM_RESET;
  cfg.pin_xclk = JH_CAM_XCLK;
  cfg.pin_sccb_sda = JH_CAM_SIOD;
  cfg.pin_sccb_scl = JH_CAM_SIOC;
  cfg.pin_d7 = JH_CAM_Y9;
  cfg.pin_d6 = JH_CAM_Y8;
  cfg.pin_d5 = JH_CAM_Y7;
  cfg.pin_d4 = JH_CAM_Y6;
  cfg.pin_d3 = JH_CAM_Y5;
  cfg.pin_d2 = JH_CAM_Y4;
  cfg.pin_d1 = JH_CAM_Y3;
  cfg.pin_d0 = JH_CAM_Y2;
  cfg.pin_vsync = JH_CAM_VSYNC;
  cfg.pin_href = JH_CAM_HREF;
  cfg.pin_pclk = JH_CAM_PCLK;
  cfg.xclk_freq_hz = 20000000;
  // The camera's XCLK owns LEDC timer 0 / channel 0; the haptics take channel 1
  // (jh_07_haptics.ino) so the two never fight over a timer.
  cfg.ledc_timer = LEDC_TIMER_0;
  cfg.ledc_channel = LEDC_CHANNEL_0;
  cfg.pixel_format = PIXFORMAT_JPEG;
  // VGA is enough to identify a house or read a sign at conversational range,
  // and it keeps one frame under the multipart body a single TLS write can
  // carry without a PSRAM-sized copy.
  cfg.frame_size = FRAMESIZE_VGA;
  cfg.jpeg_quality = 12;
  cfg.fb_count = 1;
  cfg.fb_location = CAMERA_FB_IN_PSRAM;
  cfg.grab_mode = CAMERA_GRAB_LATEST;
  // The IMU owns Wire (I2C port 0) on D4/D5. Give the camera its own controller
  // (port 1) on the SCCB pins: sharing a port makes the two drivers re-route
  // each other's pins, and the camera then reports "not detected" for no
  // obvious reason.
  cfg.sccb_i2c_port = 1;
  cfg.jpeg_buffer_size = 0;

  esp_err_t err = esp_camera_init(&cfg);
  if (err != ESP_OK) {
    camera_set_error("init failed (0x%x); is the Sense camera attached?", (unsigned)err);
    jh_camera_up = false;
    return;
  }
  // A sensor that answers but is not the expected one is worth one line in the
  // boot log: a clone module with a different PID is the usual cause of a
  // picture that is all green.
  sensor_t *s = esp_camera_sensor_get();
  if (s) {
    jh_log("[cam] sensor pid=0x%02x, VGA JPEG in PSRAM", s->id.PID);
  }
  jh_camera_up = true;
  jh_camera_error[0] = '\0';
  jh_log("[cam] ready");
}

static bool camera_post_frame(const uint8_t *jpeg, size_t jlen) {
  if (!jh_house_url.length()) {
    camera_set_error("no house_url configured");
    return false;
  }
  if (WiFi.status() != WL_CONNECTED) {
    camera_set_error("wifi down");
    return false;
  }

  // multipart/form-data is what the Camera app's upload route already accepts;
  // the filename is what an unclaimed file is listed under before it is claimed.
  const char *boundary = "----JawnHatPhase0";
  String head = String("--") + boundary +
                "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"jh.jpg\"\r\n"
                "Content-Type: image/jpeg\r\n\r\n";
  String tail = String("\r\n--") + boundary + "--\r\n";
  size_t total = head.length() + jlen + tail.length();
  uint8_t *body = (uint8_t *)heap_caps_malloc(total, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (!body) {
    body = (uint8_t *)malloc(total);
  }
  if (!body) {
    camera_set_error("no %u-byte body buffer", (unsigned)total);
    return false;
  }
  memcpy(body, head.c_str(), head.length());
  memcpy(body + head.length(), jpeg, jlen);
  memcpy(body + head.length() + jlen, tail.c_str(), tail.length());

  HTTPClient http;
  bool tls = jh_house_url.startsWith("https://");
  // The secure client is scoped to this call: a fresh handshake per frame is
  // short enough at this rate, and it means a failed TLS session cannot poison
  // the next snap. Both clients stay alive until http.end().
  WiFiClientSecure secure;
  WiFiClient plain;
  bool began = false;
  if (tls) {
    secure.setCACert(HOUSE_CA_PEM);
    began = http.begin(secure, jh_house_url);
  }
  else {
    began = http.begin(plain, jh_house_url);
  }
  if (!began) {
    camera_set_error("bad url: %s", jh_house_url.c_str());
    free(body);
    return false;
  }
  http.setTimeout(8000);
  http.addHeader("Content-Type", String("multipart/form-data; boundary=") + boundary);
  if (jh_house_token.length()) {
    http.addHeader("Authorization", String("Bearer ") + jh_house_token);
  }
  int code = http.POST(body, total);
  String reply = http.getString();
  http.end();
  free(body);

  if (code >= 200 && code < 300) {
    jh_log("[cam] posted %u bytes, http %d %s", (unsigned)jlen, code,
           reply.length() ? reply.substring(0, 80).c_str() : "");
    jh_camera_error[0] = '\0';
    return true;
  }
  camera_set_error("post failed, http %d %s", code, reply.substring(0, 80).c_str());
  return false;
}

static void camera_task(void *arg) {
  (void)arg;
  if (!jh_camera_up) {
    camera_init();
  }
  if (!jh_camera_up) {
    jh_camera_busy = false;
    vTaskDelete(NULL);
    return;
  }
  camera_fb_t *fb = esp_camera_fb_get();
  if (!fb) {
    camera_set_error("capture returned no frame");
    jh_camera_busy = false;
    vTaskDelete(NULL);
    return;
  }
  camera_post_frame(fb->buf, fb->len);
  // The frame buffer belongs to the driver; give it back before the task exits
  // or the next capture has nowhere to land.
  esp_camera_fb_return(fb);
  jh_camera_busy = false;
  vTaskDelete(NULL);
}

// Start a capture off the BLE/loop thread. The HTTP client blocks for up to the
// timeout above; keeping that in its own task is what makes jh.snap feel like a
// command instead of a stall. The stack is larger than the deck's house task
// because the TLS handshake runs here.
void camera_request_snap() {
  if (jh_camera_busy) {
    camera_set_error("busy");
    return;
  }
  jh_camera_busy = true;
  if (xTaskCreatePinnedToCore(camera_task, "jh-snap", 12288, NULL, 1, NULL, 0) != pdPASS) {
    jh_camera_busy = false;
    camera_set_error("no task");
  }
}

bool camera_busy() {
  return jh_camera_busy;
}

const char *camera_last_error() {
  return jh_camera_error;
}
