# Firmware plan: Board A and Board B

Status: **draft for discussion.** Nothing here is final. Assumptions are marked
**(assumption)**, and the questions that need your input are collected in
[§13 Open questions](#13-open-questions).

---

## 0. Summary

```
            ┌──────────────────────── Board B (optional) ───────────────────────┐
            │  Scanner ──► Input processing ──► InputState ──► Link TX (UART)   │
            │  (shared)     (shared)             (shared)       (shared)        │
            └──────────────────────────────────────────────────────────┬────────┘
                                                        Cat5, ≤2 m, UART │ ▲ heartbeat
            ┌──────────────────────── Board A (always present) ────────▼─┴──────┐
            │  Scanner ──► Input processing ──► InputState(local)               │
            │                                   InputState(remote) ◄── Link RX  │
            │                                          │                        │
            │        System inputs (mode switch, zero switch)                   │
            │                                          ▼                        │
            │        Mode function (mapping) ──► Pulse engine ──► Zero gate     │
            │                                                  ──► HID reporter │──► USB
            └───────────────────────────────────────────────────────────────────┘
```

* **One repo, one codebase, two build targets.** Everything up to and including
  `InputState` and the link protocol is shared. Board A adds USB HID and mapping.
  Board B is "scanner + transmitter" and nothing else.
* **Board B sends its whole state, not change events.** It sends a full snapshot
  of its debounced, decoded state, with **cumulative counters** for encoders and
  multi-position switches. A lost or corrupted frame then costs nothing, because
  the next one carries the same counters, and "B absent" just means "no valid
  frame for 50 ms".
* **The scan loop runs on its own CPU core** at about 10 kHz for the digital
  chain. The 4051 address and the rotary "phase" step in the background, and
  each one is only sampled once it has settled.
* **Mapping is plain C++ code, one class per master mode,** written in
  immediate-mode style: every millisecond the mode computes the whole output
  state from the current inputs. Held outputs are recomputed every time, so a
  button can never get stuck. Anything with timing (pulses, key taps) goes
  through a small pulse engine.

---

## 1. Hardware facts the firmware depends on

Taken from `PCBs/Shared_Main` and `PCBs/Right_Keypad` (netlist in the `.kicad_pcb` files).
If the schematic changes, update this section and `hw_pins.h`.

### 1.1 ESP32-S3-Zero pin map (same on both boards)

| GPIO | Net | Direction | Use |
|---|---|---|---|
| 1 | `ADDR0` | out | 74HC4051 S0 **and** keypad ROW1 (via R4 100 Ω) |
| 2 | `ADDR1` | out | 74HC4051 S1 **and** keypad ROW2 (via R5 100 Ω) |
| 3 | `ADDR2` | out | 74HC4051 S2 **and** keypad ROW3 (via R6 100 Ω). GPIO3 is a strapping pin, but only for JTAG-source selection when an eFuse is burned, so it is harmless here. |
| 4 | `A` | analog in | 4051 common output. **ADC1_CH3**: ADC1 is the right choice because ADC2 conflicts with Wi-Fi. |
| 5 | `ROT_PIN_1` | out | Drives the bases of **all four** BC547s at once (R1 10 k, R7 10 k pull-down). High = transistors on = rotary "pin 1" sunk to GND. |
| 6 | `SR_Q7` | in | Serial data from U4, the first 165 in the chain |
| 7 | `SR_CP` | out | Shift clock (R10 47 Ω series) |
| 8 | `SR_PL` | out | Parallel load, active low (R9 47 Ω series) |
| 9–13 | `AUX0`–`AUX4` | — | Expansion grid, unused. Useful as **timing probe pins** while developing (see §10). |
| 21 | (on-module) | out | WS2812 RGB LED on the S3-Zero. Use it for status (see §10). |
| 43 | `TX` → RJ45 pin 1 | A: **UART TX**, B: **UART RX** | |
| 44 | `RX` ← RJ45 pin 3 | A: **UART RX**, B: **UART TX** | |

Use **UART1** on both boards and route it to 43/44 through the GPIO matrix
(`uart_set_pin`). That leaves UART0 alone. On B the pins are swapped in software.

### 1.2 Shift register chain order

The chain is `MCU ← U4 ← U5 ← U6 ← U7 ← U8 ← U9 ← U10 ← U11 ← keypad 165 ← GND`.
A 74HC165 outputs D7 first and D0 last. If each byte is read **MSB-first**, a terminal
pin maps cleanly to a bit:

| Byte read | Chip | Terminal | Bit *n* = |
|---|---|---|---|
| 0 | U4 | J10 | J10 pin *n*+1 |
| 1 | U5 | J11 | J11 pin *n*+1 |
| 2 | U6 | J12 | J12 pin *n*+1 |
| 3 | U7 | J13 | J13 pin *n*+1 |
| 4 | U8 | J14 | J14 pin *n*+1 |
| 5 | U9 | J15 | J15 pin *n*+1 |
| 6 | U10 | J17 | J17 pin *n*+1 |
| 7 | U11 | J18 | J18 pin *n*+1 |
| 8 | keypad U1 | — | bit7..bit0 = COL8, COL7, COL6, COL5, **COL1, COL2, COL3, COL4** (the order is permuted, so use a lookup table) |
| 9 | (sentinel) | — | Keypad present: `0x00` (keypad DS is tied to GND). No keypad: `0xFF` (R8 pull-up on `SR_Q7_KP`). |

So the scanner clocks **80 bits (10 bytes)** per read. Byte 9 gives
**free keypad presence detection** on both boards.

All inputs have pull-ups and switch to GND, so **raw 0 = active**. The scanner inverts
everything so that logical `true` = pressed/closed.

### 1.3 Keypad matrix (8 columns × 3 rows, diodes)

Each column is pulled up and connects through a Schottky diode (anode on the column)
and a switch to a row. **A row is active when it is driven LOW.** Because the
rows share wires with the 4051 address lines, only some addresses give a clean row scan:

| ADDR (S2 S1 S0) | Rows low | Keypad data means |
|---|---|---|
| 6 = `110` | ROW1 | row 1 |
| 5 = `101` | ROW2 | row 2 |
| 3 = `011` | ROW3 | row 3 |
| 7 = `111` | none | must read "nothing pressed". Use it as a sanity check. |
| 0, 1, 2, 4 | ≥ 2 rows | ambiguous, ignore |

So the keypad is scanned "for free" as the mux address steps through 0–7.

### 1.4 74HC4051 channel → terminal J5

Channel *n* ↔ **J5 pin (8 − n)**: Y0 = J5-8, Y1 = J5-7, …, Y7 = J5-1.
E is tied to GND, so the mux is always enabled. Each J5 input has an optional 100 nF cap
to GND (C12–C19).

### 1.5 Rotary-switch phase line

There is **one** control line (GPIO5) for all four transistors. All rotary switches
switch phase together: phase 1 is GPIO5 low (pin 1 pulled up), phase 2 is GPIO5 high
(pin 1 sunk). Wiring per switch: pin 1 → one J2 terminal **and** one SR input;
pins 2–6 → SR inputs; pin 7 → GND. Each switch uses 6 SR inputs, so four switches use
24 of a board's 64.

### 1.6 Hardware observations that matter for the firmware

1. **Boot-time contention on the A-TX wire (pin 1).** On board B, GPIO43 is the
   *receive* pin. But the ESP32 ROM bootloader (and the 2nd-stage bootloader) always
   prints its boot log on GPIO43 (UART0 TX). For roughly 100–300 ms after B powers up
   or resets, **both A and B drive that wire**. R3 on each board limits the current to
   about 3.3 V / 200 Ω ≈ 16 mA, so nothing breaks. Firmware mitigations:
   * **A stays silent until it has received a valid frame from B.** B's firmware
     has its UART set up by then, so the ROM is done.
   * The receiving side must tolerate garbage, which COBS framing and a CRC handle (§6).
   * Optional: burn the eFuse that silences the ROM log on B (`espefuse.py … UART_PRINT_CONTROL`).
     This is irreversible, so not needed unless the above proves insufficient.
2. **Analog top end.** In the 12 dB attenuation range, the ESP32-S3 ADC is only usable up
   to about **3.1 V**, while the pots swing up to 3.3 V. The top few percent of pot
   travel will read as "max". Firmware handles it with per-axis calibration, where max is
   wherever the reading saturates. Hardware fix if you want it: a resistor of roughly
   680 Ω–1 k in series with the 3V3 end of each pot.
3. **Pots are ratiometric to `+3V3_EXP` (behind polyfuse F2); the ADC is not.** Rail noise
   shows up in the readings. Filtering (§5.5) and calibration take care of it.
   See the brainstorm item in §14 for a fully ratiometric option.
4. `SR_Q7_KP` already has a pull-up (R8), so an unpopulated keypad header is stable.
5. The pull-down on the transistor bases means the rotary phase is a defined
   "phase 1" while the ESP32 is still booting. Good.

---

## 2. Toolchain and repo layout

**Recommendation: PlatformIO (VS Code) with the Arduino-ESP32 core 3.x.** It is the
least friction coming from Arduino. You can still call ESP-IDF APIs (UART driver,
`adc_oneshot`, FreeRTOS tasks, TinyUSB) whenever the Arduino API is too limited, and
one `platformio.ini` gives you several build targets from one source tree. (If
PlatformIO's official platform still ships the old 2.x core, use the community
*pioarduino* platform.) Pure ESP-IDF is the alternative: more control, more boilerplate.

```
firmware/
  platformio.ini            # [env:board_a] [env:board_b] [env:native] (PC unit tests)
  lib/
    core/                   # PURE C++, no ESP32 headers, unit-tested on the PC
      bits.h                #   fixed-size bitset helpers
      debounce.*            #   digital debouncer
      quadrature.*          #   encoder decoder
      rotary12.*            #   decoder for the 7-contact rotary switch
      selector.*            #   multi-position switch: position + step counter
      analog_filter.*       #   oversample / median / 1-euro / hysteresis
      input_state.h         #   THE shared data contract (A local, A remote, B)
      link_protocol.*       #   COBS, CRC-16, frame structs
      wiring_types.h        #   EncoderDef, RotaryDef, Toggle3Def, …
    hal/                    # ESP32-specific, shared by A and B
      hw_pins.h             #   §1.1
      shift_chain.*         #   80-bit read (bit-bang first, SPI later)
      mux_adc.*             #   address lines, ADC oneshot + calibration
      scanner.*             #   the timed scan task (core 1)
      link_uart.*           #   UART1 + framing + statistics
      status_led.*
  src/
    board_a/
      main.cpp
      usb_hid.*             #   descriptors + report sending
      outputs.h             #   Outputs struct (joysticks, keyboard, consumer)
      mapping/              #   Map API, pulse engine, helpers
      modes/                #   one file per master mode
      system_inputs.*       #   master-mode switch, zero switch
      console.*             #   debug commands over USB CDC
    board_b/
      main.cpp
  config/
    wiring_a.h              # which physical input is what, on board A
    wiring_b.h              # same for board B
  test/                     # native unit tests (Unity or GoogleTest)
```

`build_src_filter` in `platformio.ini` picks `src/board_a` or `src/board_b`. `pio run`
builds **both** firmwares every time, so you can't forget to update B's copy of a
shared change.

**Tip for a C# developer:** keep `lib/core` free of any ESP32 headers and
`#ifdef`s. Then it compiles on your PC, and you can unit-test debouncing, decoding,
mapping helpers and the link protocol at full speed with a debugger, the way you would
in .NET. The ESP32 parts (`hal/`) stay thin.

C++ conventions: no heap allocation after startup, no exceptions, fixed-size arrays
(`std::array`), `constexpr` tables, `enum class`. Think "struct-heavy C# with no GC".

---

## 3. Layers and threads

| Layer | Runs on | Shared? | Rate |
|---|---|---|---|
| Scanner (shift chain, mux, ADC, rotary phase) | **core 1**, dedicated busy-loop task | yes | 10 kHz digital, ~400 Hz per analog channel |
| Input processing (debounce, decoders, filters) | core 1, inline in the scanner | yes | same |
| `InputState` publish | core 1 → core 0 via double buffer | yes | 1 kHz |
| Link TX (B) / Link RX (A) | core 0 | yes | ≤ 500 Hz + 100 Hz heartbeat |
| Mapping + pulse engine + zero gate | core 0 (A only) | no | 1 kHz |
| USB HID (TinyUSB) | core 0 (A only) | no | 1 kHz (USB full speed, bInterval = 1) |
| Console, LED | core 0, low priority | yes | ~10–50 Hz |

* Core 1 runs a tight loop that polls `esp_timer_get_time()` and never blocks,
  because microsecond scheduling and `vTaskDelay` (1 ms tick) don't mix. Make sure
  the idle-task watchdog isn't watching core 1. In Arduino-ESP32 it normally isn't,
  but verify.
* **Handover:** the scanner fills `InputState` buffer *n*, then atomically publishes
  index *n*. Readers copy the latest published buffer. It is about 150 bytes, so the
  copy is trivial. A spinlock (`portMUX`) around the copy is fine too.

---

## 4. Scanner (shared)

### 4.1 Shift-chain read

The frequency that matters is the **scan rate, not the clock rate.** Encoders need
the whole chain sampled at about 5–10 kHz (see §5.2). That takes only a **1–4 MHz** shift
clock, so there's no reason to push it to 20+ MHz. A slower clock is kinder to signal
integrity, and with 9 chips plus a ribbon cable, that matters.

Sequence:

1. `PL` low for ≥ 1 µs (the datasheet needs tens of ns, but 1 µs costs nothing). All 80 inputs are latched.
2. `PL` high; wait ≥ 1 µs.
3. 80 times: read `Q7`, then a rising edge on `CP` (the 165 shifts on the rising edge).

**Version 1: bit-bang** with direct register writes (`GPIO.out_w1ts/out_w1tc`). At
about 2 MHz, 80 bits take ~40 µs. Simple, deterministic, easy to look at on a logic analyzer.

**Version 2 (optional), SPI with DMA, near-zero CPU:** FSPI through the GPIO matrix,
**SPI mode 2** (CPOL = 1, CPHA = 0), 10 bytes per transfer.
* Mode 2 samples on the falling edge, half a clock *after* the 165 shifted on the rising
  edge. That gives a full half-period of margin. Mode 0 samples right on the shift edge,
  which usually works but is marginal.
* Trick: use `SR_PL` as a chip-select with **positive polarity** (`SPI_DEVICE_POSITIVE_CS`).
  Between transfers, PL is low, so the chips are continuously loading. When CS goes high
  at the start of a transfer, PL rises, the inputs are latched, and clocking starts.
  The whole read is then done by hardware.

**Signal-integrity knob in firmware:** set the drive strength of `SR_CP` and `SR_PL` to the
weakest setting (`gpio_set_drive_capability(…, GPIO_DRIVE_CAP_0)`). That slows the edges,
which together with the 47 Ω series resistors reduces ringing. Ringing on CP is the main
risk: the HC165 clock input has no Schmitt trigger, so ringing can cause a double shift.
Check CP at the far end (U11 and the keypad) with a scope or a logic analyzer once.

### 4.2 Scan schedule (address, phase, settle)

ADDR0–2 drive the 4051 and the keypad rows. GPIO5 sets the rotary phase. After any
change, things need time to settle (mux output, cable capacitance, BJT turn-off
storage time, 10 k pull-ups charging cable capacitance). Key idea: **change
address/phase immediately *after* a chain read, so the next read is always settled.**

```
tick period T = 100 µs (10 kHz).   slot = 3 ticks (300 µs).   frame = 8 slots (2.4 ms)

slot i: addr = GRAY[i] = 0,1,3,2,6,7,5,4      (only 1 address line changes per step)
        phase = i & 1                          (rotary phase 1 / phase 2)

  tick 0: read chain ─► process      (addr/phase have been stable for ≥ ~60 µs)
  tick 1: read chain ─► process
  tick 2: read chain ─► process
          ADC: 1 dummy conversion + 4 conversions averaged, on channel `addr`
          then: set next addr + phase  ◄── changes only happen here
```

Each read is **tagged** with the `(addr, phase)` it was taken under, and processing
routes the bits:

| Bits | Used from |
|---|---|
| Plain buttons/switches, encoders | **every** read (10 kHz) |
| Rotary-switch pins | reads with `phase` = 1 or 2, combined into pairs |
| Keypad byte | reads with `addr` ∈ {6, 5, 3} → row 1/2/3; `addr` = 7 → check that all keys read "not pressed" |
| ADC result | belongs to channel `addr` |

Resulting rates: digital 10 kHz, each analog channel ~417 Hz, each keypad row ~417 Hz,
complete rotary-switch reads ~1.7 kHz. Plenty everywhere.

**All of these numbers are starting points and live in one `constexpr` config struct.**
Measure on the real board: toggle `AUX0` at every tick and `AUX1` during ADC conversions,
and look at it with a logic analyzer (§10). Then tune the settle time with the console
command that reports per-channel noise (§10).

### 4.3 Analog settling (electrical)

* **With** the optional 100 nF caps fitted: when the mux switches, the 4051 output node
  (a few tens of pF) charges from the 100 nF reservoir through about 200 Ω of mux on-resistance.
  That settles in **well under 1 µs**. The caps also low-pass the cable noise.
  **Recommendation: fit them for pots.** With a 10 k pot, the response time constant is
  ≤ 250 µs, which you can't feel.
* **Without** caps: settling depends on the pot's output impedance (≤ 2.5 kΩ for a 10 k pot)
  and on charge kick-back from the ADC sample capacitor. 20–50 µs is generous.
* In both cases, **throw away the first conversion** after switching, then average N.
* Use ESP-IDF `adc_oneshot` + `adc_cali` (curve fitting), not Arduino `analogRead()`.

---

## 5. Input processing (shared)

### 5.1 Digital debouncing

There is one debouncer per logical bit: 64 board bits + 24 keypad keys = 88.
Parameters are **in time, not samples**, because keypad bits are sampled less often
than board bits.

Algorithm ("confirm, then lock out"):

1. If the raw value ≠ the stable value continuously for **`t_confirm`** (default 0.3 ms,
   about 3 samples), accept the change immediately. This rejects single-sample glitches
   such as EMI or a rare double-clock read.
2. After accepting, **freeze** the bit for **`t_lockout`** (default 8 ms). Contact bounce
   during that window is ignored.

So the latency is about 0.3 ms. That is far better than the classic "wait 20 ms after the last
change", and still bounce-proof. You can override the defaults per input class (old
toggle switches may need a longer lockout).

