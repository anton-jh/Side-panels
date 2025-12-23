volatile int32_t enc = 0;

void setup() {
  pinMode(7, INPUT_PULLUP); // A
  pinMode(2, INPUT_PULLUP); // B

  Serial.begin(115200);
  while (!Serial) {}

  attachInterrupt(digitalPinToInterrupt(7), encoderISR, CHANGE);
  attachInterrupt(digitalPinToInterrupt(2), encoderISR, CHANGE);
}

void loop() {
  static int32_t last = 0;

  noInterrupts();
  int32_t v = enc;
  interrupts();

  if (v != last) {
    Serial.println(v);
    last = v;
  }
}

void encoderISR() {
  static uint8_t lastState = 0;

  uint8_t a = digitalRead(7);
  uint8_t b = digitalRead(2);
  uint8_t state = (a << 1) | b;

  switch ((lastState << 2) | state) {
    case 0b0001:
    case 0b0111:
    case 0b1110:
    case 0b1000:
      enc++;
      break;

    case 0b0010:
    case 0b0100:
    case 0b1101:
    case 0b1011:
      enc--;
      break;

    default:
      // bounce / invalid → ignore
      break;
  }

  lastState = state;
}
