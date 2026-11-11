// ---- pulling a file off the deck without wifi ------------------------------
// The usb serial is the GPS bridge. A line that arrives as "JAWNDUMP <path>"
// (watch it in loop()) is the one exception: the file comes back as base64
// between BEGIN and END markers, so a recording can be pulled with nothing but
// the usb cable.
static void serialDumpFile(String name) {
  while (name.length() > 0 && (name.endsWith("\r") || name.endsWith(" "))) {
    name.remove(name.length() - 1);
  }
  if (!name.startsWith("/") || name.indexOf("..") >= 0) {
    Serial.println("JAWNDUMP bad name");
    return;
  }
  File f = store->open(name.c_str());
  if (!f) {
    // config and the boot report still live on FFat; a developer's dump of one
    // should not depend on which filesystem the bulk files chose
    f = FFat.open(name.c_str());
  }
  if (!f || f.isDirectory()) {
    Serial.println("JAWNDUMP no file");
    return;
  }
  Serial.printf("JAWNDUMP BEGIN %s %u\n", name.c_str(), (unsigned)f.size());
  static const char *b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  static uint8_t raw[768];
  static char out[(sizeof(raw) / 3 + 1) * 4 + 1];
  while (true) {
    size_t got = f.read(raw, sizeof(raw));
    if (got == 0) {
      break;
    }
    size_t n = 0;
    for (size_t i = 0; i < got; i += 3) {
      uint32_t v = ((uint32_t)raw[i]) << 16;
      if (i + 1 < got) {
        v |= ((uint32_t)raw[i + 1]) << 8;
      }
      if (i + 2 < got) {
        v |= (uint32_t)raw[i + 2];
      }
      out[n++] = b64[(v >> 18) & 63];
      out[n++] = b64[(v >> 12) & 63];
      out[n++] = (i + 1 < got) ? b64[(v >> 6) & 63] : '=';
      out[n++] = (i + 2 < got) ? b64[v & 63] : '=';
    }
    out[n] = 0;
    Serial.println(out);
    delay(1);
  }
  f.close();
  Serial.println("JAWNDUMP END");
}

// The mic array is an ES7210 wired for TDM; core 3.x dropped the old
// i2s_driver_install() API, so this is the same setup through i2s_tdm.
i2s_chan_handle_t mic_rx_handle = NULL;

void setupMicrophoneI2S(i2s_port_t  i2s_ch)
{
  i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(i2s_ch, I2S_ROLE_MASTER);
  // 8 x 256 frames is 128 ms of audio sitting in the rx DMA. The capture task
  // writes to flash between reads, and a write that stalls for a few ms used
  // to overflow this: the missing samples are heard as a periodic buzz and
  // cost about 9% of the capture rate (29 kB/s instead of 32).
  chan_cfg.dma_desc_num = 8;
  chan_cfg.dma_frame_num = 256;

  if (i2s_new_channel(&chan_cfg, NULL, &mic_rx_handle) != ESP_OK) {
    Serial.println("mic i2s channel failed");
    return;
  }

  i2s_tdm_config_t tdm_cfg = {};
  tdm_cfg.clk_cfg = I2S_TDM_CLK_DEFAULT_CONFIG(MIC_I2S_SAMPLE_RATE);
  tdm_cfg.slot_cfg = I2S_TDM_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT,
                     I2S_SLOT_MODE_STEREO,
                     (i2s_tdm_slot_mask_t)(I2S_TDM_SLOT0 | I2S_TDM_SLOT1 | I2S_TDM_SLOT2 | I2S_TDM_SLOT3));
  // four slots in one frame, not the two a stereo config would assume; without
  // this the driver frames the ES7210's TDM output wrong (this is the same
  // setting LilyGoLib's ES7210 bring-up uses)
  tdm_cfg.slot_cfg.total_slot = 4;
  tdm_cfg.gpio_cfg.mclk = (gpio_num_t)BOARD_ES7210_MCLK;
  tdm_cfg.gpio_cfg.bclk = (gpio_num_t)BOARD_ES7210_SCK;
  tdm_cfg.gpio_cfg.ws = (gpio_num_t)BOARD_ES7210_LRCK;
  tdm_cfg.gpio_cfg.dout = I2S_GPIO_UNUSED;
  tdm_cfg.gpio_cfg.din = (gpio_num_t)BOARD_ES7210_DIN;
  tdm_cfg.gpio_cfg.invert_flags.mclk_inv = false;
  tdm_cfg.gpio_cfg.invert_flags.bclk_inv = false;
  tdm_cfg.gpio_cfg.invert_flags.ws_inv = false;

  if (i2s_channel_init_tdm_mode(mic_rx_handle, &tdm_cfg) != ESP_OK) {
    Serial.println("mic i2s tdm mode failed");
    return;
  }
  i2s_channel_enable(mic_rx_handle);

}