Efficiency: XOR the new raw word with the stable word. Only bits that differ need any
work, which is almost always none.

### 5.2 Encoders (on the shift chain)

* **No time-based debounce.** Use the standard Gray-code state machine, the same idea as
  `src/sketch_dec20a`, but polled instead of interrupt-driven. Use the variant that only
  counts when the encoder arrives at a **detent state** (for example the well-known
  "full-step" table). Bounce then just wiggles between neighbouring states and never
  produces a count.
* Per-encoder config: `stepsPerDetent` (4 = one full quadrature cycle per click,
  which is most EC11 types; 2 = half-cycle), and `invert`.
* Output: an **`int16_t` cumulative counter** (wraps safely). Consumers compute
  `delta = (int16_t)(now - last)`.
* **Is 10 kHz fast enough?** A 24-detent encoder spun hard by hand at about 5 rev/s gives
  480 transitions/s, about 2 ms apart on average and maybe 0.5 ms for the shortest phase.
  10 kHz gives ≥ 5 samples per state. 5 kHz would also work.
* Optional: velocity, i.e. steps per 100 ms, for acceleration in mappings.

### 5.3 The 7-contact 12-position rotary switch

For each rotary switch *k*, the scanner keeps the last 6-bit sample from phase 1 (`p1`) and
from phase 2 (`p2`), with pins 1..6 as bits 0..5 and raw levels (1 = high). Whenever a new
pair is complete:

