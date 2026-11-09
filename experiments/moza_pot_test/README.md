# Moza pot test

Turn a potentiometer on an Arduino Nano, and the Moza R5 wheel turns to match.

## How it works

- **Arduino** (`arduino/moza_pot/moza_pot.ino`) reads the pot on A0 (16 reads summed, so `0..16368`) and sends it as a text line about every 5 ms (115200 baud). The sketch and the app must match: an old sketch sending `0..1023` only moves the wheel a tiny bit.
- **PC app** (`pc/MozaPot`) creates a DirectInput **spring** force-feedback effect on the wheel and moves the spring's centre point to wherever the pot says. The wheel base's own firmware then pulls the wheel to that angle. No Moza SDK needed: it is the same standard FFB that games use. The FFB updates run on their own thread at about 250 Hz.

The spring offset covers ±half of the rotation angle set in Pit House. The **Range %** box scales that down: with 900° in Pit House and 25 %, the pot covers about ±112°.

## Wiring

Pot outer legs to **5V** and **GND**, wiper to **A0**.

## Run

1. Upload the sketch (Arduino IDE, board "Arduino Nano"; try "ATmega328P (Old Bootloader)" if the upload fails).
2. Close the Arduino Serial Monitor, since only one program can have the COM port open.
3. `dotnet run --project pc/MozaPot`
4. Pick the COM port, then press **Start**. **Keep your hands off the wheel**: it moves by itself.
5. Tune:
   - **Spring**: how hard the wheel is pulled to the target. Raise it if the wheel is sluggish or stops short.
   - **Damping**: a damper effect (force against wheel speed) that adds to Pit House's damping. Raise it if the wheel overshoots.
   - **Max speed %/s**: how fast the target may move (100 = centre to full lock in 1 s, 0 = no limit). A fast pot flick becomes a ramp the wheel can follow instead of a jump it overshoots.
   - **Smoothing ms**: rounds off the target so it glides instead of moving in small steps. Raise it if the wheel vibrates while moving slowly. Too high makes the wheel lag behind the pot.
   - **Deadband**: no spring force when the wheel is this close to the target (same -10000..10000 scale). Try 20-50 if the wheel buzzes around the target.

## If the wheel vibrates

- Set **Damping** to 0 and see if the vibration goes away. At low speeds the base's speed estimate is noisy, so a strong damper (here or in Pit House) can buzz. Use the lowest damping that still stops the overshoot.
- If it buzzes even when the pot is still, raise **Deadband** a little, or lower **Spring**.
- If it only vibrates while moving slowly, raise **Smoothing ms**.

## If the wheel doesn't move

- Check that Pit House's game FFB strength isn't 0 or very low. Spring/condition effects go through the same game-FFB path.
- Close any game or tool that might hold the wheel's FFB exclusively.
- The app takes the first FFB device with "MOZA" in its name (shown as `Device:` in the window). The steering axis is assumed to be X.