// ---- voice notes: ES7210 mic array -> WAV on flash -> speaker -----------------
// The shape of this is the watch's: write a 44 byte RIFF header, append the PCM
// while recording, then patch the two size fields when it stops. What differs
// is the hardware - the deck's microphone is an ES7210 wired for TDM with four
// slots, so every frame in the I2S buffer is four 16 bit samples and MIC1 (the
// first of them) becomes the mono track.
String WAV_FILE_PATH = "/jawn/rec.wav";
// the voice path: the clip's own epoch (seconds) and the file it was written to,
// so the shipping task knows what to send
static volatile long deck_voice_ts = 0;
static String deck_voice_wav;
// a timed recording (0 = until the button is tapped again)
static uint32_t record_end_ms = 0;

// The vendored es7210 driver and the esp_codec_dev driver LilyGoLib ships write
// different DSP mode bits, and they disagree about the register values too:
// this one sends 0x13, which leaves the upper pair of mics on the second output
// pin, while the factory firmware sends 0x03 with all four mics time multiplexed
// onto SDOUT1 - which is what the four slot Philips TDM on the I2S side expects.
// Reading a 0x13 codec with a 0x02 receiver gets roughly half of every frame off
// by a slot: quiet and gritty. So write those two registers ourselves afterwards.
static void es7210WriteReg(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(ES7210_ADDR);
  Wire.write(reg);
  Wire.write(value);
  Wire.endTransmission();
}

bool es7210Begin()
{
  Wire.beginTransmission(ES7210_ADDR);
  if (Wire.endTransmission() != 0) {
    deckLog("[mic] no ES7210 on the i2c bus");
    return false;
  }
  audio_hal_codec_config_t cfg = {};
  cfg.adc_input = AUDIO_HAL_ADC_INPUT_ALL;
  cfg.codec_mode = AUDIO_HAL_CODEC_MODE_ENCODE;
  cfg.i2s_iface.mode = AUDIO_HAL_MODE_SLAVE;
  // LilyGo's own driver puts the ES7210 in plain I2S (register 0x11 = 0x00),
  // and that is what a four slot Philips receiver wants to read: MIC1 lands in
  // slot 0, MIC2 in slot 2, the odd slots carry padding. The DSP-B setup this
  // used to write (0x03 into 0x11, 0x02 into 0x12) packs the four mics back to
  // back inside the frame with a different sync, and the receiver then slices
  // them into near-Nyquist garbage - heard as the buzz that came and went.
  cfg.i2s_iface.fmt = AUDIO_HAL_I2S_NORMAL;
  cfg.i2s_iface.samples = AUDIO_HAL_16K_SAMPLES;
  cfg.i2s_iface.bits = AUDIO_HAL_BIT_LENGTH_16BITS;
  es7210_adc_init(&Wire, &cfg);               // sets slave mode, clocks and mics
  // The vendored driver's high pass filter writes are commented out, and the
  // esp_codec_dev driver LilyGoLib ships applies them: without them the ADC's
  // DC and low frequency content ends up in the recording as hum.
  es7210WriteReg(ES7210_ADC12_HPF2_REG23, 0x2a);
  es7210WriteReg(ES7210_ADC12_HPF1_REG22, 0x0a);
  es7210WriteReg(ES7210_ADC34_HPF2_REG20, 0x0a);
  es7210WriteReg(ES7210_ADC34_HPF1_REG21, 0x2a);
  es7210_adc_set_gain_all(GAIN_37_5DB);       // the chip's maximum: this microphone is quiet
  es7210_adc_ctrl_state(AUDIO_HAL_CODEC_MODE_ENCODE, AUDIO_HAL_CTRL_START);
  // These three only stick once the adc clocks are running - writing them
  // before the START above is silently lost, which is what made every
  // recording so far read garbage or a dead noise floor:
  //  - REG40 0x43: the vendored init's 0xC3 sets bit 7, which powers the
  //    analog block down.
  //  - REG12 0x02: TDM mode, all four mics on one output line. The vendored
  //    config_fmt clears it to 0x00 and the old code compensated with DSP-B
  //    format bits that left the receiver slicing the stream a byte off.
  //  - REG11 0x60: 16 bit data, normal I2S format, which is what the four slot
  //    Philips receiver expects.
  es7210WriteReg(ES7210_ANALOG_REG40, 0x43);
  es7210WriteReg(ES7210_SDP_INTERFACE2_REG12, 0x02);
  es7210WriteReg(ES7210_SDP_INTERFACE1_REG11, 0x60);
  deckLog("[mic] ES7210 up (37.5 dB)");
  return true;
}

