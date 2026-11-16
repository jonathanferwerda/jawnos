// ---- haptics: a tick you can feel ------------------------------------------
// A coin vibration motor on D1 (GPIO 2). The GPIO cannot drive the motor
// directly: a coin motor wants 60-100 mA, more than the pin can source, so the
// build needs a small NPN/MOSFET low-side switch and a flyback diode across the
// motor. The firmware only owns the PWM gate.
//
// The motor has a dead zone: below roughly a quarter duty it buzzes weakly or
// not at all, which is why a strength of 1 still gets a minimum pulse. That is
// the same behaviour the panel's strength slider has to account for.
#define JH_HAPTIC_PIN       2      // D1
#define JH_HAPTIC_CHANNEL   1      // LEDC channel 1: the camera's XCLK owns 0
#define JH_HAPTIC_PULSE_MS  120
#define JH_HAPTIC_MIN_DUTY  70     // out of 255; below this a coin motor stalls

static bool jh_haptic_up = false;
static volatile uint32_t jh_haptic_until = 0;

void haptics_init() {
  jh_haptic_up = ledcAttachChannel(JH_HAPTIC_PIN, 1000, 8, JH_HAPTIC_CHANNEL);
  ledcWrite(JH_HAPTIC_PIN, 0);
  jh_log("[hap] motor on gpio %d (%s)", JH_HAPTIC_PIN, jh_haptic_up ? "pwm" : "FAILED");
}

// strength 0-100. A tick is a pulse, not a level: the next haptics_update()
// ends it. That keeps the BLE handler fast and stops a dropped link from
// leaving the motor running.
void haptics_tick(int strength) {
  if (!jh_haptic_up) {
    return;
  }
  if (strength <= 0) {
    ledcWrite(JH_HAPTIC_PIN, 0);
    jh_haptic_until = 0;
    return;
  }
  if (strength > 100) {
    strength = 100;
  }
  int duty = strength * 255 / 100;
  if (duty < JH_HAPTIC_MIN_DUTY) {
    duty = JH_HAPTIC_MIN_DUTY;
  }
  ledcWrite(JH_HAPTIC_PIN, (uint32_t)duty);
  jh_haptic_until = millis() + JH_HAPTIC_PULSE_MS;
}

void haptics_update() {
  if (jh_haptic_until && (int32_t)(millis() - jh_haptic_until) >= 0) {
    ledcWrite(JH_HAPTIC_PIN, 0);
    jh_haptic_until = 0;
  }
}
