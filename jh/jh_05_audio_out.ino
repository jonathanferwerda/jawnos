// ---- audio out: the house's answer, in the ear ------------------------------
// A MAX98357 I2S amplifier drives the bone-conduction pair. The transducer is
// the only speaker the hat has; there is no codec, no volume pot and no
// headphone jack. The MAX98357 sets its own gain with a resistor and expects
// standard I2S, 16-bit words; anything else (8-bit, stereo, MP3) is rejected
// rather than played as noise.
//
// The pins are the XIAO's D6/D7/D3 header pins. They are deliberately not
// D8/D9/D10 (GPIO 7/8/9): those are the Sense microSD card's SPI bus, and the
// hat still wants the card for logged frames later. D6/D7 are UART0's TX/RX,
// which USB-CDC boot leaves free on this board.
#define JH_I2S_BCLK   43   // D6
#define JH_I2S_LRCLK  44   // D7
#define JH_I2S_DOUT   4    // D3

static I2SClass jh_spk(I2S_NUM_0);
static bool jh_audio_up = false;
static volatile bool jh_audio_busy = false;
static uint32_t jh_audio_rate = JH_AUDIO_RATE;
static int jh_audio_volume = 80;   // percent; the amp's gain sets the ceiling

struct jh_audio_job_t {
  uint8_t *data;
  size_t len;
  uint32_t rate;
};

void audio_out_init() {
  jh_spk.setPins(JH_I2S_BCLK, JH_I2S_LRCLK, JH_I2S_DOUT);
  jh_audio_up = jh_spk.begin(I2S_MODE_STD, JH_AUDIO_RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO);
  if (!jh_audio_up) {
    jh_log("[spk] i2s begin failed (%d)", jh_spk.lastError());
    return;
  }
  jh_log("[spk] i2s %u Hz mono on bclk=%d lrclk=%d din=%d", (unsigned)JH_AUDIO_RATE,
         JH_I2S_BCLK, JH_I2S_LRCLK, JH_I2S_DOUT);
}

static void audio_task(void *arg) {
  jh_audio_job_t *job = (jh_audio_job_t *)arg;
  if (job->rate != jh_audio_rate) {
    // The house may answer at 8, 16 or 22.05 kHz. Re-clock the peripheral once
    // per clip instead of resampling in software; the MAX98357 follows the
    // LRCLK it is given.
    jh_spk.end();
    // end() tears the channel down; the pins are re-asserted so the re-clock
    // cannot silently fall back to the constructor's defaults.
    jh_spk.setPins(JH_I2S_BCLK, JH_I2S_LRCLK, JH_I2S_DOUT);
    if (!jh_spk.begin(I2S_MODE_STD, job->rate, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO)) {
      jh_log("[spk] re-clock to %u Hz failed (%d)", (unsigned)job->rate, jh_spk.lastError());
      free(job->data);
      delete job;
      jh_audio_busy = false;
      vTaskDelete(NULL);
      return;
    }
    jh_audio_rate = job->rate;
  }

  size_t offset = 0;
  size_t written = 0;
  int16_t scaled[256];
  while (offset < job->len) {
    size_t chunk = job->len - offset;
    if (chunk > sizeof(scaled)) {
      chunk = sizeof(scaled);
    }
    if (jh_audio_volume >= 100) {
      written += jh_spk.write(job->data + offset, chunk);
    }
    else {
      size_t samples = chunk / 2;
      const int16_t *src = (const int16_t *)(job->data + offset);
      for (size_t i = 0; i < samples; i++) {
        scaled[i] = (int16_t)(((int32_t)src[i] * jh_audio_volume) / 100);
      }
      written += jh_spk.write((const uint8_t *)scaled, samples * 2);
    }
    offset += chunk;
  }
  jh_log("[spk] played %u/%u bytes at %u Hz", (unsigned)written, (unsigned)job->len,
         (unsigned)job->rate);
  free(job->data);
  delete job;
  jh_audio_busy = false;
  vTaskDelete(NULL);
}

