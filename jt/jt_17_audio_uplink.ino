// The live Studio uplink (docs/studio-audio-roadmap.md P4).
//
// A T-Deck already records 16 kHz mono clips into PSRAM. This part lets the
// same capture feed a master engine while it records: the deck speaks the
// engine's own UDP protocol (HELLO/WELCOME, PING/PONG, authenticated PCM16
// datagrams), claims the stream Now Me gave it, and stamps every block with its
// fitted position on the master clock. The engine expands 16 kHz to 48 kHz, so
// the deck sends exactly what it captured.
//
// Two rules from the firmware's voice path still hold:
//
// * **A datagram carries a position, never an arrival time.** The block's first
//   frame is placed where the deck played it, so a late Wi-Fi hop costs jitter,
//   not alignment.
// * **Never write flash while capturing.** The WAV is still written after the
//   capture ends; this path only copies frames into a PSRAM ring and sends them.
//
// The session key is a house audio key delivered by Now Me, never the pairing
// token and never printed. An absent address or key means the deck records
// locally, exactly as before.

#include <WiFiUdp.h>
#include <mbedtls/md.h>
#include <esp_random.h>
#include <freertos/task.h>

static const uint16_t AUDIO_UPLINK_STREAM_BASE = 0x1000;
static const uint16_t AUDIO_UPLINK_CLOCK_PING = 0xFF00;
static const uint16_t AUDIO_UPLINK_CLOCK_PONG = 0xFF01;
static const uint16_t AUDIO_UPLINK_CLOCK_HELLO = 0xFF02;
static const uint16_t AUDIO_UPLINK_CLOCK_WELCOME = 0xFF03;
static const uint8_t AUDIO_UPLINK_HEADER = 32;
static const uint8_t AUDIO_UPLINK_TAG = 16;
static const uint8_t AUDIO_UPLINK_RATIO = 3;
// 10 ms at 16 kHz; 480 master frames once expanded, under the engine's 512.
static const uint16_t AUDIO_UPLINK_FRAMES = 160;
// One second of 16 kHz mono in PSRAM. A stalled Wi-Fi hop spills the oldest
// frames and counts them; the master conceals the gap on its own timeline.
static const uint32_t AUDIO_UPLINK_RING = 16000;
// The sender's stack lives in PSRAM: the voice listener already holds the
// internal heap the microphone task draws from, and 8 KB of it is not there.
static const uint32_t AUDIO_UPLINK_STACK_WORDS = 4096;
// A pong whose echoed ping is older than this is not a measurement of the
// path: its midpoint would charge seconds of capture to the delay.
static const uint32_t AUDIO_UPLINK_MAX_RTT = 24000;

static uint8_t audio_uplink_key[32];
static IPAddress audio_uplink_ip;
static uint16_t audio_uplink_port = 0;
static volatile bool audio_uplink_stop = false;
static volatile bool audio_uplink_ready = false;
static volatile bool audio_uplink_running = false;
static volatile uint32_t audio_uplink_captured = 0;
static volatile uint32_t audio_uplink_dropped = 0;
static int16_t *audio_uplink_ring = NULL;
static volatile uint32_t audio_uplink_head = 0;
static volatile uint32_t audio_uplink_tail = 0;
static portMUX_TYPE audio_uplink_mux = portMUX_INITIALIZER_UNLOCKED;
static StaticTask_t audio_uplink_tcb;
static StackType_t *audio_uplink_stack = NULL;
static uint32_t audio_uplink_seq = 1;

static void uplink_put_u16(uint8_t *p, uint16_t value) {
  p[0] = (uint8_t)(value & 0xFF);
  p[1] = (uint8_t)((value >> 8) & 0xFF);
}

static void uplink_put_u32(uint8_t *p, uint32_t value) {
  for (int i = 0; i < 4; i++) {
    p[i] = (uint8_t)((value >> (8 * i)) & 0xFF);
  }
}

static void uplink_put_u64(uint8_t *p, uint64_t value) {
  for (int i = 0; i < 8; i++) {
    p[i] = (uint8_t)((value >> (8 * i)) & 0xFF);
  }
}

