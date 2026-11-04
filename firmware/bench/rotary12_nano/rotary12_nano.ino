// rotary12_nano.ino
//
// Bench test for ONE "weird" 7-contact, 12-position rotary switch on an Arduino Nano
// (ATmega328P). Prints the debounced position to the serial monitor (115200 baud).
//
// Follows FIRMWARE_PLAN.md §4.2 (scan schedule) and §5.3 (decoder + debouncer):
//   * one read every 100 µs (10 kHz tick)
//   * 12 ticks in phase 1 (pin 1 pulled up), then 12 ticks in phase 2 (pin 1 sunk)
//     -> frame = 24 ticks = 2.4 ms -> one complete phase-1 + phase-2 pair at ~417 Hz
//   * the phase only changes right AFTER a read, so the next read is always settled
//   * code = last phase-1 sample + last phase-2 sample, looked up in the truth table
//   * a new position is accepted when the code has been identical for 20 ms
//     (100 ms if the jump is not to an adjacent position, or on the first reading)
//
// Wiring (no external parts needed, the Nano's internal pull-ups replace the 10 k network):
//   switch pin 1 -> D2      (read in phase 1, driven LOW by the Nano in phase 2;
//                            this replaces the BC547 on the real board)
//   switch pin 2 -> D3
//   switch pin 3 -> D4
//   switch pin 4 -> D5
//   switch pin 5 -> D6
//   switch pin 6 -> D7
//   switch pin 7 -> GND
//
// D2..D7 are bits 2..7 of port D, so one read of PIND samples all six pins at the same
// instant, just like a shift-register snapshot. (D0/D1 are the USB serial pins.)

#include <Arduino.h>

// ---------------------------------------------------------------- configuration
const uint16_t kTickUs               = 100;  // 10 kHz scan tick
const uint8_t  kTicksPerPhase        = 12;   // 4 mux slots x 3 ticks per slot
const uint32_t kRotaryStableTime     = 10;   // ms, adjacent positions
const uint32_t kRotaryJumpStableTime = 50;  // ms, non-adjacent jumps / first reading

// 1 = also print every change of the raw decoded code (for measuring contact chatter
// and tuning kRotaryStableTime, like the planned console "rotary" view).
#define LOG_CODES 0

// ---------------------------------------------------------------- truth table
// Converts "pin1 pin2 ... pin6" as written in the plan into a 6-bit value with
// pin 1 in bit 0 ... pin 6 in bit 5 (same order as the bits come out of PIND >> 2).
constexpr uint8_t bits(const char* s, uint8_t i = 0) {
  return i == 6 ? 0 : (uint8_t)(((s[i] == '1') ? 1u : 0u) << i) | bits(s, i + 1);
}

struct Entry { uint8_t p1, p2; };

const Entry kTable[12] = {
  //  phase 1          phase 2            position
  { bits("111110"), bits("011110") },  //  1
  { bits("111101"), bits("011101") },  //  2
  { bits("111011"), bits("011011") },  //  3
  { bits("110111"), bits("010111") },  //  4
  { bits("101111"), bits("001111") },  //  5
  { bits("011111"), bits("011111") },  //  6
  { bits("111111"), bits("011110") },  //  7
  { bits("111111"), bits("011101") },  //  8
  { bits("111111"), bits("011011") },  //  9
  { bits("111111"), bits("010111") },  // 10
  { bits("111111"), bits("001111") },  // 11
  { bits("111111"), bits("011111") },  // 12
};

// Returns 0..11, or -1 for a code that isn't in the table (garbage during a transition).
int8_t lookup(uint8_t p1, uint8_t p2) {
  for (int8_t i = 0; i < 12; i++) {
    if (kTable[i].p1 == p1 && kTable[i].p2 == p2) return i;
  }
  return -1;
}

// ---------------------------------------------------------------- phase control (pin 1 = D2)
// Order matters: never let D2 drive HIGH, because the switch can connect it to GND.
inline void phase2SinkPin1() {
  PORTD &= ~_BV(PD2);  // pull-up off (pin briefly floats as input, harmless)
  DDRD  |=  _BV(PD2);  // now output LOW
}

inline void phase1ReleasePin1() {
  DDRD  &= ~_BV(PD2);  // input first...
  PORTD |=  _BV(PD2);  // ...then pull-up on
}

