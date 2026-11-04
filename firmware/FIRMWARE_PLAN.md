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
            │        System inputs (mode, filter and zero switches)             │
            │                                          ▼                        │
            │        Mode function (mapping) ──► Pulse engine ──► Zero gate     │
            │                                                  ──► HID reporter │──► USB
            └───────────────────────────────────────────────────────────────────┘
```

* **One repo, one codebase, two build targets.** Everything up to and including
  `InputState` and the link protocol is shared. Board A adds USB HID and mapping.
  Board B is "scanner + transmitter" and nothing else.
* **Board B sends its whole state, not change events.** It sends a full snapshot
  of its debounced, decoded state: button bits, rotary-switch positions, analog
  values, and a **cumulative counter per encoder**. A lost or corrupted frame then
  costs nothing, because the next one carries the same values, and "B absent" just
  means "no valid frame for 50 ms". Board A works out up/down steps of multi-position
  switches itself, from the previous vs the new position.
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
| 43 | `TX` | out | **UART TX** on both boards. A: via R3 → RJ45 pin 1. B: R2/R3 are fitted crossed ("Cross on board B" silkscreen), so it goes → RJ45 pin 3. |
| 44 | `RX` | in | **UART RX** on both boards. A: via R2 ← RJ45 pin 3. B: crossed, ← RJ45 pin 1. |

Because B's resistors are crossed, **both firmwares use identical UART pins**; nothing is
swapped in software. Use **UART1**, routed to 43/44 through the GPIO matrix (`uart_set_pin`),
so link traffic stays separate from any UART0 debug logging.

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

1. **Boot logs arrive at the other board.** The ESP32 ROM bootloader (and the 2nd-stage
   bootloader) always prints a boot log on GPIO43 at 115200 baud. With R2/R3 crossed on B,
   GPIO43 is the TX pin on both boards, so there is no contention. But each board's
   receiver gets a burst of garbage whenever the other board boots or resets. The link
   framing (COBS + CRC, §6) discards it and resynchronises, so nothing else is needed.
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
      selector.*            #   multi-position switch: debounced position, up/down from position change
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
      outputs.h             #   Outputs struct (JA, JB, keyboard)
      mapping/              #   Map API, pulse engine, helpers
      modes/                #   one file per master mode
      system_inputs.*       #   master-mode, filter and zero switches
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

Every plain digital input also has a **kind** in the wiring config: `Momentary` (push
button) or `Toggle` (on-off switch). An on-off-on switch is declared as a `Toggle3` over
two bits. The kind doesn't change debouncing; it tells board A which inputs get re-synced
when the zero switch returns from "zero + re-report" (§7.3.2), which output class they
produce for the filter switches (§7.3.1), and how the generic mode lays them out (§7.4).

Efficiency: XOR the new raw word with the stable word. Only bits that differ need any
work, which is almost always none.

### 5.2 Encoders (on the shift chain)

* **No time-based debounce.** Use the standard Gray-code state machine, the same idea as
  `src/sketch_dec20a`, but polled instead of interrupt-driven. Use the variant that only
  counts when the encoder arrives at a **detent state** (for example the well-known
  "full-step" table). Bounce then just wiggles between neighbouring states and never
  produces a count.
* Per-encoder config: `stepsPerDetent` and `invert`. Encoders differ in how many
  quadrature state changes happen between two clicks: **4** (one full A/B cycle per
  click, most common, e.g. typical EC11), **2** (half a cycle per click, common on
  higher-detent-count models), or **1**. A wrong value means 2–4 counts per click, or
  a count only every other click. You don't need to know it upfront: the `inputs` console
  view (§10) shows the raw state changes per click on the bench.
* Capacity: up to **32 encoders per board** (2 shift-register bits each). Nothing is
  hard-coded for a particular count; the wiring tables decide.
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

**Transitions.** The switches are **make-before-break** with a very wide wiper and almost no
gap between pads. While turning, the switch reads as **garbage** (a code that isn't in the
table) or briefly as **another valid position**, for a long time compared with normal
contact bounce. So the rotary debouncer is much slower than the button debouncer:

* The decoded code must stay **identical for `kRotaryStableTime`** before the new position
  is accepted. That is one central constant, default **200 ms**. Any change of code, valid or
  not, restarts the timer.
* Invalid codes never become a position. The last accepted position is kept and the code
  is counted as a diagnostic.
* Latency for rotary changes is therefore about 200 ms. That's fine for slowly turned
  selectors and is the price of the huge overlap.

The switches have **no end stops** (infinite rotation), so board A computes the step from
old to new position **modulo 12, shortest way**: `d = ((new - old + 18) % 12) - 6` gives
−6..+5. If you turn faster than one position per 200 ms, positions are skipped and A emits
`|d|` pulses in the right direction. That stays correct as long as fewer than 6 positions
are skipped between two accepted readings, which is not a realistic turning speed for these switches.

Capacity: **4 rotary switches per board** (one transistor each). The scanner decodes all
the ones listed in the wiring table.

### 5.4 Selectors: position plus up/down pulses

A **Selector** is a mapping-side abstraction (on board A) for "a switch with more than one
stable position". It gives a mode both the **actual position** and **up/down pulses**. It
needs nothing but a debounced position:

| Source | Positions | Wraps? | Position comes from |
|---|---|---|---|
| Rotary12 (two-phase) | 12 | yes, no end stops | decoded on the board that scans it (§5.3) |
| Toggle3 (on-off-on) | 3 | no | decoded on A from two debounced bits: `10` / `00` / `01` → pos 0/1/2 |
| Toggle (on-off) | 2 | no | one debounced bit |

Up/down is derived on A by comparing the previous and the new position: shortest way
modulo *N* for wrapping switches, plain difference otherwise. One step = one pulse on the
"up" output or the "down" output (helpers in §7.4).

A position diff is enough here, without a step counter like the encoders have. Positions
change at most every 200 ms and B re-sends its full state at least every 10 ms, so A
can't miss a step even when a frame is lost. Encoders are different: they can change
faster than frames are sent, so they keep their cumulative counter.

The master-mode switch is *not* a selector. It only needs its position (§7.2).

Possible later sources, using the same interface: coded/BCD rotary switches, other
resistor-ladder switches, zones on an analog axis.

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

    // decoded (only what needs the scanning board's timing; toggles are just bits)
    uint8_t  numEncoders;                    // as configured in the wiring table
    int16_t  encoderCount[32];               // cumulative; only numEncoders are sent
    int8_t   rotaryPos[4];                   // 0..11, -1 = unknown / not fitted

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
// Scanner part: needed by board B itself (B decodes these)
constexpr EncoderDef  kEncoders[]  = { { T(J12,1), T(J12,2), StepsPerDetent{4} },
                                       { T(J12,3), T(J12,4), StepsPerDetent{4} } };
constexpr RotaryDef   kRotaries[]  = { { T(J14,1), T(J14,2), T(J14,3),
                                         T(J14,4), T(J14,5), T(J14,6) } }; // pin1..pin6
constexpr AnalogDef   kAnalog[8]   = { {Use::Axis}, {Use::Axis}, {Use::Unused}, … };

// Mapping part: only used by board A
constexpr Toggle3Def  kToggle3[]   = { { T(J13,7), T(J13,8) } };
namespace B {
    constexpr ButtonId   GEAR      = toggle(T(J10,1));       // on-off switch
    constexpr ButtonId   FIRE      = momentary(T(J10,2));    // push button
    constexpr ButtonId   KP_ENTER  = keypad(2, 8);           // row 3, col 8 (momentary)
    constexpr EncoderId  HDG       = encoder(0);
    constexpr SelectorId RADIO     = rotary(0);
    constexpr SelectorId FLAPS     = toggle3(0);
    constexpr AnalogId   THROTTLE  = analog(0);
}
```