// Hand an owned PCM buffer to the speaker task. The caller copied it (or
// decoded straight into it) so this never touches the BLE write buffer: a `say`
// command can be 30 KB, and the task owns the memory until it finishes.
static bool audio_start(uint8_t *data, size_t len, uint32_t rate) {
  if (!jh_audio_up) {
    free(data);
    jh_log("[spk] not initialised; dropping %u bytes", (unsigned)len);
    return false;
  }
  if (jh_audio_busy) {
    free(data);
    jh_log("[spk] busy; dropping %u bytes", (unsigned)len);
    return false;
  }
  if (len < 2) {
    free(data);
    return false;
  }
  jh_audio_job_t *job = new jh_audio_job_t;
  if (!job) {
    free(data);
    return false;
  }
  job->data = data;
  job->len = len;
  job->rate = rate ? rate : JH_AUDIO_RATE;
  jh_audio_busy = true;
  if (xTaskCreatePinnedToCore(audio_task, "jh-say", 4096, job, 2, NULL, 1) != pdPASS) {
    jh_audio_busy = false;
    free(data);
    delete job;
    jh_log("[spk] no task");
    return false;
  }
  return true;
}

bool audio_play_pcm(const uint8_t *data, size_t len, uint32_t rate) {
  // Raw PCM is what the house's TTS stream looks like once its base64 wrapper is
  // off: signed 16-bit little-endian samples, mono. Reject anything else here
  // rather than let the amp turn it into noise.
  if (!data || len < 2) {
    return false;
  }
  uint8_t *copy = (uint8_t *)heap_caps_malloc(len, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (!copy) {
    copy = (uint8_t *)malloc(len);
  }
  if (!copy) {
    return false;
  }
  memcpy(copy, data, len);
  return audio_start(copy, len, rate ? rate : JH_AUDIO_RATE);
}

static uint16_t wav_u16(const uint8_t *p) {
  return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t wav_u32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

bool audio_play_wav(const uint8_t *data, size_t len) {
  // RIFF/WAVE with a canonical fmt chunk. This walks the chunks instead of
  // assuming the 44-byte header: a TTS server is free to add a LIST chunk, and
  // an assumed offset then plays the metadata as a click.
  if (!data || len < 44 || memcmp(data, "RIFF", 4) != 0 || memcmp(data + 8, "WAVE", 4) != 0) {
    return false;
  }
  uint16_t format = 0, channels = 0, bits = 0;
  uint32_t rate = 0;
  const uint8_t *pcm = nullptr;
  size_t pcm_len = 0;
  size_t pos = 12;
  while (pos + 8 <= len) {
    uint32_t chunk = wav_u32(data + pos + 4);
    if (memcmp(data + pos, "fmt ", 4) == 0 && pos + 8 + 16 <= len) {
      format = wav_u16(data + pos + 8);
      channels = wav_u16(data + pos + 10);
      rate = wav_u32(data + pos + 12);
      bits = wav_u16(data + pos + 22);
    }
    else if (memcmp(data + pos, "data", 4) == 0) {
      pcm = data + pos + 8;
      pcm_len = chunk;
      if (pos + 8 + pcm_len > len) {
        pcm_len = len - (pos + 8);
      }
      break;
    }
    pos += 8 + chunk + (chunk & 1);
  }
  if (!pcm || !pcm_len) {
    jh_log("[spk] wav has no data chunk");
    return false;
  }
  if (format != 1 || channels != 1 || bits != 16) {
    jh_log("[spk] wav unsupported (format=%u ch=%u bits=%u); want PCM mono 16-bit",
           format, channels, bits);
    return false;
  }
  return audio_play_pcm(pcm, pcm_len, rate ? rate : JH_AUDIO_RATE);
}

bool audio_busy() {
  return jh_audio_busy;
}