// 44 byte RIFF/WAVE header with zeroes where the sizes go
bool create_wav_header_on_flash(const char *song_name, const uint32_t sampling_rate, uint16_t bits_per_sample, uint16_t channels) {
  File new_audio_file = store->open(song_name, FILE_WRITE);
  if (!new_audio_file) {
    deckLog("[mic] cannot create %s", song_name);
    return false;
  }

  uint8_t header[44] = {
    'R', 'I', 'F', 'F',
    0, 0, 0, 0,       // ChunkSize placeholder (updated later)
    'W', 'A', 'V', 'E',
    'f', 'm', 't', ' ',
    16, 0, 0, 0,      // Subchunk1Size
    1, 0,             // AudioFormat PCM
    (uint8_t)(channels & 0xff), (uint8_t)((channels >> 8) & 0xff),   // channels
    (uint8_t)(sampling_rate & 0xff), (uint8_t)((sampling_rate >> 8) & 0xff), 0, 0,
    0, 0, 0, 0,       // ByteRate placeholder (updated later)
    (uint8_t)((channels * bits_per_sample) / 8), 0, // BlockAlign
    (uint8_t)bits_per_sample, 0,             // BitsPerSample
    'd', 'a', 't', 'a',
    0, 0, 0, 0        // Subchunk2Size placeholder (updated later)
  };

  new_audio_file.write(header, 44);
  new_audio_file.close();
  return true;
}

// rewrites header placeholders with the exact byte sizes after recording stops
void finalize_wav_sizes(const char *song_name, uint32_t raw_pcm_bytes, uint16_t channels) {
  File audio_file = store->open(song_name, "r+");
  if (!audio_file) {
    return;
  }

  uint32_t chunk_size = raw_pcm_bytes + 36;
  uint32_t byte_rate = MIC_I2S_SAMPLE_RATE * channels * (MIC_I2S_BITS_PER_SAMPLE / 8);

  audio_file.seek(4);
  audio_file.write((uint8_t *)&chunk_size, 4);
  audio_file.seek(28);
  audio_file.write((uint8_t *)&byte_rate, 4);
  audio_file.seek(40);
  audio_file.write((uint8_t *)&raw_pcm_bytes, 4);
  audio_file.close();
}

// ---- voice clips over the BLE bridge (the watch's voice path, deck edition) --
// The deck records a clip to /recordings/<epoch>.wav (16 kHz mono). To reach the
// server the way the watch does, the clip is folded to 8 kHz and compressed to
// IMA ADPCM (~4:1), then sent as one base64 "voice" message over the BLE bridge -
// the server funnels it into the same voice_ingest a tap's url reaches, so the
// deck gets the same transcription and the same reply. BLE only for now (the
// watch also POSTs over WiFi when it can; that can follow).
#define DECK_ADPCM_BLOCK 1024
#define DECK_ADPCM_SPB ((DECK_ADPCM_BLOCK - 4) * 2 + 1)   // 2041 samples/block
#define DECK_VOICE_RATE 8000

static const int32_t deck_adpcm_step[89] = {
  7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,
  50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,
  337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,
  2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,
  12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767 };
static const int8_t deck_adpcm_index[16] = { -1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8 };

static void deck_wr16(uint8_t *p, uint16_t v) { p[0] = v & 0xff; p[1] = (v >> 8) & 0xff; }
static void deck_wr32(uint8_t *p, uint32_t v) { p[0] = v & 0xff; p[1] = (v >> 8) & 0xff; p[2] = (v >> 16) & 0xff; p[3] = (v >> 24) & 0xff; }