Board A compiles **both** wiring files, since it needs B's names for the mappings. Board B
only uses the scanner part of its own file.

* `static_assert`s enforce the board's limits at compile time: ≤ 4 rotaries, ≤ 32 encoders,
  no shift-register bit used twice, rotary pin-1 inputs present, and so on. Adding or
  removing a switch is just a table edit.
* B must be re-flashed only when the **scanner part** of `wiring_b.h` changes (encoders,
  rotaries, analog). The `wiringHash` covers just that part. If you forget to re-flash,
  A shows a warning colour on the LED.

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

**B → A: `STATE` frame** = a serialised `InputState`, about 60 bytes plus 2 per encoder
(≤ 125 bytes even with 32 encoders).
* Sent **when anything changed**, but at most every **2 ms** (500 Hz), and **at least
  every 10 ms** (heartbeat). Worst case ≈ 125 bytes × 500/s ≈ 63 kB/s, inside the
  ~100 kB/s that 1 Mbaud carries. (Going to 1 kHz would need 2 Mbaud; not worth it, since
  2 ms is far below anything you can feel.)
* No ACK or retransmit is needed: every frame is the complete truth.

**A → B: `HEARTBEAT` frame,** every 20 ms:
`{ seq, masterMode, zeroActive, ledCommand, requests }`. It lets B show status on its LED
and lets B know whether A is alive. Room for later: "identify" (blink), "send stats",
config push.

