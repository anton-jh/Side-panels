# Moza pot test

Quick bench test: a potentiometer on an Arduino Nano sets the angle of a Moza R5 wheel.

## How it works

- **Nano** (`moza_pot_nano/`): reads a pot on A0 and sends `0..1023` over USB serial (115200 baud, about 100 values per second).
- **PC** (`MozaPotTest/`, C# / .NET 8, Windows only): reads those values and plays a DirectInput
  force-feedback **spring** effect on the wheel. A spring pulls the wheel towards its centre point,
  so moving that centre point makes the wheel follow the pot. The wheel's own firmware does the
  position control, and there is nothing Moza-specific here.

## Wiring

Pot outer legs to 5V and GND, wiper to A0.

## Running

1. Upload `moza_pot_nano.ino`. Check in the Serial Monitor that the numbers change as you turn the pot, then **close the Serial Monitor**, because only one program can have the port open.
2. In Moza Pit House, note the **steering wheel angle** (max rotation) and set `WheelRotationDeg` at the top of `Program.cs` to match. Also check that the game force-feedback intensity and the **spring** game-effect slider are not at 0.
3. Run it, passing the Nano's COM port:
   ```
   cd MozaPotTest
   dotnet run -- COM5
   ```
   With no argument it lists the serial ports it can see.
4. Ctrl+C stops it and the wheel goes limp.

Settings at the top of `Program.cs`: `TestRangeDeg` (how far the pot turns the wheel, 180 by default, so ±90°),
`SpringStrength` (0..10000, 3000 by default; start low) and `RampSeconds` (how long the spring takes to fade in at start-up).

Keep your hands loose on the rim the first time. The R5 can turn hard.