// Fold the 16 kHz mono clip to 8 kHz and IMA-encode it under the same 60-byte
// header the watch writes, so the server's whisper reads an identical file.
static bool deck_voice_compress(const String &in_path, const String &out_path) {
  File in = store->open(in_path.c_str(), FILE_READ);
  if (!in || in.size() <= 44) { if (in) { in.close(); } return false; }
  uint32_t pcm_bytes = in.size() - 44;
  uint32_t in_samples = pcm_bytes / 2;
  uint32_t out_samples = in_samples / 2;      // 16k mono -> 8k
  uint32_t blocks = (out_samples + DECK_ADPCM_SPB - 1) / DECK_ADPCM_SPB;
  uint32_t data_bytes = blocks * DECK_ADPCM_BLOCK;
  uint32_t total = 60 + data_bytes;
  uint8_t *buf = (uint8_t *)ps_malloc(total);
  if (!buf) { buf = (uint8_t *)malloc(total); }
  if (!buf) { in.close(); return false; }
  uint32_t abps = (uint32_t)((uint64_t)DECK_VOICE_RATE * DECK_ADPCM_BLOCK / DECK_ADPCM_SPB);
  memcpy(buf, "RIFF", 4); deck_wr32(buf + 4, total - 8); memcpy(buf + 8, "WAVE", 4);
  memcpy(buf + 12, "fmt ", 4); deck_wr32(buf + 16, 20);
  deck_wr16(buf + 20, 0x11); deck_wr16(buf + 22, 1);
  deck_wr32(buf + 24, DECK_VOICE_RATE); deck_wr32(buf + 28, abps);
  deck_wr16(buf + 32, DECK_ADPCM_BLOCK); deck_wr16(buf + 34, 4);
  deck_wr16(buf + 36, 2); deck_wr16(buf + 38, DECK_ADPCM_SPB);
  memcpy(buf + 40, "fact", 4); deck_wr32(buf + 44, 4); deck_wr32(buf + 48, out_samples);
  memcpy(buf + 52, "data", 4); deck_wr32(buf + 56, data_bytes);
  in.seek(44);
  static int16_t blk[DECK_ADPCM_SPB];
  int16_t pair[2];
  uint32_t o = 60;
  while (true) {
    int count = 0;
    while (count < DECK_ADPCM_SPB) {
      int got = in.read((uint8_t *)pair, 4);       // two 16k samples -> one 8k
      if (got < 4) { break; }
      blk[count++] = (int16_t)(((int32_t)pair[0] + (int32_t)pair[1]) >> 1);
    }
    if (count < 2) { break; }
    uint32_t block_start = o;
    int32_t pred = blk[0];
    int index = 0;
    deck_wr16(buf + o, (uint16_t)pred); o += 2; buf[o++] = (uint8_t)index; buf[o++] = 0;
    int nib_have = 0; uint8_t pending = 0;
    for (int i = 1; i < count; i++) {
      int32_t step = deck_adpcm_step[index];
      int32_t diff = (int32_t)blk[i] - pred;
      uint8_t nib = 0;
      if (diff < 0) { nib = 8; diff = -diff; }
      if (diff >= step) { nib |= 4; diff -= step; }
      if (diff >= (step >> 1)) { nib |= 2; diff -= (step >> 1); }
      if (diff >= (step >> 2)) { nib |= 1; }
      int32_t diffq = step >> 3;
      if (nib & 4) { diffq += step; }
      if (nib & 2) { diffq += step >> 1; }
      if (nib & 1) { diffq += step >> 2; }
      pred = (nib & 8) ? pred - diffq : pred + diffq;
      if (pred > 32767) { pred = 32767; } else if (pred < -32768) { pred = -32768; }
      index += deck_adpcm_index[nib];
      if (index < 0) { index = 0; } else if (index > 88) { index = 88; }
      if (!nib_have) { pending = nib; nib_have = 1; }
      else { buf[o++] = pending | (nib << 4); nib_have = 0; }
    }
    if (nib_have) { buf[o++] = pending; }
    while (o - block_start < DECK_ADPCM_BLOCK) { buf[o++] = 0; }   // pad the block
    if (count < DECK_ADPCM_SPB) { break; }
  }
  in.close();
  File out = store->open(out_path.c_str(), FILE_WRITE);
  if (!out) { free(buf); return false; }
  size_t wrote = out.write(buf, o);
  out.close();
  free(buf);
  deckLog("[voice] compressed %u -> %u bytes", (unsigned)pcm_bytes, (unsigned)wrote);
  return wrote == o;
}

static void deck_b64_append(String &out, const uint8_t *p, unsigned len) {
  static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  for (unsigned i = 0; i < len; i += 3) {
    unsigned rem = len - i;
    uint8_t b0 = p[i];
    out += tbl[(b0 >> 2) & 0x3f];
    if (rem == 1) {
      out += tbl[((b0 & 0x03) << 4) & 0x3f];
      out += "==";
    }
    else {
      uint8_t b1 = p[i + 1];
      out += tbl[((b0 & 0x03) << 4) | ((b1 >> 4) & 0x0f)];
      if (rem == 2) {
        out += tbl[((b1 & 0x0f) << 2) & 0x3f];
        out += '=';
      }
      else {
        uint8_t b2 = p[i + 2];
        out += tbl[((b1 & 0x0f) << 2) | ((b2 >> 6) & 0x03)];
        out += tbl[b2 & 0x3f];
      }
    }
  }
}

