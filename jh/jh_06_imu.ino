// ---- IMU: which way the hat faces ------------------------------------------
// An ICM-20948 on the XIAO's default I2C pins (D4/D5, GPIO 5/6). The hat only
// needs yaw: pitch and roll do not change what "on your left" means. Yaw is
// integrated from the gyro's Z axis with the bias measured at boot, so it is
// relative to the direction the hat was powered facing, not magnetic north.
//
// That distinction is real and is a phase-0 question: a gyro-only heading drifts
// as the bias moves with temperature, and docs/hat.md's "knows which way it
// faces" eventually wants the magnetometer (the ICM-20948's AK09916). Reading
// the magnetometer needs the ICM's I2C-master mode and a calibration pass, which
// is deliberately not in this skeleton. Report a relative yaw and say so.
#define JH_I2C_SDA 5   // D4
#define JH_I2C_SCL 6   // D5
#define JH_IMU_GYRO_LSB_PER_DPS 65.5f   // GYRO_FS_SEL = 1, +/-500 dps

static uint8_t jh_imu_addr = 0;
static bool jh_imu_up = false;
static float jh_yaw = 0.0f;
static float jh_gyro_bias = 0.0f;
static uint32_t jh_imu_last_ms = 0;

static bool imu_write(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(jh_imu_addr);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

static bool imu_read(uint8_t reg, uint8_t *buf, size_t n) {
  Wire.beginTransmission(jh_imu_addr);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) {
    return false;
  }
  size_t got = Wire.requestFrom((int)jh_imu_addr, (int)n);
  if (got != n) {
    return false;
  }
  for (size_t i = 0; i < n; i++) {
    buf[i] = (uint8_t)Wire.read();
  }
  return true;
}

// The ICM-20948 splits its register map into banks selected by 0x7F. Every
// access below names the bank it assumes; forgetting one is the classic way to
// write a gyro setting into an accel register and get a silently wrong scale.
static bool imu_bank(uint8_t bank) {
  return imu_write(0x7F, (uint8_t)(bank << 4));
}

static bool imu_gyro_z_raw(int16_t *out) {
  if (!imu_bank(0)) {
    return false;
  }
  uint8_t b[2];
  // GYRO_ZOUT_H is 0x37 in bank 0; the high byte comes first.
  if (!imu_read(0x37, b, 2)) {
    return false;
  }
  *out = (int16_t)((b[0] << 8) | b[1]);
  return true;
}

bool imu_init() {
  Wire.begin(JH_I2C_SDA, JH_I2C_SCL);
  Wire.setClock(400000);

  // AD0 selects 0x68 or 0x69. Probe both rather than assume the breakout's
  // solder jumper, because clone modules ship either way.
  const uint8_t candidates[] = { 0x68, 0x69 };
  for (uint8_t i = 0; i < sizeof(candidates); i++) {
    Wire.beginTransmission(candidates[i]);
    if (Wire.endTransmission() == 0) {
      jh_imu_addr = candidates[i];
      break;
    }
  }
  if (!jh_imu_addr) {
    jh_log("[imu] no ICM-20948 on 0x68/0x69; heading unavailable");
    return false;
  }

  if (!imu_bank(0) || !imu_write(0x06, 0x80)) {
    jh_log("[imu] reset write failed at 0x%02x", jh_imu_addr);
    return false;
  }
  delay(100);
  // Wake with the internal oscillator; the default sleep bit otherwise leaves
  // every output register frozen at zero.
  if (!imu_write(0x06, 0x01)) {
    jh_log("[imu] wake failed");
    return false;
  }
  delay(50);
  if (!imu_bank(2)) {
    return false;
  }
  // GYRO_CONFIG_1: DLPFCFG=3 (~41 Hz), FS_SEL=1 (+/-500 dps), FCHOICE=1.
  // 500 dps covers a head turn without clipping; 250 does not.
  if (!imu_write(0x01, 0x1B)) {
    jh_log("[imu] gyro config failed");
    return false;
  }
  // ACCEL_CONFIG: the same DLPF setting. The hat does not use accel yet, but a
  // configured sensor is one fewer surprise when phase 1 adds tilt.
  imu_write(0x14, 0x1B);
  imu_bank(0);

  // Average the gyro at rest for the boot bias. A hat set down and powered on
  // is still; one powered while being carried will carry that motion as bias,
  // which is why jh.heading also reports ready=false until this finishes.
  int32_t sum = 0;
  int samples = 0;
  for (int i = 0; i < 200; i++) {
    int16_t raw = 0;
    if (imu_gyro_z_raw(&raw)) {
      sum += raw;
      samples++;
    }
    delay(2);
  }
  if (!samples) {
    jh_log("[imu] no gyro samples");
    return false;
  }
  jh_gyro_bias = (float)sum / (float)samples;
  jh_imu_last_ms = millis();
  jh_imu_up = true;
  jh_log("[imu] ICM-20948 at 0x%02x, z bias %.1f, relative yaw", jh_imu_addr, jh_gyro_bias);
  return true;
}

void imu_poll() {
  if (!jh_imu_up) {
    return;
  }
  uint32_t now = millis();
  float dt = (now - jh_imu_last_ms) / 1000.0f;
  if (dt <= 0.0f) {
    return;
  }
  // A loop that stalled (a serial write, a long flash erase) must not integrate
  // the whole gap at full rate: cap the step so the yaw stays believable.
  if (dt > 0.25f) {
    dt = 0.25f;
  }
  jh_imu_last_ms = now;
  int16_t raw = 0;
  if (!imu_gyro_z_raw(&raw)) {
    return;
  }
  float dps = ((float)raw - jh_gyro_bias) / JH_IMU_GYRO_LSB_PER_DPS;
  // A still gyro reads a fraction of a dps of noise; without a deadband the
  // integrated yaw walks a few degrees a minute while the hat sits on the desk.
  if (fabsf(dps) < 0.6f) {
    dps = 0.0f;
  }
  jh_yaw += dps * dt;
  while (jh_yaw < 0.0f) {
    jh_yaw += 360.0f;
  }
  while (jh_yaw >= 360.0f) {
    jh_yaw -= 360.0f;
  }
}

float imu_yaw_degrees() {
  return jh_yaw;
}

bool imu_ready() {
  return jh_imu_up;
}