```
code = (p1 << 6) | p2                            // 12 bits
position = LOOKUP[code]  (one of 12 entries, everything else = INVALID)
```

The lookup table is exactly your truth table, so phase 1 and phase 2 are checked against
each other with no special cases:

| Pos | phase 1 (pins 1-6) | phase 2 (pins 1-6) |
|---|---|---|
| 1 | 011111 | 011111 |
| 2 | 101111 | 001111 |
| 3 | 110111 | 010111 |
| 4 | 111011 | 011011 |
| 5 | 111101 | 011101 |
| 6 | 111110 | 011110 |
| 7 | 111111 | 011111 |
| 8 | 111111 | 001111 |
| 9 | 111111 | 010111 |
| 10 | 111111 | 011011 |
| 11 | 111111 | 011101 |
| 12 | 111111 | 011110 |

**Gotcha: position 7 is "nothing connected",** and that is exactly what a break-before-make
switch looks like *between any two positions*. A 3→4 turn will briefly read as "7".
Mitigations, all in the selector debouncer (§5.4):

* A new position must be **stable for `t_stable`** (default 20 ms) before it is accepted.
  The transient "7" between detents lasts a few ms and is rejected.
* **Plausibility for 7:** accept a jump to 7 quickly only from 6 or 8. From anywhere else
  it needs a much longer stable time (default 250 ms).