inline uint8_t readPins() {
  return (PIND >> 2) & 0x3F;  // pin 1..6 -> bit 0..5, 1 = high
}

// ---------------------------------------------------------------- debouncer state
uint16_t lastCode     = 0xFFFF;  // (p1 << 6) | p2 of the previous decode
int8_t   lastCodePos  = -1;      // lookup() of lastCode
uint32_t stableSince  = 0;       // millis() when lastCode first appeared
int8_t   position     = -1;      // accepted position 0..11, -1 = unknown
uint32_t invalidCodes = 0;
uint32_t overruns     = 0;

void printBits(uint8_t v) {
  for (uint8_t i = 0; i < 6; i++) Serial.print((v >> i) & 1);  // pin 1 first
}

// Called once per frame (~417 Hz) with a complete phase-1 + phase-2 pair.
void decode(uint8_t p1, uint8_t p2) {
  const uint32_t now  = millis();
  const uint16_t code = ((uint16_t)p1 << 6) | p2;

  // Any change of code, valid or not, restarts the stable timer.
  if (code != lastCode) {
    lastCode    = code;
    lastCodePos = lookup(p1, p2);
    stableSince = now;
    if (lastCodePos < 0) invalidCodes++;
#if LOG_CODES
    Serial.print(now);
    Serial.print(F(" ms  p1="));
    printBits(p1);
    Serial.print(F(" p2="));
    printBits(p2);
    Serial.print(F("  -> "));
    if (lastCodePos < 0) Serial.println(F("invalid"));
    else                 Serial.println(lastCodePos + 1);
#endif
  }

  const int8_t cand = lastCodePos;
  if (cand < 0 || cand == position) return;

  const bool up       = position >= 0 && cand == (position + 1) % 12;
  const bool down     = position >= 0 && cand == (position + 11) % 12;
  const uint32_t need = (up || down) ? kRotaryStableTime : kRotaryJumpStableTime;

  if (now - stableSince < need) return;

  position = cand;
  Serial.print(F("Position "));
  Serial.print(position + 1);
  if (up)        Serial.print(F("  (up)"));
  else if (down) Serial.print(F("  (down)"));
  else           Serial.print(F("  (jump)"));
  Serial.print(F("   invalid codes: "));
  Serial.print(invalidCodes);
  Serial.print(F("   overruns: "));
  Serial.println(overruns);
}

// ---------------------------------------------------------------- setup / scan loop
void setup() {
  // D2..D7 as inputs with pull-ups (start in phase 1).
  DDRD  &= ~0xFC;
  PORTD |=  0xFC;

  Serial.begin(115200);
  Serial.println(F("rotary12 bench test"));
  Serial.print(F("tick "));
  Serial.print(kTickUs);
  Serial.print(F(" us, frame "));
  Serial.print(2UL * kTicksPerPhase * kTickUs);
  Serial.print(F(" us, stable "));
  Serial.print(kRotaryStableTime);
  Serial.print(F(" ms, jump "));
  Serial.print(kRotaryJumpStableTime);
  Serial.println(F(" ms"));
}

void loop() {
  static uint32_t nextTick = micros() + kTickUs;
  static uint8_t  tick     = 0;  // 0..23 within the frame
  static uint8_t  p1 = 0, p2 = 0;

  while ((int32_t)(micros() - nextTick) < 0) { }  // wait for the tick

  // 1. Read, tagged with the phase it was taken under.
  const uint8_t sample = readPins();
  if (tick < kTicksPerPhase) p1 = sample;
  else                       p2 = sample;

  // 2. Change the phase only right after a read (it then settles for a whole tick).
  tick++;
  if (tick == kTicksPerPhase) {
    phase2SinkPin1();
  } else if (tick == 2 * kTicksPerPhase) {
    phase1ReleasePin1();
    tick = 0;
    decode(p1, p2);  // pair complete
  }

  // 3. Schedule the next tick. If we fell behind (e.g. serial printing blocked),
  //    resync instead of bursting reads back-to-back without settle time.
  nextTick += kTickUs;
  if ((int32_t)(micros() - nextTick) >= 0) {
    overruns++;
    nextTick = micros() + kTickUs;
  }
}