// One "voice" message: the clip base64'd whole, sent through the transport framer
// (which cuts it to the link's MTU, whatever that is).
static bool deck_voice_ble_send(const String &path, long ts, const char *mode) {
  if (!ble_link_ready()) { return false; }
  File f = store->open(path.c_str(), FILE_READ);
  if (!f) { return false; }
  size_t size = f.size();
  if (size == 0) { f.close(); return false; }
  String msg = "{\"type\":\"voice\",\"chip_id\":\"" + chip_id_maker()
    + "\",\"edt\":\"teletype\",\"ts\":" + String(ts)
    + ",\"voice\":\"" + mode + "\",\"data\":\"";
  msg.reserve(size * 4 / 3 + 128);
  uint8_t b[3];
  while (true) {
    int got = f.read(b, 3);
    if (got <= 0) { break; }
    deck_b64_append(msg, b, got);
    if (got != 3) { break; }
  }
  msg += "\"}";
  f.close();
  ble_notify_payload(msg, 20);
  return true;
}

// POST the finished clip to the homebase over WiFi. Streamed from flash, the
// way the watch does it: the clip is tens of KB, which the TLS stack should not
// hold in RAM. A missing WiFi link or a homebase already marked down returns at
// once so the caller can go straight to BLE.
static bool deck_voice_post_clip(const String &path, long ts, const char *mode) {
  if (homebaseIP.length() == 0 || authorization.length() == 0) {
    deckLog("%s", "[voice] no homebase/auth; BLE now");
    return false;
  }
  if (WiFi.status() != WL_CONNECTED) {
    deckLog("%s", "[voice] WiFi not connected; BLE now");
    return false;
  }
  if ((int32_t)(millis() - homebase_down_until) < 0) {
    deckLog("%s", "[voice] homebase marked down; BLE now");
    return false;
  }
  File f = store->open(path.c_str(), FILE_READ);
  if (!f) { return false; }
  WiFiClientSecure client;
  client.setCACert(HOUSE_CA_PEM);
  HTTPClient https;
  // Short enough that an unreachable homebase costs a moment, not the reply
  // window: the clip is compressed and the link is local, so this is ample.
  https.setTimeout(4000);
  String url = "https://" + homebaseIP + "/watch/voice?edt=teletype"
    + "&chip_id=" + chip_id_maker()
    + "&authorization=" + urlEncode(authorization)
    + "&voice=" + String(mode)
    + "&timestamp=" + String(ts);
  bool ok = false;
  if (https.begin(client, url)) {
    https.addHeader("Content-Type", "application/octet-stream");
    int code = https.sendRequest("POST", &f, (size_t)f.size());
    f.close();
    deckLog("[voice] WiFi POST %d", code);
    ok = (code > 0 && code < 400);
    https.end();
  }
  else {
    f.close();
    deckLog("%s", "[voice] WiFi begin failed; BLE now");
  }
  homebase_down_until = ok ? 0 : millis() + 20000;
  return ok;
}

// WiFi first, BLE when there is no link (or the POST failed): a WiFi POST
// carries the whole clip in one request, while BLE has to send hundreds of
// notifications and can lose parts. The log names the chosen road.
static bool deck_voice_ship(const String &path, long ts, const char *mode) {
  if (deck_voice_post_clip(path, ts, mode)) {
    deckLog("[voice] clip shipped over WiFi");
    return true;
  }
  if (deck_voice_ble_send(path, ts, mode)) {
    deckLog("[voice] clip shipped over BLE");
    return true;
  }
  deckLog("%s", "[voice] no radio to ship the clip on");
  return false;
}

// The shipping task: compress the clip and hand it off, then release the
// microphone to the next recording.
static void deckVoiceShipTask(void *pv) {
  (void)pv;
  long ts = deck_voice_ts;
  String cls = deck_voice_wav;
  if (deck_voice_compress(deck_voice_wav, "/jawn/voice.adpcm")) { cls = "/jawn/voice.adpcm"; }
  bool ok = deck_voice_ship(cls, ts, "vad");
  deckLog("[voice] clip ts=%ld %s", ts, ok ? "shipped" : "NOT shipped");
  vTaskDelete(NULL);
}