* Codes that aren't in the table (make-before-break overlap, a fault) are ignored and the
  last valid position is kept. They are counted as diagnostics.

Infinite rotation means the step direction is computed **modulo 12, shortest way**:
`d = ((new - old + 18) % 12) - 6` gives −6..+5. Debouncing at 20 ms is fast enough not to
skip positions even on a quick flick, about 25 ms per position for a full turn in 0.3 s.

### 5.4 Selectors: position plus up/down steps, for everything multi-position

A generic **Selector** is the single abstraction for "a switch with more than one stable
position". Sources:

| Source | Example | Decoder |
|---|---|---|
| Rotary12 (two-phase) | your 7-contact switches | §5.3 |
| One-hot bits | ON-OFF-ON toggle on 2 SR inputs: `10` / `00` / `01` → pos 0/1/2 | table |
| Binary/BCD/Gray bits | thumbwheels, coded rotary switches | table |
| Analog ladder | the master-mode switch (§7.2), other resistor-ladder switches | bands with hysteresis |
| Analog axis zones | "throttle in idle detent", lever positions | bands with hysteresis |

Each selector publishes:

* `position`: debounced, `-1` = unknown (not yet valid after boot)
* `steps`: **cumulative signed `int16_t` counter**, +1 per step up, −1 per step down
  (with wrap-around for infinite switches, linear otherwise)

Consumers on A derive both the **actual position** and the **up/down pulses** from these
two fields (helpers in §7.4). The counter, rather than position diffs, keeps pulses correct
even if a link frame is lost in the middle of a fast turn.

### 5.5 Analog stabilisation (value filtering)

This is separate from electrical settling (§4.3), which is about getting a *correct* sample.
Here the goal is a *stable, low-latency* value:

1. **Oversample:** discard 1 conversion, average 4 per mux visit.
2. **Median of 3** visits: kills single spikes.
3. **1€ filter** (One-Euro filter): an adaptive low-pass that smooths heavily while the input
   is still (no jitter) and lightly while it moves (low lag). Two parameters, well suited to
   joysticks and pots. A fixed EMA (exponential moving average) is the simpler fallback.
