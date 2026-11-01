// ---- wrist-raise wake --------------------------------------------------------
//
// The BMA423 hands over samples in m/s2 with the board remap applied: x and y
// lie in the screen plane, z points out of the screen. Reading the watch leaves
// the screen tilted toward the face: the 2026-10-09 captures settled a worn look
// around z=7.4 and an in-hand look at z=2-4.6, while a rest on a desk reads
// z>=9.2 and an arm hanging at the side z~-1. A look is a fast turn out of a
// quiet pose that then settles held inside that z window (see wristPollStep).

static void tilt_log_flush() {
  if (tilt_log_len == 0) {
    return;
  }
  appendFile(FFat, TILT_LOG_PATH, tilt_log_buf);
  tilt_log_bytes += (uint32_t)tilt_log_len;
  tilt_log_len = 0;
  tilt_log_buf[0] = '\0';
  tilt_log_flushed_at = millis();
  if (tilt_log_bytes >= TILT_LOG_MAX) {
    tiltLog = false;      // full: stop rather than fill the partition
  }
}

// A labelled line in the pose log, so a capture can interleave the screen's
// brightness and the wake events with the samples (the USB console cannot be
// used off the cable, where light sleep lives).
static void tilt_log_marker(const char *tag, long value) {
  if (!tiltLog) {
    return;
  }
  tilt_log_flush();          // keep the marker in order with the samples
  char b[72];
  int n = snprintf(b, sizeof(b), "# t=%lu %s %ld\n", (unsigned long)millis(), tag, value);
  if (n > 0) {
    appendFile(FFat, TILT_LOG_PATH, b);
    tilt_log_bytes += (uint32_t)n;
  }
}
// Every raw sample the machine is fed goes here, so an off-cable capture can be
// replayed exactly what the state machine saw.
static void tilt_log_sample(float x, float y, float z) {
  if (!tiltLog) {
    return;
  }
  int room = (int)sizeof(tilt_log_buf) - tilt_log_len - 1;
  int n = snprintf(tilt_log_buf + tilt_log_len, room, "[t] %.2f %.2f %.2f\n", x, y, z);
  if (n > 0) {
    tilt_log_len += (n < room ? n : room - 1);
  }
  if (tilt_log_len >= (int)sizeof(tilt_log_buf) - 64 || millis() - tilt_log_flushed_at > 2000) {
    tilt_log_flush();
  }
}

static bool accel_sample(float &x, float &y, float &z) {
  if (!watch.sensor) {
    return false;
  }
  AccelerometerData d;
  if (!watch.sensor->readData(d)) {
    return false;
  }
  x = d.mps2.x;
  y = d.mps2.y;
  z = d.mps2.z;
  tilt_log_sample(x, y, z);
  return true;
}


