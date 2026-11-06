static void tilt_serial_command(String line) {
  line.trim();
  line.toLowerCase();
  if (line == "tiltdbg on") {
    tiltDbg = true;
    Serial.println("[tilt] debug on");
  }
  else if (line == "tiltdbg off") {
    tiltDbg = false;
    Serial.println("[tilt] debug off");
  }
  else if (line == "tilt on") {
    tiltWake = true;
    configSave();
    Serial.println("[tilt] wrist wake on");
  }
  else if (line == "tilt off") {
    tiltWake = false;
    configSave();
    Serial.println("[tilt] wrist wake off");
  }
  else if (line == "tiltsim") {
    // feed the machine raises without moving the watch, using the poses the
    // 2026-10-09 captures actually held; the real sensor samples are ignored
    // while this runs. If a raise is said while dozing, the doze should end
    // and the screen sit for a short look.
    wrist_sim = true;
    // phase 1: the worn raise -- arm hanging at the side, then a fast turn up
    // to the face (the real dwell settled at z 7.4). Must detect.
    wristPollReset();
    for (int i = 0; i < 40; i++) { wristPollStep(-0.6f, 9.6f, -1.1f, millis()); delay(30); }
    for (int i = 0; i <= 8; i++) {
      float t = i / 8.0f;
      wristPollStep(-0.6f - 5.6f * t, 9.6f - 8.0f * t, -1.1f + 8.5f * t, millis());
      delay(30);
    }
    bool look = false;
    for (int i = 0; i < 20; i++) {
      if (wristPollStep(-6.2f, 1.6f, 7.4f, millis())) { look = true; }
      delay(30);
    }
    // phase 2: the walk -- the arm swinging (the pose it holds while walking)
    // turning up to a reading look (z 7.0, the worn pose on the user's right
    // arm). Must detect even though the arm was moving.
    wristPollReset();
    for (int i = 0; i < 40; i++) { wristPollStep(8.0f, -3.0f, 1.0f, millis()); delay(30); }
    for (int i = 0; i <= 8; i++) {
      float t = i / 8.0f;
      wristPollStep(8.0f - 7.5f * t, -3.0f + 9.5f * t, 1.0f + 6.0f * t, millis());
      delay(30);
    }
    bool pickup = false;
    for (int i = 0; i < 20; i++) {
      if (wristPollStep(0.5f, 6.5f, 7.0f, millis())) { pickup = true; }
      delay(30);
    }
    // phase 3: the reading look coming back down to the arm-at-side (the
    // walking swing). Must stay quiet: it settles outside the look window.
    wristPollReset();
    for (int i = 0; i < 40; i++) { wristPollStep(0.5f, 6.5f, 7.0f, millis()); delay(30); }
    for (int i = 0; i <= 8; i++) {
      float t = i / 8.0f;
      wristPollStep(0.5f + 7.5f * t, 6.5f - 9.5f * t, 7.0f - 6.0f * t, millis());
      delay(30);
    }
    bool set_down = false;
    for (int i = 0; i < 20; i++) {
      if (wristPollStep(8.0f, -3.0f, 1.0f, millis())) { set_down = true; }
      delay(30);
    }
    wrist_sim = false;
    Serial.printf("[tiltsim] worn raise=%s walk=%s back=%s\n",
                  look ? "detected" : "MISSED", pickup ? "detected" : "MISSED",
                  set_down ? "FIRED" : "quiet");
    if ((look || pickup) && dozing) {
      Serial.println("[tilt] wrist raise: lighting the screen (sim)");
      tilt_wake_short = true;
      pmuIrq = true;
    }
  }
  else if (line == "tilt now") {
    // a short blocking capture on the same machine the doze loop feeds: move
    // the arm during it and the answer is whatever the machine decides
    bool was = tiltDbg;
    tiltDbg = true;
    uint32_t until = millis() + 3000;
    bool got = false;
    while ((int32_t)(until - millis()) > 0) {
      if (wristPoll()) { got = true; break; }
      delay(20);
    }
    Serial.println(got ? "[tilt] now: raise detected" : "[tilt] now: no raise");
    tiltDbg = was;
  }
  else if (line == "tilt status") {
    Serial.printf("[tilt] wake=%d dbg=%d armed=%d rose=%d have=%d lz=%.1f sz=%.1f\n",
                  (int)tiltWake, (int)tiltDbg, (int)wrist_armed, (int)wrist_rose,
                  (int)wrist_have, wrist_lz, wrist_sz);
  }
  else if (line == "vol+" || line == "vol up" || line == "vol-" || line == "vol down") {
    // The watch has no Vol+/- key of its own yet (the Configure slider is this
    // watch's speaker), so this is the hook a key or a face calls. It sends the
    // house volume tap over BLE; the Pico or the bridge carries it to the
    // manager and the volume_result arrives on loop2.
    int delta = (line.endsWith("+") || line == "vol up") ? 5 : -5;
    bool sent = house_volume_tap(delta, "all");
    Serial.println(sent ? "[vol] sent over BLE" : "[vol] no BLE link");
  }
  else if (line == "crown") {
    // press the crown, then run this: does the PMU latch the event at all?
    uint64_t status = watch.pmic.irq().readStatus();
    Serial.printf("[crown] status=0x%llx short=%d long=%d\n",
                  (unsigned long long)status,
                  (int)watch.pmic.irq().isPekeyShortPress(status),
                  (int)watch.pmic.irq().isPekeyLongPress(status));
  }
  else if (line == "sleeptest") {
    // what the light-sleep entry arms, and what the IDF says about it. Run it
    // over USB: the sleep itself needs the cable out, but validation does not.
    watch.pmic.irq().readStatus();
    rtc_gpio_pullup_en((gpio_num_t)PMU_INT);
    rtc_gpio_pulldown_dis((gpio_num_t)PMU_INT);
    esp_err_t e1 = esp_sleep_enable_ext1_wakeup(_BV(PMU_INT), ESP_EXT1_WAKEUP_ALL_LOW);
    esp_err_t e2 = gpio_wakeup_enable((gpio_num_t)SENSOR_INT, GPIO_INTR_HIGH_LEVEL);
    esp_err_t e3 = esp_sleep_enable_gpio_wakeup();
    Serial.printf("[sleeptest] ext1=%d gpio_enable=%d gpio_wakeup=%d pmu_int=%d sensor_int=%d\n",
                  (int)e1, (int)e2, (int)e3, (int)PMU_INT, (int)SENSOR_INT);
    esp_sleep_disable_wakeup_source(ESP_SLEEP_WAKEUP_ALL);
  }
  else if (line == "crumb") {
    crumbs_dump();
  }
  else if (line == "tiltlog on") {
    tilt_log_flush();
    deleteFile(FFat, TILT_LOG_PATH);
    tilt_log_bytes = 0;
    tiltLog = true;
    Serial.println("[tiltlog] logging poses to " TILT_LOG_PATH);
  }
  else if (line == "tiltlog off") {
    tiltLog = false;
    tilt_log_flush();
    Serial.printf("[tiltlog] stopped, %u bytes\n", (unsigned)tilt_log_bytes);
  }
  else if (line == "tiltlog clear") {
    tiltLog = false;
    tilt_log_len = 0;
    tilt_log_buf[0] = '\0';
    tilt_log_bytes = 0;
    deleteFile(FFat, TILT_LOG_PATH);
    Serial.println("[tiltlog] cleared");
  }
  else if (line == "tiltlog dump") {
    // printed in chunks: one huge Serial.print has wedged the USB console before
    File f = FFat.open(TILT_LOG_PATH, "r");
    if (!f) {
      Serial.println("[tiltlog] none");
    }
    else {
      Serial.printf("[tiltlog] %u bytes\n", (unsigned)f.size());
      char buf[256];
      while (f.available()) {
        int k = f.read((uint8_t *)buf, sizeof(buf) - 1);
        if (k <= 0) {
          break;
        }
        buf[k] = '\0';
        Serial.print(buf);
        delay(2);
      }
      Serial.println("[tiltlog] end");
      f.close();
    }
  }
  else if (line == "crash") {
    // test the breadcrumb path: the next boot should say "crash test"
    crumb("crash test");
    Serial.println("[crumb] aborting now");
    Serial.flush();
    abort();
  }
  else if (line == "heap") {
    // what a room push has to work with: the largest single block matters as
    // much as the total, because the payload needs one contiguous ~25 KB, and
    // the display's SPI flush takes its bounce from the DMA-capable pool - the
    // failures show up there first ("setup_dma_priv_buffer")
    Serial.printf("[heap] free=%u max=%u min=%u psram=%u/%u\n",
                  (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getMaxAllocHeap(),
                  (unsigned)ESP.getMinFreeHeap(),
                  (unsigned)ESP.getFreePsram(), (unsigned)ESP.getPsramSize());
    Serial.printf("[heap] int=%u int_max=%u dma=%u dma_max=%u dma_min=%u\n",
                  (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                  (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL),
                  (unsigned)heap_caps_get_free_size(MALLOC_CAP_DMA),
                  (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_DMA),
                  (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_DMA));
  }
  else if (line.startsWith("heapfast")) {
    // sample the DMA pool fast while a known-triggering sequence runs (a clip
    // shipping while the screen repaints): the LCD's per-flush bounce fails in a
    // dip that the one-shot 'heap' can miss. On core 0 so the ui keeps drawing.
    int secs = line.substring(8).toInt();
    xTaskCreatePinnedToCore(heapfast_task, "heapfast", 3072, (void *)(intptr_t)secs, 1, NULL, 0);
  }
  else if (line == "awake") {
    // hold the screen on for console-driven testing (voice, LCD): rebase the
    // timeout the way a touch does, so a probe needs no hand on the watch
    buttonMillis = millis();
    wrist_look_watch = false;
    Serial.println("[console] screen timeout rebased");
  }
  else if (line == "time") {
    // the watch face reads the hardware clock; this says what both of them hold
    struct tm pcf_tm = {};
    watch.rtc.getDateTime(&pcf_tm);
    Serial.printf("[rtc] pcf %04d-%02d-%02d %02d:%02d:%02d | esp %s | offset %ld\n",
                  pcf_tm.tm_year + 1900, pcf_tm.tm_mon + 1, pcf_tm.tm_mday,
                  pcf_tm.tm_hour, pcf_tm.tm_min, pcf_tm.tm_sec,
                  rtc.getTime("%Y-%m-%d %H:%M:%S").c_str(), offset);
  }
  else if (line == "blestop on") {
    ble_state_off = true;   // the watch stops asking, the phone stops pushing
    Serial.println("[ble] state requests off");
  }
  else if (line == "blestop off") {
    ble_state_off = false;
    Serial.println("[ble] state requests on");
  }
  else if (line == "voicedbg on") {
    voiceDbg = true;
    Serial.println("[voice] debug on");
  }
  else if (line == "voicedbg off") {
    voiceDbg = false;
    Serial.println("[voice] debug off");
  }
  else if (line == "voice") {
    // one hands-free capture: record on speech, stop on silence, ship the clip
    // to the homebase for whisper. The console trigger exists so the VAD can be
    // tuned over USB without touching the UI.
    Serial.println("[voice] listening for a command");
    voiceListenStart(true);
  }
  else if (line.startsWith("vtrig")) {
    // pick the voice model from the console, for tuning over USB: the panel's
    // Now Me push is unreliable over BLE. "vtrig hey_jawn" / "vtrig vad" / "vtrig off".
    String m = line.substring(5);
    m.trim();
    voice_trigger = m;
    Serial.printf("[voice] trigger '%s'\n", voice_trigger.c_str());
    voiceCaptureEnabled = (m.length() && m != "off");
    voiceListening = false;          // let any running listener exit so the model reloads
    delay(150);
    if (voiceCaptureEnabled) { voiceListenStart(false); }
  }
  else if (line.startsWith("vfloor")) {
    // the end-of-speech floor, for tuning over USB: "vfloor auto" follows the
    // room, "vfloor 1800" pins it. The room figure the auto floor rides on is
    // printed beside it, so an adjustment is a measurement and not a guess.
    String f = line.substring(6);
    f.trim();
    voice_floor = f.length() ? f : "auto";
    Serial.printf("[voice] floor '%s' (room %u -> %u)\n", voice_floor.c_str(),
                  (unsigned)voice_ambient_rms, (unsigned)voice_end_floor());
  }
  else if (line == "blecycle") {
    // exercise the async bring-up the way a wake does: tear the radio down, then
    // start it from the core-0 task. Run it over USB to prove the task path is
    // sound without needing the cable out.
    Serial.println("[ble] cycle: stop, then async start");
    stop_ble_transfer();
    ble_start_async();
  }
  else if (line == "blesim") {
    // reproduce a 25 KB room push without the phone: same message, same queue,
    // none of the BLE task; if this survives, the panic lives in the radio path.
    // The base is captured once: pushing the payload back into itself would
    // grow the message every run and the sizes would stop being the phone's.
    static String blesim_base;
    if (blesim_base.length() == 0) {
      blesim_base = before_me;
    }
    String pad = "";
    while (pad.length() < 20000) {
      pad += "pad-pad-pad-pad-pad-pad-pad-pad-pad-";
    }
    String inner = blesim_base.substring(1, blesim_base.length() - 1);
    String msg = "{\"type\":\"room\",\"data\":{\"room\":1,\"payload\":{\"pad\":\"" + pad + "\"," + inner + "}}}";
    Serial.printf("[blesim] queueing %u bytes\n", (unsigned)msg.length());
    queue_ble_message(msg);
  }
  else if (line.startsWith("blesimframe")) {
    // the same push as blesim, but through the daemon's framing and split into
    // the 52 chunks it really arrives in, fed from a task with the BLE stack's
    // own stack budget: this is the reassembly path, exercisable without the phone
    int rounds = line.substring(11).toInt();
    if (rounds <= 0) {
      rounds = 1;
    }
    static String blesimframe_base;
    if (blesimframe_base.length() == 0) {
      blesimframe_base = before_me;
    }
    Serial.printf("[blesimframe] %d round(s)\n", rounds);
    xTaskCreatePinnedToCore(blesimframe_task, "bleSimTask", 3584, (void *)(intptr_t)rounds, 1, NULL, 0);
  }
}

static void tilt_serial_poll() {
  static String line;
  while (Serial.available()) {
    int c = Serial.read();
    if (c == '\r') {
      continue;
    }
    if (c == '\n') {
      tilt_serial_command(line);
      line = "";
    }
    else if (line.length() < 48) {
      line += (char)c;
    }
  }
}

void lowPowerEnergyHandler()
{
  Serial.println("Enter light sleep mode!");
 
  buttonMillis = 0;
  brightnessLevel = watch.getBrightness();
  tilt_log_marker("sleep br", brightnessLevel);
  // straight to black: the 65-step fade cost a few hundred ms of the user's
  // "slow to turn the screen off" and bought nothing
  watch.setBrightness(0);

  sportsIrq = false;
  pmuIrq = false;
  // any marker from a past raise is about that wake, not this one
  tilt_wake_short = false;
  // going back down cancels a radio restore the last wake scheduled: a glance
  // that ended before it came due should never pay the bring-up
  ble_restore_at = 0;
  if (WiFi.status() == WL_CONNECTED && buttoned_before && homebaseIP.length() > 0) {
    String req = "https://" + homebaseIP + "/watch/next_appt?format=sleep";
    Serial.println(req);
    wakeup_time = 0;
    String wakeup_string = https_request(req);
    if (wakeup_string != "failure") {
      Serial.println(wakeup_string);
      notifications = JSON.parse(wakeup_string);

    }
    notifications_processor();

  }
  else { notifications_processor(); }
  //TODO: Low power consumption not debugged
  configSave();
 // Serial.flush(); 
  watch.sleepDisplay();

  // everything from here until the screen is back is "asleep": the crown click
  // that ends a real light sleep is still latched in the PMU, and without this it
  // would read as a click while awake and put the watch straight back to sleep
  dozing = true;
  wrist_look_watch = false;   // the glance ends with the screen
  wristPollReset();    // both sleep paths start their pose from scratch

  if (lightSleep && !watch.isUsbIn()) {
    
    Serial.println("right before sleep");
    crumb("ls enter");
    // a latched PMU event keeps PMU_INT pulled low, and EXT1 would read that as
    // "the crown is being held" and bounce straight back out of the sleep
    watch.pmic.irq().readStatus();
    // the pin is pulled up in the digital domain, but the RTC pad has its own
    // pull state that has to be set for the wake to be seen
    rtc_gpio_pullup_en((gpio_num_t)PMU_INT);
    uint64_t wakeup_pin = _BV(PMU_INT);
    esp_sleep_enable_ext1_wakeup((wakeup_pin), ESP_EXT1_WAKEUP_ALL_LOW);
    // the sensor line is active high and level triggered, so it cannot ride
    // EXT1's one level setting along with the crown's active-low PMU_INT; the
    // GPIO wake configures the pin on its own. Any tilt/tap/step already
    // latched is drained first, so the sleep does not bounce back up on a
    // stale event.
    watch.loopSensor();
    // The sensor line is deliberately NOT a wake source: this board's sensor
    // interrupt pin is the one that crash-looped the radio when wired up (see
    // settingSensor), and a raise only needs a sample every 100 ms, which the
    // nap timer already gives. So the crown rides EXT1 alone and nothing
    // competes with the button for the wake (2026-10-10).
 
    int default_wakeup = (60 * 60 * 3);
    int64_t notify_us = -1;      // no notification scheduled: sleep until a pin moves
    if (wakeup_time != 0) {
      if (wakeup_time > default_wakeup) {
        wakeup_time = default_wakeup;
      }
      Serial.printf("Waking in %ld seconds\n", (long)wakeup_time);
      notify_us = (int64_t)wakeup_time * 1000000LL;
    }
    bool temp_bt_enabled = bt_enabled;
    stop_ble_transfer();
    // Only the crown may wake the chip from here: with the battery and charger
    // IRQs enabled, any VBUS or charge event would assert the PMU line and
    // bounce the chip out of light sleep. This is the masking the library's own
    // lightSleep() uses; the full set is restored once the naps are over.
    watch.pmic.irq().disable(AXP2101Irq::IRQ_ALL_MASK);
    watch.pmic.irq().enable(AXP2101Irq::IRQ_PEKEY_SHORT_PRESS | AXP2101Irq::IRQ_PEKEY_LONG_PRESS);
    watch.pmic.irq().clearStatus();

    // Only the crown (EXT1) and the nap timer wake the chip. While the wrist
    // raise is on the naps stay short, so a stall in here is a bug, not a long
    // sleep: put the main task on the watchdog so a hang reboots the watch
    // instead of leaving a dead, dark screen that only a power cycle clears
    // (2026-10-10). Only a raise that passes the state machine earns the screen.
    bool wdt_here = tiltWake && (esp_task_wdt_add(NULL) == ESP_OK);
    bool wrist_wake = false;
    bool ext1_warned = false;
    uint32_t last_real_nap = millis();
    uint32_t sleep_began = millis();
    esp_sleep_wakeup_cause_t wakeup_reason = ESP_SLEEP_WAKEUP_UNDEFINED;
    while (true) {
      // Pump the library's own event path before the sleep decision: the doze
      // loop catches the crown through it, and here it is a second, independent
      // way to see a press alongside the direct PMU status read below.
      watch.loop();
      if (wdt_here) {
        esp_task_wdt_reset();
      }
      if (pmuIrq) {
        pmuIrq = false;
        Serial.println("[tilt] crown latched between naps");
        crumb("ls crown latched");
        wakeup_reason = ESP_SLEEP_WAKEUP_EXT1;
        break;
      }
      // A crown press latched while the chip was up between naps must not be
      // slept through: reading the status reports it and clears the latch, so
      // EXT1 is armed against a clean line. The doze path catches presses the
      // same way.
      if (crown_irq_pending()) {
        Serial.println("[tilt] crown latched between naps");
        crumb("ls crown latched");
        wakeup_reason = ESP_SLEEP_WAKEUP_EXT1;
        break;
      }
      if (millis() - last_real_nap > 15000) {
        // fifteen seconds without one real nap: something (a phantom PMU level)
        // is bouncing every sleep. Come back up rather than stay dark and
        // unpressable.
        Serial.println("[tilt] no real nap for 15s; waking");
        crumb("ls no-nap wake");
        wrist_wake = true;
        break;
      }
      int64_t remaining_us = notify_us;
      if (notify_us > 0) {
        remaining_us = notify_us - (int64_t)(millis() - sleep_began) * 1000LL;
        if (remaining_us <= 0) {
          wakeup_reason = ESP_SLEEP_WAKEUP_TIMER;
          break;                  // the notification is due
        }
      }
      int64_t nap_us = remaining_us;
      if (tiltWake) {
        // The raise machine needs a sample every ~100 ms at rest and every
        // ~40 ms while the arm is doing something (WRIST_REST_MS/WRIST_ARM_MS).
        // A 200 ms nap only gave it 5 Hz, and a raise whose turn happened
        // between two samples was rejected — that is why wrist wake worked
        // with light sleep off (the doze loop polls at ~15 ms) and not with it
        // on. 100 ms is the machine's own "still" rate; a fast turn pulls the
        // next naps down to 40 ms.
        int64_t poll_us = (millis() < wrist_fast_until) ? 40000LL : 100000LL;
        if (nap_us < 0 || poll_us < nap_us) {
          nap_us = poll_us;
        }
      }
      if (nap_us > 0) {
        esp_sleep_enable_timer_wakeup((uint64_t)nap_us);
      }
      rtc_gpio_pullup_en((gpio_num_t)PMU_INT);
      rtc_gpio_pulldown_dis((gpio_num_t)PMU_INT);
      esp_err_t ext1_arm = esp_sleep_enable_ext1_wakeup(_BV(PMU_INT), ESP_EXT1_WAKEUP_ALL_LOW);
      if (ext1_arm != ESP_OK && !ext1_warned) {
        // if this ever fails the crown cannot wake the watch from light sleep;
        // say so once instead of sleeping into a dead button
        Serial.printf("[sleep] ext1 arm failed: %d\n", (int)ext1_arm);
        crumb("ls ext1 arm fail");
        ext1_warned = true;
      }
      uint32_t nap_began = millis();
      esp_light_sleep_start();
      if (millis() - nap_began > 50) {
        last_real_nap = millis();
      }
      wakeup_reason = esp_sleep_get_wakeup_cause();
      // The cause names one source; read the PMU too, so a press the EXT1
      // wakeup missed is still caught before the decision (2026-10-10).
      if (wakeup_reason != ESP_SLEEP_WAKEUP_EXT1 && crown_irq_pending()) {
        Serial.println("[tilt] crown found latched after a nap");
        crumb("ls crown after nap");
        wakeup_reason = ESP_SLEEP_WAKEUP_EXT1;
      }
      if (wakeup_reason == ESP_SLEEP_WAKEUP_EXT1) {
        // the press was meant for the sleep; read the status once more so the
        // awake path does not handle the same click as a fresh one
        watch.pmic.irq().readStatus();
        crumb("ls crown");
        break;                    // the crown
      }
      if (wakeup_reason == ESP_SLEEP_WAKEUP_TIMER && tiltWake) {
        // a nap, not the notification (that is checked at the top): sample the
        // wrist and sink back down
        watch.loopSensor();
        // The nap paces the sampling here, but wristPoll's throttle is the same
        // 100 ms as the nap: a nap that returned a hair early failed `now -
        // wrist_last_sample < interval` and skipped its sample, so the arm's
        // turn could fall between two of them. The pose log replays a look on
        // every sample while the wrist missed it -- so take this nap's sample.
        wrist_last_sample = 0;
        if (wristPoll()) {
          wrist_wake = true;
          tilt_log_marker("ls raise", (long)(wrist_lz * 10));
          crumb("ls raise");
          break;
        }
        continue;
      }
      break;                      // the notification timer, or a refused sleep
    }
    if (wdt_here) {
      esp_task_wdt_delete(NULL);
    }
    Serial.println("right after sleep");
    crumb("ls exit");
    // the awake watch wants the whole event set back (charger, battery, key)
    watch.pmic.irq().disable(AXP2101Irq::IRQ_ALL_MASK);
    watch.pmic.irq().enable(
      AXP2101Irq::IRQ_VBUS_INSERT |
      AXP2101Irq::IRQ_VBUS_REMOVE |
      AXP2101Irq::IRQ_BAT_CHG_START |
      AXP2101Irq::IRQ_BAT_CHG_DONE |
      AXP2101Irq::IRQ_PEKEY_SHORT_PRESS |
      AXP2101Irq::IRQ_PEKEY_LONG_PRESS);
    watch.pmic.irq().clearStatus();
    // the screen comes back before the radio: the BLE stack takes seconds to
    // come up, and waking it first left the display dark while it did
    // instant, like the sleep side: no fade to sit through on the way up
    watch.setBrightness(brightnessLevel);
    tilt_log_marker("ls wake br", watch.getBrightness());
    if (temp_bt_enabled == true) {
      // off the wake's critical path: the screen is already back. A wrist glance
      // used to skip this, but a button pressed on a freshly woken watch then had
      // no link to send over - so the radio now comes up on every wake and a tap
      // works straight away.
      ble_restore_at = millis() + 1200;
    }

    if (wrist_wake) {
      Serial.println("[tilt] wrist raise: screen up");
      tilt_wake_short = true;
    } else if (wakeup_reason == ESP_SLEEP_WAKEUP_TIMER) {
      next_notification = 0;
      crumb("ls notify");
      Serial.println("Wakeup was caused by the timer!");
      notification_display(notifications[0]["title"], notifications[0]["notification"]);
      notifications[0] = undefined;
    } else if (wakeup_reason == ESP_SLEEP_WAKEUP_EXT0 || wakeup_reason == ESP_SLEEP_WAKEUP_EXT1) {
        Serial.println("Wakeup was caused by an external GPIO button!");
    } else {
        // Returns ESP_SLEEP_WAKEUP_UNDEFINED (0) if it was a normal power-on or hard reset
        Serial.printf("Wakeup was not from sleep. Code: %d\n", wakeup_reason);
        if (wakeup_reason == ESP_SLEEP_WAKEUP_UNDEFINED) {
          // the chip refused the light sleep (an attached USB serial does that), so the
          // "sleep" returned at once; doze properly instead of bouncing the screen
          // off and on again every few seconds
          doze_until_crown();
        }
    }


  } else {
    if (lightSleep) {
      // an attached USB serial both refuses the light sleep and wakes the chip
      // straight out of it, so doze properly until the cable is out
      Serial.println("[sleep] USB is attached, dozing instead of light sleeping");
    }
    doze_until_crown();
  }
  if (brightnessLevel <= 1) {
    brightnessLevel = 20;
  }
  dozing = false;
  watch.wakeupDisplay();

  watch.setBrightness(brightnessLevel);
  tilt_log_marker("wake br", watch.getBrightness());
  Serial.println("just before frequency");
  setCpuFrequencyMhz(240);
  step_writer();
  if (tilt_wake_short) {
    // a wrist raise earns a glance, not the full timeout: arm the deadline as
    // if the full timeout had almost elapsed, leaving TILT_WAKE_LOOK_MS. A
    // touch rebases buttonMillis through touch_watch() and the full timeout
    // is back. The tail is where this belongs: loop()'s wake block can be
    // starved by the motion that always follows a raise.
    tilt_wake_short = false;
    if (DEFAULT_SCREEN_TIMEOUT > (long)TILT_WAKE_LOOK_MS) {
      buttonMillis = millis() - (uint32_t)(DEFAULT_SCREEN_TIMEOUT - TILT_WAKE_LOOK_MS);
      Serial.printf("[tilt] short wake: %ld seconds\n", (long)TILT_WAKE_LOOK_MS / 1000);
    }
    // the arm is up: keep the glance alive while it stays there and drop the
    // screen the moment it comes down (wrist_look_monitor)
    wrist_look_watch = true;
    wrist_look_since = millis();
    wrist_look_release = 0;
  }
  // the event that woke us is spent, loop() would only re-run wakeup() for it
  pmuIrq = false;
  //JSONVar dct;
  //dct["task"] = "homebasePing";
  //dualCoreTaskMaker(dct);

}