4. **Hysteresis/deadband on the published value:** only change it when it differs by more
   than *h* counts (default 3 of 4095) from the last published value. This kills last-bit
   flicker, so nothing spams HID reports.
5. Publish as **millivolts (`uint16_t`)** using `adc_cali`. Per-axis **calibration**
   (min / centre / max / deadzones / curve) is applied on **A** in the mapping layer,
   so all calibration data lives in one place (NVS on A, editable via the console).

### 5.6 `InputState`: the shared contract

```cpp
struct InputState {
    // header
    uint32_t bootId;          // random per boot; lets A detect "B rebooted" → re-baseline
    uint32_t wiringHash;      // hash of wiring_x.h; A warns if B was flashed with old wiring
    uint16_t fwVersion;
    uint8_t  flags;           // READY, KEYPAD_PRESENT, …

    // digital (logical: true = active)
    Bits<64> board;           // debounced shift-register inputs, byte/bit as in §1.2
    Bits<24> keypad;          // debounced, row-major: key = row*8 + (col-1)

    // decoded
    int16_t  encoderCount[MAX_ENCODERS];     // cumulative
    int8_t   selectorPos[MAX_SELECTORS];     // -1 = unknown
    int16_t  selectorSteps[MAX_SELECTORS];   // cumulative

    // analog
    uint16_t analogMv[8];     // filtered, millivolts, 4051 channel order

    // diagnostics (cheap, very useful)
    uint16_t invalidRotaryCodes, keypadSanityErrors, scanOverruns;
};
```

`READY` is set once every debouncer and filter has had time to fill (≈ 50 ms after boot).
Until then, A treats the state as not valid yet.

### 5.7 Wiring config (`config/wiring_a.h`, `config/wiring_b.h`)

This is where you describe what is physically connected where. It exists so that the
scanner knows which bits are encoder pairs, rotary switches, etc., and so that mappings can
use names instead of bit numbers.

```cpp
// wiring_b.h — example
constexpr EncoderDef  kEncoders[]  = { { T(J12,1), T(J12,2), Detent::Full },
                                       { T(J12,3), T(J12,4), Detent::Full } };
constexpr RotaryDef   kRotaries[]  = { { T(J14,1), T(J14,2), T(J14,3),
                                         T(J14,4), T(J14,5), T(J14,6) } }; // pin1..pin6
constexpr Toggle3Def  kToggle3[]   = { { T(J13,7), T(J13,8) } };
constexpr AnalogDef   kAnalog[8]   = { {Use::Axis}, {Use::Axis}, {Use::Unused}, … };

// logical names used by the mappings
namespace B {
    constexpr ButtonId  GEAR       = button(T(J10,1));
    constexpr ButtonId  KP_ENTER   = keypad(2, 8);          // row 3, col 8
    constexpr EncoderId HDG        = encoder(0);
    constexpr SelectorId RADIO     = rotary(0);
    constexpr SelectorId FLAPS     = toggle3(0);
    constexpr AnalogId  THROTTLE   = analog(0);
}
```

Because B decodes its own encoders and rotaries, **B must be re-flashed when `wiring_b.h`
changes.** The `wiringHash` field catches the case where you forget: A shows a warning
colour on the LED.

---

## 6. Link protocol (shared)

**Physical:** UART1, 8N1, start at **1 Mbaud**. That's fine for 2 m of twisted pair with
100 Ω source termination, which is what R2/R3 effectively are. The error counters (§10)
will show whether you need to drop to 500 k.

**Framing:** `[COBS-encoded: type | seq | payload | CRC-16]` + `0x00` delimiter.
* COBS (Consistent Overhead Byte Stuffing) guarantees `0x00` only appears as a frame
  delimiter. After any garbage (boot logs, unplugging the cable mid-frame) the receiver
  resynchronises at the next `0x00`.
* A bad CRC or a bad length means the frame is dropped and an error counter goes up. Never act on it.

**B → A: `STATE` frame** = a serialised `InputState`, about 80–110 bytes.
* Sent **when anything changed**, but at most every **2 ms** (500 Hz), and **at least
  every 10 ms** (heartbeat). Worst case ≈ 110 bytes × 500/s ≈ 55 kB/s, well inside the
  ~100 kB/s that 1 Mbaud carries. (Going to 1 kHz would need 2 Mbaud; not worth it, since
  2 ms is far below anything you can feel.)
* No ACK or retransmit is needed: every frame is the complete truth.

**A → B: `HELLO/HEARTBEAT` frame,** every 20 ms, but **only after A has heard B** (§1.6):
`{ seq, masterMode, zeroActive, ledCommand, requests }`. It lets B show status on its LED
and lets B know whether A is alive. Room for later: "identify" (blink), "send stats",
config push.

**Presence logic on A:**

| Condition | A's view of B |
|---|---|
| No valid frame yet / none for **50 ms** | `remote.present = false`, all remote inputs read as neutral |
| Valid frames resume | `present = true`, **re-baseline** counters/positions/edges (no phantom pulses) |
| `bootId` changes | B rebooted: re-baseline |
| `wiringHash` ≠ expected | still use the data, but warn (LED + console) |

Latency, B input to USB: debounce 0.3 ms + ≤ 2 ms link + ≤ 1 ms mapping + ≤ 1 ms USB ≈ **2–5 ms**.

---

## 7. Board A

### 7.1 Main loop on core 0 (1 kHz)

```
every 1 ms:
  local  = scanner.latest()
  remote = link.latest()  (or neutral if absent)
  sys.update(local)                       // master mode + zero switch (debounced)
  if mode changed → mode transition (§7.2)
  out.clear()                             // immediate mode: rebuild every frame
  modes[sys.mode]->run(Map{local, remote, prev, out, pulses, now})
  pulses.apply(out, now)                  // OR in the active pulses
  zeroGate.apply(out)                     // §7.3
  hid.send(out)                           // diff against last sent; only changed reports
  prev = {local, remote}
```