**Presence logic on A:**

| Condition | A's view of B |
|---|---|
| No valid frame yet / none for **50 ms** | `remote.present = false`, all remote inputs read as neutral |
| Valid frames resume | `present = true`, **re-baseline** encoder counters, previous positions and edges (no phantom pulses) |
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
  sys.update(local)                       // master mode, filter switches, zero switch (debounced)
  if mode changed → mode transition (§7.2)
  out.clear(mode.neutrals)                // immediate mode: rebuild every frame; axes start at neutral
  modes[sys.mode]->run(Map{local, remote, prev, out, pulses, sys.filter, now})
                                          // hidden output classes are dropped inside Map (§7.3.1)
  pulses.apply(out, now)                  // OR in the active pulses
  zeroGate.apply(out)                     // §7.3.2: zero / isolated binding; sees `out` as the "logical" state
  hid.send(out)                           // diff against last sent; only changed reports
  prev = {local, remote}
```

### 7.2 Master-mode switch (12 positions with end stop, analog ladder, on A)

The master mode picks **which mapping** turns physical inputs into logical outputs (HID
buttons, keys, axes). It does nothing else. What gets *reported* (positions, pulses) is
decided separately by the filter switches (§7.3.1), so the filters work the same in every mode.

**(assumption)** It uses one 4051 channel on board A. That leaves 7 analog channels on A
for pots and joysticks.

* Decode the position only: 12 bands around nominal voltages, thresholds at the midpoints,
  plus hysteresis. No up/down pulses, no selector; the only consumer is the mode logic.
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
1. Report **everything released**, with axes at the outgoing mode's neutral values, for
   ≥ 30 ms so games see the release.
2. Clear the pulse engine queue and call the new mode's `onEnter()`. **Any state that can't
   be inferred from physical switch positions is reset:** latches, encoder-driven virtual
   axes, long-press timers, and so on. Everything else follows from the switches anyway.
3. **Re-baseline edge detection** so the new mode doesn't fire "pulse on change" for
   switches that were already in position.
4. Run the new mode. Held outputs immediately reflect current switch positions, which
   is what you want.
5. LED colour/blink shows the new mode.

### 7.3 System switches: output filters and the zero switch

These are physical switches on board A, declared in `wiring_a.h` as system inputs. They
never reach the mode functions as ordinary inputs, so a mode can't accidentally map them.
They work the same in every master mode.

#### 7.3.1 Output filter switches

One **on-off switch per output class** decides whether that class is reported:

| Switch | Class | Covers |
|---|---|---|
| `SYS_SHOW_POSITIONS` | `Position` | held outputs that reflect a switch's absolute position: on-off toggles, each position of an on-off-on or rotary switch |
| `SYS_SHOW_PULSES` | `StepPulse` | pulses created from switch changes: on/off pulses of toggles, up/down pulses of on-off-on and rotary switches |
| (always shown) | `Always` | momentary buttons, keypad keys, encoders, axes, anything the mode marks explicitly |

Adding a filter later means one new class plus one row in a small table
(`{ SYS_SHOW_xxx, Class::xxx }`). Nothing else changes.

How the class gets attached, without extra work in the mode code:

* `m.on(input)` returns a small `Signal` value: `{ bool value; ClassMask classes; }`. The
  class comes from the input's kind (§5.1): a `Toggle` gives `Position`, a `Momentary` gives
  `Always`.
* `||`, `&&` and `!` are overloaded and **merge the class masks**. So
  `m.on(A::GEAR) || m.on(A::FIRE)` carries both classes. `Signal` converts to `bool`, so
  `if (m.on(A::SHIFT))` still works.
* Pulse helpers on toggles and selectors are `StepPulse`. `selectorButtons` is `Position`.
  Encoder pulses are `Always`.
* A mode can override the class when needed: `m.hold(out, expr.as(Class::Always))`.

The filter is applied **inside `Map`, per contribution**. A `hold` whose signal has any
hidden class contributes nothing, and a pulse of a hidden class is never queued. Hiding a
class also flushes its pulses that are already queued, so they can't play out after you
switch the filter back on. Because everything is recomputed every frame, toggling a filter
switch takes effect immediately in either direction.

Typical use: when binding in a game's settings screen, hide `StepPulse` to bind toggles by
position, or hide `Position` to bind the up/down pulses of a rotary switch. This works in
**every** mode, not just the generic one.

#### 7.3.2 Zero switch (on-off-on, three positions)

**(assumption)** This is a 3-position toggle (`Toggle3`) on A, called `SYS_ZERO`.

| Position | Name | Behaviour |
|---|---|---|
| Centre | normal | Everything is reported. |
| Side 1 | **Zero + re-report** | Everything is zeroed (below). When it returns to centre: held outputs and axes are re-reported, and **on-off / on-off-on toggles replay** the pulse matching their current position (as before). Rotary up/down pulses, encoder and momentary pulses are not replayed. |
| Side 2 | **Isolated binding mode** | Everything is zeroed. Each logical button (or key) that is **pressed and then released while in this mode** produces **one pulse right after its release**. Every other change is ignored: activation only, deactivation only, axis movement. No toggle replay, no up/down replay. |

**"Zeroed"** means: every button and key released, every axis at its neutral value (below),
and the pulse queue flushed. Scanning, debouncing and mapping keep running the whole time,
so their state stays current. Only what reaches USB is gated.

**Isolated binding mode, in detail.** It's a binding helper. In a game's "press a button to
bind" screen, the game should see only clean, separate presses of exactly the logical button
you mean, and none of the noise around it: other toggles changing, a pot being touched, a
held button.

* While in side 2, the full pipeline (mapping → filters → pulse engine) keeps running into a
  **shadow** output that is not sent. The real output stays zeroed, except for the pulses below.
* For each digital logical output (every joystick button **and** keyboard key), the gate
  watches the shadow state. When an output that **went on during this mode** goes **off**
  again (still during this mode), the gate immediately queues **one standard pulse** of that
  output on the real output (`kPulseOnTime` / `kPulseOffTime`, §7.5).
  * It has to wait for the release: only then is it known that this was a complete
    press-and-release.
  * An output that was already on when the mode was entered and is released during it is
    ignored. So is one pressed during the mode and still held when leaving it.
* **Everything else is ignored:** activations without a release (yet), releases without a
  preceding press in this mode, axis movement. No toggle replay and no up/down replay.
* Every press-then-release produces its own pulse. Pressing the same button three times gives
  three pulses, queued per output like any other pulse.
* Pulse-generated activations count like any other. With pulses shown, flicking a toggle mapped
  to "pulse on ON" produces that pulse's button once the pulse has ended. With pulses hidden
  (§7.3.1), it produces nothing, and only a position button would count. That way the filter
  switches choose *what* can be bound.
* On return to centre, pulses that are still queued are **dropped**, and normal reporting
  resumes immediately: current held positions and axes are reported again, with no replay.

**Switch-over details:**
* Going from side 1 to side 2 physically passes through the centre. To stop that from
  counting as "returned to centre", the zero switch uses a longer stable time than normal
  toggles (default 150 ms) before a centre position is accepted.
* Entering or leaving either zero position never changes the master mode or its state.

**Neutral axis values are defined per axis *and* per master mode.** Each mode declares a
neutral for each axis it uses, as `Min`, `Centre`, `Max` or an explicit fraction. The
default is `Centre`. Neutral is used for:
* the zero switch (both sides)
* mode transitions (§7.2)
* axes the mode doesn't write in a frame (`out.clear()` starts every axis at its neutral)
* JB's axes while board B is absent

So the descriptor's axis range (signed or unsigned) no longer matters for zeroing.

### 7.4 Mapping API

Each master mode is a class. As a C# developer you'd recognise it as a small "render"
method that runs every millisecond and declares what the outputs *should be right now*.

**Bindings, not tables.** A mapping is **not** keyed on physical inputs or on logical outputs.
There is no "settings for input X" record and no "source of button Y" record. Each helper
call is **one standalone binding**, like a row in an m:n junction table:

* The same physical input can appear in any number of bindings. A toggle can drive two
  position buttons **and** two pulse buttons; a rotary switch can report its position
  **and** emit up/down pulses like an encoder.
* The same logical output can be fed by any number of bindings, which are OR-ed for buttons.
* Each binding carries its own options (pulse type, output class, curve, deadzone, …).
  Nothing is shared between bindings unless you share it in code.
* Bindings are plain C++ statements, so `if`/`else` on any input switches between whole sets
  of bindings. That covers **sub-modes** inside a master mode with no extra machinery.

```cpp
class FlightSim : public Mode {
    // Virtual-axis state: can't be inferred from switches → member of the mode,
    // reset whenever this master mode is entered.
    RateAxis    yaw   { /*full range per second*/ 0.8f };
    RateAxis    pitchTrim { 0.25f };
    StepAxis    elevTrim  { /*per encoder click*/ 0.01f };
public:
    FlightSim() {
        neutral(JA.axis(Z),  Neutral::Min);       // throttle: zero = idle
        neutral(JA.axis(RZ), Neutral::Centre);    // (Centre is the default anyway)
    }
    const char* name() const override { return "Flight sim"; }
    void onEnter() override { yaw.reset(); pitchTrim.reset(); elevTrim.reset(); }

