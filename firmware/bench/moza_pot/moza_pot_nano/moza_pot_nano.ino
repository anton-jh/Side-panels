// Moza pot test - Arduino Nano side.
//
// Wiring: potentiometer ends to 5V and GND, wiper to A0.
// Sends the (lightly smoothed) pot reading, 0..1023, as one text line
// about 100 times per second at 115200 baud. Open the Serial Monitor to
// check it before running the PC program.

const int POT_PIN = A0;

float smoothed = 512;

void setup() {
  Serial.begin(115200);
  smoothed = analogRead(POT_PIN);
}

void loop() {
  // Simple low-pass filter so ADC jitter doesn't make the wheel buzz.
  smoothed += (analogRead(POT_PIN) - smoothed) * 0.2f;
  Serial.println((int)(smoothed + 0.5f));
  delay(10);
}
