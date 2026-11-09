// Moza pot test - Arduino Nano
// Wiring: pot outer legs to 5V and GND, wiper to A0.
// Sends the filtered pot reading as one text line about every 5 ms (~200 Hz).
// Each sample is 16 ADC reads summed (range 0..16368): averages out noise and gives
// finer steps than the plain 0..1023, so slow pot movements come out smoother.

const uint8_t POT_PIN = A0;
const uint8_t OVERSAMPLE = 16;  // 16 x 10-bit reads -> 0..16368 (PC side expects this range)
float filtered = 0;

uint16_t readPot() {
  uint16_t sum = 0;
  for (uint8_t i = 0; i < OVERSAMPLE; i++) sum += analogRead(POT_PIN);
  return sum;
}

void setup() {
  Serial.begin(115200);
  filtered = readPot();
}

void loop() {
  filtered += (readPot() - filtered) * 0.3f;  // simple low-pass against jitter
  Serial.println((long)(filtered + 0.5f));
  delay(3);  // + ~2 ms of ADC reads = ~5 ms per sample
}