    void run(Map& m) override {
        // ── Held (level) outputs: "output is ON while condition is true".
        //    Multiple bindings to the same output are OR-ed → many-to-one is natural.
        // JA = board A's joystick, JB = board B's joystick. Any input can go to either.
        m.hold(JA.btn(2),  m.on(A::TRIGGER) || m.on(B::TRIGGER2));   // many → one
        m.hold(JA.btn(3),  m.on(A::MASTER_ARM));                     // one → many …
        m.hold(KEY(F1),    m.on(A::MASTER_ARM));                     // … as many as you like

        // ── One on-off toggle, four independent bindings (your example 1)
        m.hold(JA.btn(1),  m.off(A::LIGHTS));          // physical position 1 → logical 1 [Position]
        m.hold(JA.btn(2),  m.on (A::LIGHTS));          // physical position 2 → logical 2 [Position]
        m.pulseOnPress  (A::LIGHTS, JA.btn(3));        // 1 → 2 → pulse logical 3        [StepPulse]
        m.pulseOnRelease(A::LIGHTS, JA.btn(4));        // 2 → 1 → pulse logical 4        [StepPulse]

        // ── One rotary switch: absolute position AND encoder-like pulses (example 2)
        m.selectorButtons(B::RADIO, JB.btn(20));             // pos 1..12 → hold btn 20..31 [Position]
        m.selectorPulses (B::RADIO, JB.btn(40), JB.btn(41)); // step up / step down        [StepPulse]
        m.selectorButtons(A::FLAPS, JA.btn(50));             // 3-pos toggle → 3 buttons
        m.selectorPulses (A::FLAPS, KEY(F7), KEY(F6));

        // ── Chords and shift layers are just code
        Signal shift = m.on(A::SHIFT);   // Signal = bool + output class (§7.3.1)
        m.hold(JA.btn(5),  !shift && m.on(A::BTN7));
        m.hold(JA.btn(6),   shift && m.on(A::BTN7));
        m.hold(JA.btn(7),  m.on(A::BTN8) && m.on(A::BTN9));          // chord
        m.pulseOnChange(A::PITOT, KEY(H));                          // any flip → tap H
        m.tapOnPress   (A::SAVE,  KEY(LCTRL, S));                   // key combo

        // ── Encoders
        m.encoderPulses(B::HDG, JB.btn(1), JB.btn(2));       // CW → btn 1, CCW → btn 2

        // ── Axes, three ways (§7.4.1)
        // Sub-mode: a physical switch decides what stick X does. Just an `if`.
        if (m.on(A::STICK_DIRECT)) {
            m.axis(JA.axis(X), m.analog(A::STICK_X).cal().deadzone(0.03f));   // 1. direct
        } else {
            yaw.integrate(m, m.analog(A::STICK_X).cal().deadzone(0.05f).curve(2.0f));
                                                                  // 2. integral of an axis:
        }                                                         //    more deflection = faster
        m.axis(JA.axis(RY), yaw.value());       // reported in both sub-modes; keeps its value
                                                // while not being driven
        pitchTrim.integrate(m, A::TRIM_UP, A::TRIM_DOWN);         // 3. integral of buttons
        m.axis(JA.axis(RX), pitchTrim.value());
        elevTrim.step(m.delta(B::TRIM));                          // (encoder clicks → steps)
        m.axis(JA.axis(RZ), elevTrim.value());

        m.axis(JA.axis(Z),  m.analog(A::THROTTLE).cal().curve(1.5f));
        m.hold(JA.btn(60),  m.analog(A::THROTTLE).cal() < 0.05f);   // axis → button

        // ── B absent is just data
        if (!m.remotePresent()) { /* e.g. fall back to local alternatives */ }
    }
};