// The wrist raise as a state machine, fed by the doze loop's polling. The
// sensor's interrupt line cannot announce this (any-motion detection crashed
// the radio, see settingSensor) and a blocking check would hold the crown for
// its whole window; a sample every 100 ms rides along the loop instead (40 ms
// while the arm is doing something). Rules, replayed against the 2026-10-09
// captures:
//   * movement is the change *between samples* -- never the distance from the
//     settled pose, which stranded on a fast move and then read every still
//     sample as movement, so the machine could not arm again until the pose
//     drifted back to where it had latched (raises after a pickup were
//     invisible);
//   * a pose held still for a moment becomes the "before"; a turn of 50 deg or
//     more out of it that then settles for 200 ms with the screen off the desk
//     (z between 0.5 and 9 -- worn look ~7.4, in-hand look 2-4.6, an elbow bent
//     up to the face ~8-9, desk 9.2+, arm hanging ~-1) is a look;
//   * after a look the arm must swing 30 deg off the read pose before another
//     turn can fire, or the hand dropping back to the side counts as a look and
//     lit the screen on the way down (2026-10-10).
#define WRIST_MOVE_EPS   0.4f   // low-passed change per sample that is movement
#define WRIST_FAST_EPS   1.5f   // a real turn: sample at 40 ms again
#define WRIST_SETTLE_EPS 1.6f   // a held pose may still wobble this much
#define WRIST_REST_MS    250    // still this long: the pose becomes "before"
#define WRIST_ARM_MS     500    // still this long: a turn out of it can be a look
#define WRIST_TURN_DEG   35.0f
// The turn out of the settled pose that counts as a look. 50 was just above
// the real arm-at-side -> reading turn: the worn capture read the rest at
// (y 9.4, z 1.6) and the look at (z 7.4), only ~40 deg apart, so at 50 the
// light-sleep machine (and the doze one in that pose) never saw a turn and the
// screen stayed off (2026-10-10). 35 catches it; the look band still keeps the
// swing and the rest quiet.
// The look band. The lower bound has to sit ABOVE the "turned away" pose. Across
// two worn captures (2026-10-12) every turned-away/rest settle read z <= 4.6
// (standing away ~3.2-4.6, sitting away ~-0.2) while every read settle read
// z >= 5.7, so 5.0 splits them. Pose alone is only marginal here - the two
// sitting reads came back with opposite y signs and z 7.6 vs 5.7 - so the floor
// is set to clear the away pose without cutting off a genuine read.
#define WRIST_LOOK_ZLOW  5.0f
// The upper bound admits the way the watch is read -- brought up in front of the
// face -- which leaves the screen nearly up (measured 6.9-8.8), so it sits just
// under a flat desk (measured desk poses read 9.2-9.9).
#define WRIST_LOOK_ZHIGH 9.0f
#define WRIST_REARM_DEG  30.0f  // after a look, swing this far off it to re-arm
static bool wrist_have = false;
static bool wrist_rose = false;
static float wrist_lx = 0, wrist_ly = 0, wrist_lz = 0;     // low-passed pose
static float wrist_sx = 0, wrist_sy = 0, wrist_sz = 0;     // the settled pose
static uint32_t wrist_moved_at = 0;
static uint32_t wrist_still_since = 0;
static uint32_t wrist_last_sample = 0;
static uint32_t wrist_fast_until = 0;      // a sign of movement buys quick samples
static bool wrist_sim = false;             // tiltsim drives the machine by hand
static bool wrist_armed = false;           // a moment of stillness arms the next turn
static bool wrist_had_look = false;        // a look already fired this session
static float wrist_gx = 0, wrist_gy = 0, wrist_gz = 0;     // the pose that look was read at
// While a look's screen is up the wrist is watched: the glance is held for as
// long as the watch stays where it can be read and handed back to sleep the
// moment the arm drops (see wrist_look_monitor).
static uint32_t wrist_look_since = 0;      // when that look began
static uint32_t wrist_look_release = 0;    // when the pose last left the read pose
static uint32_t wrist_cooldown_until = 0;  // no wake right after a look is released
// A tilt wake holds the glance at most this long without a button/touch press;
// after that it sleeps even if the arm is still up (the user: "the maximum a
// tilt wakeup without a button press can keep the screen on 5 seconds").
#define WRIST_LOOK_EXTEND_MS 5000
#define WRIST_LOOK_RELEASE_MS 350          // off the read pose this long: the arm went down
#define WRIST_LOOK_RELEASE_DEG 45.0f       // this far from the read pose is "not looking"

// The angle between two gravity vectors, in degrees.
static float wrist_angle(float ax, float ay, float az, float bx, float by, float bz) {
  float dot = ax * bx + ay * by + az * bz;
  float n1 = sqrtf(ax * ax + ay * ay + az * az);
  float n2 = sqrtf(bx * bx + by * by + bz * bz);
  return (n1 > 0.1f && n2 > 0.1f) ? acosf(dot / (n1 * n2)) * 57.3f : 0.0f;
}

static void wristPollReset() {
  wrist_have = false;
  wrist_rose = false;
  wrist_armed = false;
  wrist_had_look = false;
  wrist_last_sample = 0;
  wrist_fast_until = 0;
}

static bool wristPollStep(float x, float y, float z, uint32_t now);

static bool wristPoll() {
  if (!tiltWake || wrist_sim) {
    return false;              // the preference is off (or tiltsim drives the machine itself)
  }
  if ((int32_t)(millis() - wrist_cooldown_until) < 0) {
    return false;              // the arm is still coming down from a released look
  }
  uint32_t now = millis();
  // 10 samples a second while the arm is still, 25 while it is doing
  // something: the raise itself is only half a second long
  uint32_t interval = (now < wrist_fast_until) ? 40 : 100;
  if (now - wrist_last_sample < interval) {
    return false;
  }
  wrist_last_sample = now;
  float x, y, z;
  if (!accel_sample(x, y, z)) {
    return false;
  }
  return wristPollStep(x, y, z, now);
}

