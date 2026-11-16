void jawn_loop() {
  // One loop, no display: the work is all housekeeping. Each part owns its own
  // task where it can block (camera POST, audio playback, microphone), so this
  // function must never wait on a radio or a DMA read.
  ble_loop();       // deferred radio start + queued jh.* commands
  config_serial_loop(); // JHCONF provisioning on the USB console
  imu_poll();       // integrate the gyro; cheap at 80 MHz
  haptics_update(); // stop the motor when its pulse ends
  ota_loop();       // WiFi retry, /device_query and /update

  // A small yield keeps the idle task and the radio tasks fed. The BLE and
  // camera work runs on its own task regardless; this only stops the loop from
  // spinning a core at 100% for no reason.
  delay(5);
}