### 7.2 Master-mode switch (12 positions, analog ladder, on A)

**(assumption)** It uses one 4051 channel on board A. That leaves 7 analog channels on A
for pots and joysticks.

* Decode with an **analog-ladder Selector** (§5.4): 12 bands around nominal voltages,
  thresholds at the midpoints, plus hysteresis.
* **Suggested ladder:** a string of 14 equal resistors from 3V3 to GND, with the switch
  picking taps 1..12. That puts positions at k/14 · 3.3 V = 0.24 V … 2.83 V. The steps are
  about 0.24 V (≈ 290 ADC counts) apart and stay clear of the ADC's non-linear ends.
  Add a large pull-down (≈ 1 MΩ) on the wiper so that "between positions / open" drifts
  toward 0 V, which is an invalid band. With the 100 nF cap fitted, the voltage simply holds
  during a break-before-make gap, which is also fine.
* Optional "learn" console command: record the actual voltage at each position and store
  it in NVS. That avoids depending on resistor tolerances.
* **Debounce:** stable ≥ **150 ms** before a mode change is accepted, so turning through
  several positions doesn't flash through intermediate modes.

**Mode transition:**
1. Report **everything released or neutral** for ≥ 30 ms, so games see the release.
2. Clear the pulse engine queue and call the new mode's `onEnter()` (reset its state).
3. **Re-baseline edge detection** so the new mode doesn't fire "pulse on change" for
   switches that were already in position.
4. Run the new mode. Held outputs immediately reflect current switch positions, which
   is what you want.
5. LED colour/blink shows the new mode.

### 7.3 Zero switch (bistable "zero all reports")

**(assumption)** This is an ordinary toggle wired to a shift-register input on A, declared
in `wiring_a.h` as `SYS_ZERO`. It is a system input and never reaches the mode functions.

| | Behaviour |
|---|---|
| Turned on | HID reports go **neutral**: all buttons/keys released, axes at their neutral value. Pulse queue flushed. |
| While on | Scanning, debouncing and mapping keep running normally, so their state stays current. Only the output is gated. **New pulses are dropped** and not queued for later. |
| Turned off | The gate opens; because mapping is immediate-mode, the **current state is re-reported automatically** on the next frame. |
| Optional "sync pulses" | For mappings like "toggle ON → pulse button X, OFF → pulse Y", replay *the pulse that matches the current position* when the gate opens (and optionally on mode entry). That re-syncs the game's view of toggles that only accept pulses. See question in §13. |

"Neutral" axis value is defined per axis: centre for bipolar axes (stick), minimum for
unipolar ones (throttle, brakes). See §13.

### 7.4 Mapping API

Each master mode is a class. As a C# developer you'd recognise it as a small "render"
method that runs every millisecond and declares what the outputs *should be right now*.

```cpp
class FlightSim : public Mode {
    VirtualAxis trim { -1.0f, +1.0f, /*step*/ 0.01f };   // state that persists in this mode
public:
    const char* name() const override { return "Flight sim"; }
    void onEnter() override { trim.reset(); }

    void run(Map& m) override {
        // ── Held (level) outputs: "output is ON while condition is true".
        //    Multiple writers to the same output are OR-ed → many-to-one is natural.
        m.hold(J1.btn(1),  m.on(A::GEAR));
        m.hold(J1.btn(2),  m.on(A::TRIGGER) || m.on(B::TRIGGER2));   // many → one
        m.hold(J1.btn(3),  m.on(A::MASTER_ARM));                     // one → many …
        m.hold(KEY(F1),    m.on(A::MASTER_ARM));                     // … as many as you like

        // ── Chords and shift layers are just code
        bool shift = m.on(A::SHIFT);
        m.hold(J1.btn(4),  !shift && m.on(A::BTN7));
        m.hold(J1.btn(5),   shift && m.on(A::BTN7));
        m.hold(J1.btn(6),  m.on(A::BTN8) && m.on(A::BTN9));          // chord

        // ── Edges → pulses (fixed-length press, queued by the pulse engine)
        m.pulseOnPress  (A::LIGHTS, J1.btn(10));        // toggle up   → tap btn 10
        m.pulseOnRelease(A::LIGHTS, J1.btn(11));        // toggle down → tap btn 11
        m.pulseOnChange (A::PITOT,  KEY(H));            // any flip    → tap H
        m.tapOnPress    (A::SAVE,   KEY(LCTRL, S));     // key combo, modifier sequencing handled

        // ── Encoders
        m.encoderPulses(B::HDG, J2.btn(1), J2.btn(2));  // CW → btn 1, CCW → btn 2
        m.axis(J1.axis(RZ), trim.step(m.delta(B::TRIM)));   // encoder → virtual axis

        // ── Multi-position switches: position AND up/down pulses
        m.selectorButtons(B::RADIO, J2.btn(20));         // pos 1..12 → hold btn 20..31
        m.selectorPulses (B::RADIO, J2.btn(40), J2.btn(41)); // step up / step down
        m.selectorButtons(A::FLAPS, J2.btn(50));         // 3-pos toggle → 3 buttons
        m.selectorPulses (A::FLAPS, KEY(F7), KEY(F6));

        // ── Analog
        m.axis(J1.axis(X),  m.analog(A::STICK_X).cal().deadzone(0.03f));
        m.axis(J1.axis(Z),  m.analog(A::THROTTLE).cal().curve(1.5f));
        m.hold(J1.btn(60),  m.analog(A::THROTTLE).cal() < 0.05f);   // axis → button
        m.hat (J1.hat(0),   m.on(A::H_UP), m.on(A::H_RIGHT), m.on(A::H_DOWN), m.on(A::H_LEFT));

        // ── B absent is just data
        if (!m.remotePresent()) { /* e.g. fall back to local alternatives */ }
    }
};

Mode* const kModes[12] = { &generic, &genericPulses, &flightSim, &spaceSim, … };
```