static uint16_t uplink_get_u16(const uint8_t *p) {
  return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t uplink_get_u32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t uplink_get_u64(const uint8_t *p) {
  uint64_t value = 0;
  for (int i = 7; i >= 0; i--) {
    value = (value << 8) | p[i];
  }
  return value;
}

// The engine's one 32-byte header. `codec` is 0 (PCM16) for control and 3
// (Pcm16k) for the deck's audio.
static void uplink_header(uint8_t *h, uint8_t codec, uint32_t session, uint16_t stream,
                          uint8_t channels, uint32_t seq, uint64_t master_sample) {
  h[0] = 'J';
  h[1] = 'A';
  h[2] = 'W';
  h[3] = 'A';
  h[4] = 1;
  h[5] = codec;
  uplink_put_u16(h + 6, 0);
  uplink_put_u32(h + 8, session);
  uplink_put_u16(h + 12, stream);
  h[14] = channels;
  h[15] = 0;
  uplink_put_u32(h + 16, seq);
  uplink_put_u32(h + 20, 0);
  uplink_put_u64(h + 24, master_sample);
}

// HMAC-SHA256 over the header and body, truncated to the engine's 16 bytes.
static bool uplink_tag(uint8_t *datagram, size_t body_len) {
  unsigned char full[32];
  const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  if (!info) {
    return false;
  }
  if (mbedtls_md_hmac(info, audio_uplink_key, sizeof(audio_uplink_key),
                      datagram, AUDIO_UPLINK_HEADER + body_len, full) != 0) {
    return false;
  }
  memcpy(datagram + AUDIO_UPLINK_HEADER + body_len, full, AUDIO_UPLINK_TAG);
  return true;
}

// The same tag, checked without an early exit.
static bool uplink_tag_ok(const uint8_t *datagram, size_t body_len) {
  unsigned char full[32];
  const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  if (!info) {
    return false;
  }
  if (mbedtls_md_hmac(info, audio_uplink_key, sizeof(audio_uplink_key),
                      datagram, AUDIO_UPLINK_HEADER + body_len, full) != 0) {
    return false;
  }
  uint8_t difference = 0;
  for (size_t i = 0; i < AUDIO_UPLINK_TAG; i++) {
    difference |= full[i] ^ datagram[AUDIO_UPLINK_HEADER + body_len + i];
  }
  return difference == 0;
}

static void uplink_send(WiFiUDP &udp, const uint8_t *datagram, size_t length) {
  if (!udp.beginPacket(audio_uplink_ip, audio_uplink_port)) {
    return;
  }
  udp.write(datagram, length);
  udp.endPacket();
}

// HELLO until a WELCOME names a session. The nonce makes a retried handshake
// the same one to the master, so a lost reply does not mint a new session.
static bool uplink_handshake(WiFiUDP &udp, uint32_t *session_out) {
  uint64_t nonce = ((uint64_t)esp_random() << 32) | esp_random();
  for (int attempt = 0; attempt < 8 && !audio_uplink_stop; attempt++) {
    uint8_t datagram[AUDIO_UPLINK_HEADER + 10 + AUDIO_UPLINK_TAG];
    uplink_header(datagram, 0, 0, AUDIO_UPLINK_CLOCK_HELLO, 0, audio_uplink_seq++, 0);
    uplink_put_u64(datagram + AUDIO_UPLINK_HEADER, nonce);
    uplink_put_u16(datagram + AUDIO_UPLINK_HEADER + 8,
                   (uint16_t)(AUDIO_UPLINK_STREAM_BASE + audio_stream));
    if (!uplink_tag(datagram, 10)) {
      return false;
    }
    uplink_send(udp, datagram, sizeof(datagram));

    uint32_t deadline = millis() + 400;
    while ((int32_t)(millis() - deadline) < 0 && !audio_uplink_stop) {
      int available = udp.parsePacket();
      if (available <= 0) {
        vTaskDelay(pdMS_TO_TICKS(2));
        continue;
      }
      uint8_t incoming[AUDIO_UPLINK_HEADER + 32 + AUDIO_UPLINK_TAG];
      int length = udp.read(incoming, sizeof(incoming));
      if (length < AUDIO_UPLINK_HEADER + 4 + AUDIO_UPLINK_TAG) {
        continue;
      }
      if (uplink_get_u16(incoming + 12) != AUDIO_UPLINK_CLOCK_WELCOME) {
        continue;
      }
      if (!uplink_tag_ok(incoming, 4)) {
        continue;
      }
      uint32_t session = uplink_get_u32(incoming + AUDIO_UPLINK_HEADER);
      if (session == 0 || uplink_get_u32(incoming + 8) != session) {
        continue;
      }
      *session_out = session;
      return true;
    }
  }
  return false;
}

// One PING, then the least-delayed PONG in its window. The pong's two master
// timestamps bracket the master's own turnaround, so the midpoints compare the
// two clocks without charging the master's reply time to the path.
static bool uplink_ping(WiFiUDP &udp, uint32_t session, uint32_t *best_rtt,
                        int64_t *offset) {
  uint64_t local_send = (uint64_t)audio_uplink_captured * AUDIO_UPLINK_RATIO;
  uint8_t datagram[AUDIO_UPLINK_HEADER + 8 + AUDIO_UPLINK_TAG];
  uplink_header(datagram, 0, session, AUDIO_UPLINK_CLOCK_PING, 0, audio_uplink_seq++, 0);
  uplink_put_u64(datagram + AUDIO_UPLINK_HEADER, local_send);
  if (!uplink_tag(datagram, 8)) {
    return false;
  }
  uplink_send(udp, datagram, sizeof(datagram));

  bool found = false;
  uint32_t deadline = millis() + 15;
  while ((int32_t)(millis() - deadline) < 0) {
    int available = udp.parsePacket();
    if (available <= 0) {
      vTaskDelay(pdMS_TO_TICKS(1));
      continue;
    }
    uint8_t incoming[AUDIO_UPLINK_HEADER + 32 + AUDIO_UPLINK_TAG];
    int length = udp.read(incoming, sizeof(incoming));
    if (length < AUDIO_UPLINK_HEADER + 24 + AUDIO_UPLINK_TAG) {
      continue;
    }
    if (uplink_get_u16(incoming + 12) != AUDIO_UPLINK_CLOCK_PONG) {
      continue;
    }
    if (!uplink_tag_ok(incoming, 24)) {
      continue;
    }
    if (uplink_get_u32(incoming + 8) != session) {
      continue;
    }
    uint64_t echo = uplink_get_u64(incoming + AUDIO_UPLINK_HEADER);
    uint64_t master_recv = uplink_get_u64(incoming + AUDIO_UPLINK_HEADER + 8);
    uint64_t master_send = uplink_get_u64(incoming + AUDIO_UPLINK_HEADER + 16);
    uint64_t local_recv = (uint64_t)audio_uplink_captured * AUDIO_UPLINK_RATIO;
    // Before capture has produced anything, the local clock has not moved and
    // the exchange says nothing about the audio timeline. An old echo read at
    // the current position would skew the midpoint by the whole backlog.
    if (echo == 0 || local_recv == 0 || local_recv < echo
        || local_recv - echo > AUDIO_UPLINK_MAX_RTT) {
      continue;
    }
    int64_t master_mid = (int64_t)((master_recv + master_send) / 2);
    int64_t local_mid = (int64_t)((echo + local_recv) / 2);
    uint32_t rtt = (uint32_t)(local_recv - echo);
    if (!found || rtt < *best_rtt) {
      *best_rtt = rtt;
      *offset = master_mid - local_mid;
      found = true;
    }
  }
  return found;
}

static void audio_uplink_pop(int16_t *out, size_t max, size_t *count, uint32_t *local_start) {
  *count = 0;
  if (!audio_uplink_ring) {
    return;
  }
  portENTER_CRITICAL(&audio_uplink_mux);
  uint32_t head = audio_uplink_head;
  uint32_t tail = audio_uplink_tail;
  size_t available = (size_t)(head - tail);
  size_t take = available > max ? max : available;
  *local_start = tail;
  for (size_t i = 0; i < take; i++) {
    out[i] = audio_uplink_ring[(tail + i) % AUDIO_UPLINK_RING];
  }
  audio_uplink_tail = tail + (uint32_t)take;
  *count = take;
  portEXIT_CRITICAL(&audio_uplink_mux);
}

// Send everything the ring holds, up to the sender's per-wake burst. A block's
// first frame is stamped by its capture index, so an overwritten stretch is a
// jump on the timeline and not a shift.
static void uplink_send_audio(WiFiUDP &udp, uint32_t session, int64_t offset) {
  for (int burst = 0; burst < 3; burst++) {
    int16_t block[AUDIO_UPLINK_FRAMES];
    size_t count = 0;
    uint32_t local_start = 0;
    audio_uplink_pop(block, AUDIO_UPLINK_FRAMES, &count, &local_start);
    if (count == 0) {
      return;
    }
    int64_t position = offset + (int64_t)local_start * AUDIO_UPLINK_RATIO;
    if (position < 0) {
      position = 0;
    }
    uint8_t datagram[AUDIO_UPLINK_HEADER + AUDIO_UPLINK_FRAMES * 2 + AUDIO_UPLINK_TAG];
    uplink_header(datagram, 3, session, (uint16_t)(AUDIO_UPLINK_STREAM_BASE + audio_stream),
                  1, audio_uplink_seq++, (uint64_t)position);
    for (size_t i = 0; i < count; i++) {
      uint16_t value = (uint16_t)block[i];
      datagram[AUDIO_UPLINK_HEADER + i * 2] = (uint8_t)(value & 0xFF);
      datagram[AUDIO_UPLINK_HEADER + i * 2 + 1] = (uint8_t)((value >> 8) & 0xFF);
    }
    if (!uplink_tag(datagram, count * 2)) {
      return;
    }
    uplink_send(udp, datagram, AUDIO_UPLINK_HEADER + count * 2 + AUDIO_UPLINK_TAG);
  }
}

static void audio_uplink_release_ring(void) {
  int16_t *ring = NULL;
  portENTER_CRITICAL(&audio_uplink_mux);
  audio_uplink_running = false;
  ring = audio_uplink_ring;
  audio_uplink_ring = NULL;
  portEXIT_CRITICAL(&audio_uplink_mux);
  if (ring) {
    free(ring);
  }
}

static void audioUplinkTask(void *pv) {
  (void)pv;
  WiFiUDP udp;
  udp.begin(0);
  uint32_t session = 0;
  if (!uplink_handshake(udp, &session)) {
    deckLog("[uplink] no session; recording locally only");
    udp.stop();
    audio_uplink_release_ring();
    vTaskDelete(NULL);
    return;
  }
  deckLog("[uplink] session %lu, stream %d", (unsigned long)session, audio_stream);
  audio_uplink_ready = true;

  int64_t offset = 0;
  uint32_t best_rtt = 0xFFFFFFFF;
  bool aligned = false;
  uint32_t last_pong = millis();
  while (!audio_uplink_stop || audio_uplink_head != audio_uplink_tail) {
    uint32_t cycle = millis();
    uint32_t rtt = 0xFFFFFFFF;
    int64_t candidate = 0;
    if (uplink_ping(udp, session, &rtt, &candidate)) {
      if (!aligned || rtt < best_rtt) {
        offset = candidate;
        best_rtt = rtt;
        aligned = true;
      }
      last_pong = millis();
    }
    if (aligned) {
      uplink_send_audio(udp, session, offset);
    }
    if (millis() - last_pong > 2000) {
      if (!uplink_handshake(udp, &session)) {
        deckLog("%s", "[uplink] master went quiet; stopping");
        break;
      }
      last_pong = millis();
      aligned = false;
    }
    uint32_t spent = millis() - cycle;
    if (spent < 10) {
      vTaskDelay(pdMS_TO_TICKS(10 - spent));
    }
  }
  deckLog("[uplink] stopped, %lu frames, %lu dropped",
          (unsigned long)audio_uplink_captured, (unsigned long)audio_uplink_dropped);
  udp.stop();
  // The sender owns the ring: it may outlive the capture task's wait in
  // audio_uplink_finish, so freeing here is what makes that wait safe. The
  // critical section closes the window against a push still in flight.
  audio_uplink_release_ring();
  vTaskDelete(NULL);
}

// Copy captured 16 kHz mono frames into the PSRAM ring. When it is full the
// oldest frame goes first: the capture must never wait on the network.
static void audio_uplink_push(const int16_t *samples, size_t count) {
  portENTER_CRITICAL(&audio_uplink_mux);
  if (!audio_uplink_running || !audio_uplink_ring || count == 0) {
    portEXIT_CRITICAL(&audio_uplink_mux);
    return;
  }
  uint32_t head = audio_uplink_head;
  uint32_t tail = audio_uplink_tail;
  for (size_t i = 0; i < count; i++) {
    if (head - tail >= AUDIO_UPLINK_RING) {
      tail++;
      audio_uplink_dropped++;
    }
    audio_uplink_ring[head % AUDIO_UPLINK_RING] = samples[i];
    head++;
  }
  audio_uplink_head = head;
  audio_uplink_tail = tail;
  audio_uplink_captured += (uint32_t)count;
  portEXIT_CRITICAL(&audio_uplink_mux);
}

static int uplink_hex(char c) {
  if (c >= '0' && c <= '9') {
    return c - '0';
  }
  if (c >= 'a' && c <= 'f') {
    return c - 'a' + 10;
  }
  if (c >= 'A' && c <= 'F') {
    return c - 'A' + 10;
  }
  return -1;
}

static bool audio_uplink_parse_key(void) {
  if (audio_key.length() != 64) {
    return false;
  }
  for (int i = 0; i < 32; i++) {
    int high = uplink_hex(audio_key[i * 2]);
    int low = uplink_hex(audio_key[i * 2 + 1]);
    if (high < 0 || low < 0) {
      return false;
    }
    audio_uplink_key[i] = (uint8_t)((high << 4) | low);
  }
  return true;
}

static bool audio_uplink_parse_address(void) {
  int colon = audio_uplink.lastIndexOf(':');
  if (colon <= 0) {
    return false;
  }
  String host = audio_uplink.substring(0, colon);
  long port = audio_uplink.substring(colon + 1).toInt();
  if (port < 1 || port > 65535) {
    return false;
  }
  if (!audio_uplink_ip.fromString(host)) {
    return false;
  }
  audio_uplink_port = (uint16_t)port;
  return true;
}

// Start the sender and wait for the session before the microphone starts. A
// missing address, key or session is not an error: the deck records locally.
static bool audio_uplink_start(void) {
  if (audio_uplink_running) {
    deckLog("%s", "[uplink] a sender is already running; recording locally");
    return false;
  }
  if (audio_uplink.length() == 0 || audio_key.length() == 0 || audio_stream < 0) {
    return false;
  }
  if (WiFi.status() != WL_CONNECTED) {
    deckLog("%s", "[uplink] configured but WiFi is down; recording locally");
    return false;
  }
  if (!audio_uplink_parse_address() || !audio_uplink_parse_key()) {
    deckLog("%s", "[uplink] address or key is not usable; recording locally");
    return false;
  }
  audio_uplink_ring = (int16_t *)ps_malloc((size_t)AUDIO_UPLINK_RING * 2);
  if (!audio_uplink_ring) {
    deckLog("%s", "[uplink] no PSRAM for the ring; recording locally");
    return false;
  }
  audio_uplink_head = 0;
  audio_uplink_tail = 0;
  audio_uplink_captured = 0;
  audio_uplink_dropped = 0;
  audio_uplink_stop = false;
  audio_uplink_ready = false;
  audio_uplink_running = true;
  if (!audio_uplink_stack) {
    audio_uplink_stack = (StackType_t *)ps_malloc(
        (size_t)AUDIO_UPLINK_STACK_WORDS * sizeof(StackType_t));
  }
  if (!audio_uplink_stack) {
    deckLog("%s", "[uplink] no PSRAM for the task stack; recording locally");
    audio_uplink_running = false;
    free(audio_uplink_ring);
    audio_uplink_ring = NULL;
    return false;
  }
  if (!xTaskCreateStaticPinnedToCore(audioUplinkTask, "AudioUp",
                                     AUDIO_UPLINK_STACK_WORDS, NULL, 2,
                                     audio_uplink_stack, &audio_uplink_tcb, 0)) {
    deckLog("%s", "[uplink] no task; recording locally");
    audio_uplink_running = false;
    free(audio_uplink_ring);
    audio_uplink_ring = NULL;
    return false;
  }

  uint32_t deadline = millis() + 3000;
  while (!audio_uplink_ready && audio_uplink_running && (int32_t)(millis() - deadline) < 0) {
    vTaskDelay(pdMS_TO_TICKS(10));
  }
  if (!audio_uplink_ready) {
    audio_uplink_stop = true;
    uint32_t stop_deadline = millis() + 1000;
    while (audio_uplink_running && (int32_t)(millis() - stop_deadline) < 0) {
      vTaskDelay(pdMS_TO_TICKS(10));
    }
    // A task that is still winding down owns the ring and frees it itself.
    if (!audio_uplink_running && audio_uplink_ring) {
      free(audio_uplink_ring);
      audio_uplink_ring = NULL;
    }
    return false;
  }
  deckLog("[uplink] feeding %s stream %d", audio_uplink.c_str(), audio_stream);
  return true;
}

// Stop the sender after the capture has produced its last frame; it drains the
// ring first, so the tail of the take reaches the master.
static void audio_uplink_finish(void) {
  if (!audio_uplink_running) {
    return;
  }
  audio_uplink_stop = true;
  uint32_t deadline = millis() + 2500;
  while (audio_uplink_running && (int32_t)(millis() - deadline) < 0) {
    vTaskDelay(pdMS_TO_TICKS(10));
  }
  if (audio_uplink_running) {
    deckLog("%s", "[uplink] sender still draining; its ring stays with it");
  }
}