Mode* const kModes[12] = { &generic, &flightSim, &spaceSim, … };
```

Semantics, kept intentionally simple:

* **Buttons and keys:** OR of every binding that holds them, plus any active pulse.
* **Axes:** last writer wins. A debug build warns if an axis is written twice in one frame.
  Use explicit helpers when combining is intended: `m.axisMax(…)`, `m.axisSum(…)`,
  `splitAxis(…)` (one pot → two half-axes), `mergeAxes(…)` (two toe brakes → one rudder).
  An axis no binding writes in a frame sits at its neutral value.
* `m.on(x)`, `m.off(x)`, `m.pressed(x)` (rising edge this frame), `m.released(x)`,
  `m.delta(enc)`, `m.position(sel)`, `m.stepDelta(sel)`: inputs from absent B read as
  off / 0 / unknown.
* Edge helpers compare against the previous frame, so they need no state in the mode.
  Stateful helpers (`RateAxis`, `StepAxis`, `Latch`, `LongPress`, `DoubleTap`) are members of
  the mode class and are reset in `onEnter()`, because their state can't be inferred from the
  physical switches.
* Every helper tags what it writes with an output class (§7.3.1), so the filter switches
  work on any mode with no extra code. Virtual axes are `Always`.
* No helper assumes anything about the other bindings. That is why sub-modes, layers and
  "one input, many meanings" are just ordinary control flow.

#### 7.4.1 Logical axes: direct, integral of an axis, integral of buttons

| Way | Helper | State | Behaviour |
|---|---|---|---|
| 1. Direct | `m.axis(out, m.analog(in).cal()…)` | none | Logical axis = calibrated physical axis, with optional deadzone, curve, invert, range. |
| 2. Integral of a physical axis | `RateAxis::integrate(m, signal)` | value | Each frame: `value += rate(signal) × maxSpeed × dt`, clamped to the axis range. A deadzone around the centre means "stick at rest = axis stays put". A curve gives fine control near centre and fast movement at full deflection. |
| 3. Integral of buttons | `RateAxis::integrate(m, upInput, downInput)` | value | Same integrator, rate = +1 / −1 / 0 from two buttons (both = 0). Optional ramp: speed grows the longer a button is held. |
| (Steps) | `StepAxis::step(m.delta(enc))` | value | Fixed step per encoder click or per pulse. |

* `maxSpeed` is in "full range per second", so `0.5` means "2 s from end to end at full
  deflection". `dt` comes from `Map`, so the speed doesn't depend on the loop rate.
* **The state is scoped to the master mode.** The objects are members of the mode class, so
  each mode has its own. They are reset to the axis's neutral value whenever the master mode
  is entered (§7.2). Changing a sub-mode switch *inside* a mode does **not** reset them. In
  the example, `yaw` keeps its value while stick X is in direct mode.
* Each virtual axis is integrated at most **once per frame**. A debug build warns if the same
  object is integrated twice, which would double its speed.
* While the zero switch is active, mapping keeps running, so a virtual axis keeps moving if its
  stick or buttons are moved; only the report is zeroed. On return the current value is
  reported. **(assumption, see §13)**

**Generic mode, for binding in a game's own control settings.** It is generated
automatically from the wiring tables, so it never needs maintenance when you add or
remove switches. Each unit's inputs go to its own joystick (A → JA, B → JB), with one
**fixed button layout** assigned at compile time:

| Input | Output (fixed button numbers) | Class |
|---|---|---|
| Momentary button, keypad key | 1 held button | `Always` |
| On-off toggle | 2 held buttons (one per position: off, on) | `Position` |
| | "on" / "off" pulse buttons | `StepPulse` |
| On-off-on toggle, rotary switch | 1 held button per position | `Position` |
| | up / down pulse buttons | `StepPulse` |
| Encoder | CW / CCW pulse buttons | `Always` |
| Analog channel | 1 axis | `Always` |

There's only one generic mode now. Showing/hiding positions and pulses is done with the
filter switches, which work in every mode.

Every output in this layout has a **permanent button number**. The filters only hide or show
buttons; they never renumber them. Example: the RADIO rotary's position 3 is always JB
button 22, and its "up" pulse is always JB button 40. If you bind button 40 in a game while
positions are hidden and later show positions again, button 40 is still RADIO-up. Position 3
does *not* move down to fill the gap. (The other option, packing visible outputs together,
would make the numbers depend on the filter settings and silently break bindings.)

**Button budget (needs a decision, see §13).** Each unit gets 128 buttons. With the full
generic layout above, board A's fixed parts already use 68: 3 rotaries × 14, 1 encoder × 2,
and 24 keypad keys. That leaves 60 buttons for the remaining 40 shift-register inputs (64 minus
18 rotary bits, 2 encoder bits and 4 system-switch bits). A momentary uses 1 and an on-off
toggle uses 4 (2 positions + 2 pulses). So **with more than about 6 toggles on A, the full
generic layout no longer fits** in 128. A `static_assert` makes the build fail rather than
silently dropping anything. Options:
* a per-input flag in the wiring table to trim its generic outputs (e.g. "positions only"), or
* a third joystick used only by the generic mode for overflow, or
* letting the generic mode put A's overflow on JB when B has room.

Game-specific modes aren't affected: they only use the buttons they bind.

### 7.5 Pulse engine

Games poll input once per frame, often at 30–60 Hz, and sometimes only react to presses
longer than one or two frames. A 1 ms pulse is invisible to them. So:

* Pulse timing is defined **centrally** in one place: `kPulseOnTime` = **100 ms** (minimum;
  some games miss even 50 ms pulses) and `kPulseOffTime` = **100 ms** (the gap before the
  same output can pulse again). A mode can lengthen them if a game needs more, but never
  go below the minimum.
* That limits one output to **5 pulses per second**. Turn an encoder faster than that and
  pulses queue up. A **queue limit per output** (default 5) stops a fast spin from building
  a multi-second backlog that keeps "turning" after you stop. Overflowing pulses are dropped.
* Key combos: press modifiers → wait about 10 ms → key → release in reverse order. Some
  games miss the modifier otherwise.
* If an output is both held and pulsed in the same frame, the hold wins (OR). That's
  documented behaviour, not a bug.

### 7.6 USB HID

**(assumption)** Windows and DirectInput-style games. Composite USB device:

| Interface / collection | Content |
|---|---|
| Joystick **JA** (board A) | 128 buttons, 8 axes × 16 bit (X Y Z Rx Ry Rz Slider Dial). About 33 bytes per report. |
| Joystick **JB** (board B) | same |
| Keyboard | modifiers + 6KRO or an NKRO bitmap |
| CDC serial | debug console (§10) |

JA and JB are separate top-level collections, so Windows shows two game controllers. 8
axes per joystick (the DirectInput maximum) covers A's 7 free analog channels and B's 8.

**JB is always in the descriptor, even when B is absent.** It just reports neutral. If it
disappeared and came back, Windows would see a different device, and games could lose or
reorder their bindings.

Decide before freezing the descriptor: does either joystick need a hat switch (POV)? It costs
1 byte and can't easily be added later without breaking bindings.

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
setup(): pins, status LED, UART1 (TX = 43, RX = 44, same as A), start scanner on core 1
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
  * A: colour = master mode; slow blink = B absent; red flash = errors; white = zeroed, white blink = isolated binding mode.
  * B: green = link OK; amber blink = no heartbeat from A.

---

## 11. Testing strategy

* **Native unit tests** (`pio test -e native`) for all of `lib/core`: debouncer edge cases,
  quadrature tables including bounce sequences, the rotary-12 decoder including long
  make-before-break transitions (garbage and wrong-but-valid codes), selector up/down with
  wrap-around and skipped positions, the 1€ filter, COBS/CRC round-trip and garbage resync,
  and mapping helpers (pulse engine timing, edge baselining on mode change, toggle re-sync
  on zero release, isolated binding mode pulsing only complete press-and-release cycles, filter classes through `||`/`&&`).
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
| M6 | Mapping API, pulse engine, master-mode, filter and zero switches | first real game profile works end-to-end |
| M7 | Polish | calibration in NVS, LED codes, more profiles, optional SPI/DMA chain read |

---

## 13. Decisions and open questions

### Decided

* **Link wiring:** R2/R3 are crossed on board B. Same UART pins in both firmwares, no
  boot-time contention (§1.1, §1.6).
* **Rotary switches:** make-before-break with long overlap. A position counts only after
  being stable for a central `kRotaryStableTime` of about 200 ms (§5.3). No end stops.
* **Multi-position switches:** B sends positions only. A derives up/down from the previous
  vs the new position. Encoders keep cumulative counters (§5.4, §6).
* **Master-mode switch:** 12 positions with an end stop, position only (§7.2).
* **Pulses:** central minimum of 100 ms on / 100 ms off (§7.5).
* **HID:** one joystick per unit (JA, JB) with 128 buttons each, plus keyboard (§7.6).
* **Master mode vs filters:** the master mode only picks the mapping. On-off **filter
  switches** (show positions, show up/down pulses, more later) decide what gets reported, in
  every mode (§7.2, §7.3.1). Encoder pulses are always reported and have no filter.
  There is one generic mode (§7.4).
* **Zero switch (on-off-on):** side 1 = zero + re-report, with toggle pulse replay. Side 2 =
  isolated binding mode: everything zeroed, and each logical button or key that is pressed and
  then released in this mode gives one pulse right after the release. Pulse-generated
  presses count too. Nothing else, no replay. Pulses still queued when it returns to centre
  are dropped (§7.3.2).
* **Neutral axis values** are defined per axis and per master mode (§7.3.2).
* **Mode state:** anything that can't be inferred from physical switch positions is reset
  on mode change (§7.2).
* **Bindings are standalone** (m:n, like a junction table), not keyed on physical inputs or
  logical outputs. One switch can report its position *and* emit up/down pulses, with options
  set per binding. Sub-modes are plain `if`s in the mode (§7.4).
* **Logical axes** can be driven directly by a physical axis, as the integral of a physical
  axis, or as the integral of buttons (plus encoder steps). The integrator state is per master
  mode and is reset on mode change (§7.4.1).
* **Current hardware:** A has 3 rotaries, the mode switch and 1 encoder. B has 1 rotary and a
  few encoders. Counts will change, so everything comes from the wiring tables, with
  compile-time checks against the board's limits (4 rotaries, 32 encoders, 64 bits, 128 buttons).

### Still open

1. **Generic button budget:** the full generic layout overflows 128 buttons on A with more
   than about 6 on-off toggles (§7.4). Trim per input in the wiring table, add a third joystick
   for the generic mode, or spill onto JB?
2. **Virtual axes while zeroed:** keep integrating while the zero switch is active (assumed),
   or freeze until it returns to centre (§7.4.1)?
3. **Hat switch** on JA/JB: wanted? It has to be decided before the descriptor is frozen (§7.6).
4. **Encoder acceleration** (fast spin → bigger steps)? It's only useful for encoders mapped to
   virtual axes, since pulses are capped at 5/s anyway (§7.5).
5. **Analog:** how many channels are joysticks vs simple pots on each board? Will you fit the
   100 nF caps? Is the master-mode switch on a 4051 channel of A (assumed)?
6. **Configuration:** is compile-and-flash for mapping changes acceptable long-term
   (proposed), or do you eventually want changes without re-flashing (see §14)?
7. **Keypad on B:** the firmware supports it automatically. Just confirm whether it's planned.
8. **Both USBs connected at once** (handy for debugging both boards at the same time): check
   whether the S3-Zero has a diode between USB VBUS and its 5V pin. Otherwise the two PCs'
   (or ports') 5V rails get tied together via the Cat5 (hardware question, affects dev workflow).

---

## 14. Brainstorm: later ideas

* **Encoder → mouse wheel / mouse axis** outputs (consumer of the same `delta`).
* **Long-press / double-tap / hold-to-repeat** helpers (one button, several functions).
* **Toggle-vs-game desync fix:** besides the zero switch's toggle re-sync, a separate "resync" gesture for games
  that only offer "toggle X" commands.
* **Per-mode pulse timing presets** ("this game needs 150 ms presses"), on top of the central 100 ms minimum.
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