Semantics, kept intentionally simple:

* **Buttons and keys:** OR of every `hold` plus any active pulse.
* **Axes:** last writer wins. A debug build warns if an axis is written twice in one frame.
  Use explicit helpers when combining is intended: `m.axisMax(…)`, `m.axisSum(…)`,
  `splitAxis(…)` (one pot → two half-axes), `mergeAxes(…)` (two toe brakes → one rudder).
* `m.on(x)`, `m.pressed(x)` (rising edge this frame), `m.released(x)`, `m.delta(enc)`,
  `m.position(sel)`, `m.steps(sel)`: inputs from absent B read as off / 0 / unknown.
* Edge helpers compare against the previous frame, so no state lives in the mode.
  Stateful helpers (`Latch`, `VirtualAxis`, `LongPress`, `DoubleTap`) are members of the
  mode class and get reset in `onEnter()`.

**Generic modes, mostly for binding in a game's control settings** (**(assumption)** this
is what "used for mapping in games" means):
* `Generic`: every digital input → its own joystick button, every selector position →
  its own button, every encoder → a CW/CCW button pair, every analog channel → an axis.
  It is generated automatically from the wiring tables, so it never needs maintenance.
* `Generic pulses`: the same, but toggles produce pulses on each flip. Handy because many
  games' "press a button to bind" screens are confused by a held toggle.

### 7.5 Pulse engine

Games poll input once per frame, often at 30–60 Hz, and sometimes only react to presses
longer than one or two frames. A 1 ms pulse is invisible to them. So:

* Each pulse is queued per output with `onTime` (default **50 ms**) and `offTime` (default
  **50 ms**). Both are overridable per mode, since some games need longer.
* **Queue limit per output** (default 5). Spinning an encoder fast otherwise builds up a
  multi-second backlog that keeps "turning" after you stop. Overflow drops pulses (or,
  with an option, coalesces them).
* Key combos: press modifiers → wait about 10 ms → key → release in reverse order. Some
  games miss the modifier otherwise.
* If an output is both held and pulsed in the same frame, the hold wins (OR). That's
  documented behaviour, not a bug.

### 7.6 USB HID

**(assumption)** Windows and DirectInput-style games. Proposed composite device:

| Interface / collection | Content |
|---|---|
| Joystick 1–4 (separate top-level collections, so Windows shows 4 controllers) | 128 buttons, 8 axes × 16 bit (X Y Z Rx Ry Rz Slider Dial), 1 hat. About 34 bytes per report. |
| Keyboard | modifiers + 6KRO or an NKRO bitmap |
| Consumer control | volume, media keys |
| CDC serial | debug console (§10) |

Why several joysticks: DirectInput supports at most 8 axes and 128 buttons per device, and
some games only look at the first 32 buttons. The analog count alone (7 on A + 8 on B = 15)
needs two devices. The mapping code decides what goes where.

Important gotchas:
* **Freeze the descriptor and VID/PID early.** Games store bindings per device identity,
  and Windows caches the descriptor. Changing the layout later can wipe or scramble your
  bindings. If you must change it, bump the PID or `bcdDevice` deliberately.
* `joy.cpl` (Windows "Game Controllers") only displays 32 buttons. Use a better tester
  to verify all 128.
* Send a report only when it changed (and all of them once after USB mount/resume).
  Reports use one endpoint at 1 kHz, sent round-robin when several have changed.
* A **must not wait for USB** (no `while(!Serial)`). It has to run normally when B is
  powering it while you program B.
* Flashing A once TinyUSB HID is running: either Arduino's "1200-baud touch" on the CDC port,
  or hold **BOOT** while plugging in the USB. Keep the latter in mind for when firmware crashes.

---

## 8. Board B

`main.cpp` is roughly 30 lines:

```cpp
setup(): pins, status LED, UART1 (TX = 44, RX = 43 — swapped vs A), start scanner on core 1
loop():  state = scanner.latest()
         if changed or 10 ms elapsed: link.send(STATE, state)
         link.poll()  → heartbeat from A → LED shows link status / mode colour
         console.poll() (USB CDC, for when B is plugged in for programming)
```

B never waits for A and works the same whether or not A is listening.

---

## 9. Startup, absence and failure handling

| Situation | Behaviour |
|---|---|
| Boot (both boards) | `READY` only after ~50 ms of scanning. Edges, counters and positions are **baselined** from the first valid state, so nothing fires at power-up. |
| B absent at boot / unplugged / rebooted | Remote inputs neutral; outputs driven by them release; re-baseline when B returns (§6). |
| Keypad absent (sentinel byte = `0xFF`) | Keypad keys read as not pressed; `KEYPAD_PRESENT` flag clear. Works on A and B. |
| Keypad sanity error (key "pressed" at addr 7) | Count it; ignore keypad data for that frame. |
| USB not connected on A | Everything runs; HID sending is skipped. |
| Scanner overrun (a tick took > T) | Count it; shows up in the console. That's a sign to move to SPI or drop to 5 kHz. |
| Scanner stalls (watchdog) | A outputs neutral and the LED shows an error. |
| Wiring hash mismatch | Warn, keep working. |

---

## 10. Debug tooling (do this early, it pays for itself)

* **USB CDC console** on both boards (on A it is part of the composite device):
  * `raw`: live view of the 80 raw bits, grouped per terminal (J10…J18, keypad)
  * `inputs`: debounced named inputs, encoder counts, selector positions
  * `analog`: per-channel mV, noise (min/max/stddev over 1 s), with the settle time adjustable live
  * `link`: frames/s, CRC errors, COBS errors, last-seen, B's bootId/wiringHash
  * `stats`: scan rate, overruns, invalid rotary codes, keypad sanity errors
  * `ident`: prints the name of any input that changes, so you can find which wire is which
  * `cal`: interactive axis calibration and mode-ladder "learn", stored in NVS
  * `mode`: current mode, plus forcing a mode without turning the switch