static bool wristPollStep(float x, float y, float z, uint32_t now) {
  if (!wrist_have) {
    wrist_lx = x; wrist_ly = y; wrist_lz = z;
    wrist_sx = x; wrist_sy = y; wrist_sz = z;
    wrist_moved_at = now;
    wrist_have = true;
    return false;
  }
  float plx = wrist_lx, ply = wrist_ly, plz = wrist_lz;
  wrist_lx += (x - wrist_lx) * 0.35f;
  wrist_ly += (y - wrist_ly) * 0.35f;
  wrist_lz += (z - wrist_lz) * 0.35f;

  // Movement is the change *this sample*. Measuring from the settled pose
  // instead let one fast move strand it, after which every still sample read
  // as movement and the machine could never arm again (found replaying the
  // captures: armed stayed 0 through minutes on a desk and through every
  // raise that followed a pickup).
  float step = fabsf(wrist_lx - plx) + fabsf(wrist_ly - ply) + fabsf(wrist_lz - plz);
  if (step > WRIST_MOVE_EPS) {
    wrist_moved_at = now;
    if (step > WRIST_FAST_EPS) {
      wrist_fast_until = now + 2000;
    }
  }

  if (!wrist_rose) {
    if (now - wrist_moved_at > WRIST_REST_MS) {
      // settled: this pose becomes the "before" the next turn is measured from
      wrist_sx = wrist_lx; wrist_sy = wrist_ly; wrist_sz = wrist_lz;
    }
    wrist_armed = (now - wrist_moved_at > WRIST_ARM_MS);   // reported by "tilt status"
  }

  // A look is a turn out of the settled pose that then settles in the window.
  // Deliberately no stillness gate: while walking the arm never holds still, so
  // gating the turn on a moment of stillness meant a wrist raise while walking
  // was never even looked for (the user: "at a standstill it works every time,
  // walking it never lights", 2026-10-10). The window plus the 200 ms settle
  // keep the swing quiet, because the resting and swinging poses read outside
  // the window while the reading pose is inside it.
  if (!wrist_rose) {
    float angle = wrist_angle(wrist_sx, wrist_sy, wrist_sz, wrist_lx, wrist_ly, wrist_lz);
    if (angle > WRIST_TURN_DEG) {
      wrist_rose = true;
      wrist_still_since = now;
      if (tiltDbg) {
        Serial.printf("[tilt] turn %.0f deg (z=%.1f)\n", angle, wrist_lz);
      }
    }
  }

  if (wrist_rose) {
    if (step > WRIST_SETTLE_EPS) {
      wrist_still_since = now;
    }
    if (now - wrist_still_since >= 200) {
      float angle = wrist_angle(wrist_sx, wrist_sy, wrist_sz, wrist_lx, wrist_ly, wrist_lz);
      wrist_rose = false;
      // The z window is what separates a look from the watch set down, the arm
      // dropping back to the side, or a turn away from the face: the worn read
      // settled at z ~7-8.8 while every desk pose measured z >= 9.2, a hanging
      // arm z ~-1, and a turned-away wrist z ~3.2-4.6 (see WRIST_LOOK_ZLOW).
      if (wrist_lz > WRIST_LOOK_ZLOW && wrist_lz < WRIST_LOOK_ZHIGH) {
        // held where it can be read. The arm coming back down is not another
        // look, so the next one waits until the arm has swung off this pose
        // (see the arm gate above).
        wrist_armed = false;
        wrist_had_look = true;
        wrist_gx = wrist_lx; wrist_gy = wrist_ly; wrist_gz = wrist_lz;
        wrist_sx = wrist_lx; wrist_sy = wrist_ly; wrist_sz = wrist_lz;
        {
          // the trail for an off-cable miss: what the settled pose read
          char b[24];
          snprintf(b, sizeof(b), "look z=%.1f", wrist_lz);
          crumb(b);
        }
        if (tiltDbg) {
          Serial.printf("[tilt] look: turn %.0f deg z=%.1f\n", angle, wrist_lz);
        }
        return true;
      }
      {
        // the trail for an off-cable miss: what the settled pose actually read
        char b[24];
        snprintf(b, sizeof(b), "rej z=%.1f", wrist_lz);
        crumb(b);
      }
      if (tiltDbg) {
        Serial.printf("[tilt] rejected: settled turn %.0f deg z=%.1f\n", angle, wrist_lz);
      }
    }
  }
  return false;
}