* **Timing probe pins:** AUX0 toggles every scan tick, AUX1 is high during ADC, AUX2 during
  chain reads. Get a cheap 8-channel USB logic analyzer + PulseView (sigrok). For a first
  PCB it is the single most useful tool you can own.
* **Status LED** (WS2812 on GPIO21):
  * A: colour = master mode; slow blink = B absent; red flash = errors; white = zero switch active.
  * B: green = link OK; amber blink = no heartbeat from A.

---

## 11. Testing strategy

* **Native unit tests** (`pio test -e native`) for all of `lib/core`: debouncer edge cases,
  quadrature tables including bounce sequences, the rotary-12 decoder including the
  "transient 7" case, selector step counting with wrap-around, the 1€ filter, COBS/CRC
  round-trip and garbage resync, and mapping helpers (pulse engine timing, edge baselining
  on mode change).
* **Record and replay:** a console command dumps the tagged raw scan stream to a file.
  Feed it to the native build to reproduce a real-world glitch on the PC, under a debugger.
* **Bench checklist per board:** every terminal pin toggles exactly its bit (`ident`),
  keypad presence detected/absent, all 8 analog channels respond, all rotary positions
  decode in both directions, link survives cable pull/re-plug and B reset.

---

## 12. Milestones

| # | Goal | Done when |
|---|---|---|
| M0 | Toolchain, both envs + native tests build, LED blinks, console works | `pio run` builds A and B |
| M1 | Shift chain driver | `raw` shows correct bits for every terminal; keypad presence detection works; CP checked on a logic analyzer |
| M2 | Mux + ADC | `analog` shows all channels; settle time and noise measured, defaults chosen |
| M3 | Scanner schedule + all decoders (debounce, encoders, rotary, keypad, selectors, filters) | unit tests green; `inputs` correct on the bench at full scan rate |
| M4 | USB HID on A with the `Generic` mode, local inputs only | all inputs visible in a joystick tester |
| M5 | Link | B's inputs appear on A; unplug/replug/reset of B behave as in §9; error counters ≈ 0 at the chosen baud |
| M6 | Mapping API, pulse engine, master-mode switch, zero switch | first real game profile works end-to-end |
| M7 | Polish | calibration in NVS, LED codes, more profiles, optional SPI/DMA chain read |

---

## 13. Open questions

1. **HID outputs:** joysticks only, or also keyboard, consumer (media) and mouse? How many
   virtual joysticks? Which games and OS? This decides the descriptor, which you want to
   freeze early (§7.6).
2. **"Zero" switch details:**
   a. Axes go to centre (bipolar) / minimum (unipolar)? Or literally 0 for everything?
   b. Should it also do **sync pulses** on release (replay the pulse that matches each
      toggle's current position)? Should the same happen on mode change?
   c. Is it on board A? Does it affect keyboard output as well (proposed: yes, everything)?
3. **Master modes:** does "used for mapping in games" mean generic 1:1 modes for binding in
   the game's settings (§7.4)? How many generic vs game-specific modes? Does the master
   switch have an end stop, or does it rotate infinitely? Does mode-specific state (e.g. an
   encoder-driven virtual trim axis) reset on mode change or persist?
4. **Encoders:** how many per board, which type (clicks per quadrature cycle), and is
   acceleration wanted (fast spin = bigger steps / more pulses)?
5. **Rotary switches:** up to 4 per board (one transistor each, 6 SR inputs each). How many
   on each board? Are there other multi-position switch types (ON-OFF-ON toggles, coded
   rotary switches, ladder-based switches other than the mode switch)?
6. **Pulse timing:** is 50 ms on / 50 ms off a reasonable default for your games?
7. **Analog:** how many channels are joysticks vs simple pots on each board? Will you fit the
   100 nF caps? Is the master-mode switch on a 4051 channel of A (assumed)?
8. **Configuration:** is compile-and-flash for mapping changes acceptable long-term
   (proposed), or do you eventually want changes without re-flashing (see §14)?
9. **Keypad on B:** the firmware supports it automatically. Just confirm whether it's planned.
10. **Both USBs connected at once** (handy for debugging both boards at the same time): check
    whether the S3-Zero has a diode between USB VBUS and its 5V pin. Otherwise the two PCs'
    (or ports') 5V rails get tied together via the Cat5 (hardware question, affects dev workflow).

---

## 14. Brainstorm: later ideas

* **Encoder → mouse wheel / mouse axis** outputs (consumer of the same `delta`).
* **Long-press / double-tap / hold-to-repeat** helpers (one button, several functions).
* **Toggle-vs-game desync fix:** a "resync" gesture (or the zero switch's sync pulses) for games
  that only offer "toggle X" commands.
* **Per-mode pulse timing presets** ("this game needs 80 ms presses").
* **Ratiometric analog:** feed `+3V3_EXP` through a 2:1 divider into a spare 4051 channel and
  divide pot readings by it. This cancels rail noise and the polyfuse drop. It would be a hardware
  change; only worth it if the noise turns out to be a problem.
* **Config over USB from a PC app** (C# :-) ): a JSON mapping uploaded to NVS and
  interpreted by a small rule engine, instead of compiled C++. It's much more work. Only
  worth it if re-flashing becomes annoying; the compiled approach is more flexible and debuggable.
* **Firmware update of B through A** (A forwards an image over the link, B writes it with
  `esp_ota`). It is a firmware-level feature, since B's ROM bootloader isn't reachable through
  the link wiring. Nice-to-have only.
* **Outputs on AUX0–AUX4:** status LEDs on the panel, or I²C for a small display showing the current mode.
* **Virtual detents on axes** (e.g. throttle idle/cutoff gates reported as buttons).