// A wrist raise lights the screen for a glance. While that glance's screen is
// up, sample the wrist: keep the screen on for as long as the watch is still
// held where it can be read (the pose in the look window), and put it back to
// sleep the moment the arm drops out of it -- so the screen follows the look
// instead of sitting on a fixed timer.
static void wrist_look_monitor() {
  if (!wrist_look_watch) {
    return;
  }
  // A spoken command owns the screen. Hearing the wake phrase starts a capture,
  // and the answer is still to come - the 5 s glance (or the arm dropping) must
  // not put the watch to sleep mid-command or before the Guide has spoken. Hand
  // the glance back to the normal timeout, whose deadline loop() keeps rebasing
  // while voiceRecording/voiceAwaitingReply are set; after the answer the full
  // configured timeout starts again.
  if (voiceRecording || voiceShipping || voiceAwaitingReply
      || (voiceWakeHoldUntil && (int32_t)(millis() - voiceWakeHoldUntil) < 0)) {
    wrist_look_watch = false;
    buttonMillis = millis();
    return;
  }
  if (millis() - wrist_look_since > WRIST_LOOK_EXTEND_MS) {
    // the glance is spent: a tilt wake keeps the screen for five seconds at
    // most without a button press, even if the arm is still held up
    wrist_look_watch = false;
    Serial.println("[tilt] glance spent: screen off");
    lowPowerEnergyHandler();
    return;
  }
  static uint32_t last = 0;
  if (millis() - last < 30) {
    return;
  }
  last = millis();
  float x, y, z;
  if (!accel_sample(x, y, z)) {
    return;
  }
  // Release on how far the wrist has turned *from the pose that was read*, not
  // on the absolute window: the arm-at-side pose and the reading pose are both
  // inside the look window (~90 deg apart), so the window cannot tell them
  // apart, and the screen stayed on with the arm at the side (2026-10-10).
  if (wrist_angle(wrist_gx, wrist_gy, wrist_gz, x, y, z) < WRIST_LOOK_RELEASE_DEG) {
    wrist_look_release = 0;
    buttonMillis = millis();     // still being read: keep the glance up
  }
  else if (wrist_look_release == 0) {
    wrist_look_release = millis();
  }
  else if (millis() - wrist_look_release > WRIST_LOOK_RELEASE_MS) {
    // the arm went down: sleep now instead of waiting out the timeout, and stay
    // deaf while it finishes coming down so the tail of the drop is not read as
    // a fresh look
    wrist_look_watch = false;
    wrist_cooldown_until = millis() + 1200;
    Serial.println("[tilt] look released: screen off");
    crumb("look released");
    lowPowerEnergyHandler();
  }
}

// Raw x/y/z at ~50 Hz over USB: what the pose thresholds are tuned against.
static void tilt_dbg_stream() {
  static uint32_t last_print = 0;
  if (millis() - last_print < 20) {
    return;
  }
  last_print = millis();
  float x, y, z;
  if (accel_sample(x, y, z)) {
    Serial.printf("[t] %.2f %.2f %.2f\n", x, y, z);
  }
}

// The USB console: "tilt on|off" is the preference, "tilt now" runs one check,
// "tilt status" reports the state, "tiltdbg on|off" streams raw samples.
// The framed-push test harness (see the blesimframe command): a 25 KB room
// message sent the way the daemon sends it, from a task with the BLE stack's
// own stack size, so the reassembly can be exercised without the phone.
static void blesimframe_task(void *pv) {
  int rounds = (int)(intptr_t)pv;
  String base = before_me;
  String pad = "";
  while (pad.length() < 20000) {
    pad += "pad-pad-pad-pad-pad-pad-pad-pad-pad-";
  }
  String inner = base.substring(1, base.length() - 1);
  String msg = "{\"type\":\"room\",\"data\":{\"room\":1,\"payload\":{\"pad\":\"" + pad + "\"," + inner + "}}}";
  const int chunk = 490;
  int total = (msg.length() + chunk - 1) / chunk;
  for (int r = 0; r < rounds; r++) {
    for (int i = 0; i < total; i++) {
      int from = i * chunk;
      int to = from + chunk;
      if (to > (int)msg.length()) {
        to = msg.length();
      }
      String frame = String(i) + "/" + String(total) + ":" + msg.substring(from, to);
      ble_frame_ingest(frame);
      vTaskDelay(pdMS_TO_TICKS(2));
    }
    Serial.printf("[blesimframe] round %d: %u bytes in %d chunks; headroom %u\n",
                  r + 1, (unsigned)msg.length(), total, (unsigned)uxTaskGetStackHighWaterMark(NULL));
    vTaskDelay(pdMS_TO_TICKS(40));
  }
  Serial.println("[blesimframe] done");
  vTaskDelete(NULL);
}

static void heapfast_task(void *param) {
  int secs = (int)(intptr_t)param;
  uint32_t until = millis() + (uint32_t)(secs > 0 ? secs : 5) * 1000;
  while ((int32_t)(until - millis()) > 0) {
    Serial.printf("[dma] %u free=%u max=%u\n", millis(),
                  (unsigned)heap_caps_get_free_size(MALLOC_CAP_DMA),
                  (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_DMA));
    vTaskDelay(100 / portTICK_PERIOD_MS);
  }
  vTaskDelete(NULL);
}

