I'm planning an HID device for games and whatnot. Indoors. Reads physical switches/buttons/joysticks/encoders and such. Two separate devices (A and B) with A connected to the computer and B connected to A.

Two identical main PCBs (boards A and B, KiCad project `PCBs/Shared_Main`), each with a chain of small shift-register modules (`PCBs/Shift_Register_Module`).
Both main boards should be identical in terms of layout (same manufactured board) but not necessarily components (I will be assembling them myself).
The keypad (`PCBs/Right_Keypad`) is obsolete and no longer part of the design.

Both boards use ESP32-S3-Zero controllers. The two ESP32s will have different firmware built from one shared codebase. I want to only use the normal though-hole/header pins on the ESP32s, no POGO-pins or direct soldering to the PCB.

When in use, Board A is connected to the computer via the USB connector on the ESP32 and Board B is connected to A with a normal Cat5 UTP cable.
When programming ESP32 B, it will be connected with its own USB to the computer and ESP32 A will no longer be connected to the computer. The two boards will still be connected with the Cat5, which is fine (B powers A, A just can't do its USB stuff).
Assume the S3-Zero has no diode between USB and its 5V pin: never have both boards on USB at the same time while the Cat5 is connected. For debugging both at once, use a patch cable with the +5V wires (pins 4 and 7) cut.

The ESP32's will either be powered by their own USB or incoming 5V from the other board via the Cat5 cable.

The ESP32 on board A does the HID/USB stuff and all the mapping.
The ESP32 on board B reports its full (debounced, decoded) input state via UART (over the Cat5 cable) to board A. Board B being absent is valid; board A is always master.

The Cat5 cable is at most 2 meters long.
- Pair 1 (pins 1&2) carry data from ESP32 A's TX + GND.
- Pair 2 (pins 3&6) carry data from ESP32 B's TX + GND.
- Pairs 3&4 each carry +5V + GND.
The two 100 Ω UART series resistors (R2/R3) are fitted crossed on board B ("B: Cross" silkscreen), so both firmwares use the same TX/RX pins and no crossover cable is needed. How they are crossed is settled.

The main PCB is 4-layer, with GND (In1) and 3v3 (In2) planes in the middle. The 5V to/from the Cat5 cable runs in its own trace between the RJ45 jack and the ESP32's 5V pin, through polyfuse F1 (0.5 A).

All logic should be 3v3. 5V is only used to power the ESP32 currently not connected by USB (but instead the Cat5 cable).

Each main board (Shared_Main) has:
- 1x ESP32-S3-Zero (U1), USB end at the board edge.
- 1x 74HC4051 (U2) for reading joysticks and other pots, with an 8-channel screw terminal (J5). 100 nF caps on the analog inputs will be fitted.
- 4x BC547 NPN transistor (with base pull-down R7) for controlling a few pins (floating or GND) that are used for reading/scanning some weird rotary switches. Only signal level. Own 4-channel screw terminal (J2). All four bases are driven together from ADDR2 through R1 (no separate phase pin).
- 1x RJ45 jack (J16) for connecting to the other board.
- 1x 3-pin power screw terminal (J1): +3V3_EXP (polyfuse F2, 0.1 A), GND, +5V_EXP (polyfuse F3, 0.2 A). The silkscreen labels sit between the screws on purpose (they don't fit in line).
- 1x 5-pin right-angle socket (J3) at the left edge for the shift-register chain: 1 GND, 2 CP, 3 /PL, 4 Q7, 5 +3V3. CP and /PL have 47 Ω series resistors (R10/R9).
- 1x 9-pin expansion header (J4): ADDR0-2 and AUX5-AUX0.
- Mounting hole H1 is tied to GND (chassis), H2/H3 are unplated.

Shift-register modules (Shift_Register_Module, 2-layer): each has 1x 74HC165, 8x 10k pull-ups and an 8-channel screw terminal (J1) for buttons, switches and encoders. All inputs switch to GND, so raw 0 = active. J1 pin 1 is D7 (read first), pin 8 is D0.
- J2 "Upstream" (right-angle socket, left edge): data comes in from the next module into DS.
- J3 "Downstream" (right-angle header, right edge): Q7 goes out towards the main board.
- Same 5-pin order as the main board's J3, so modules plug edge to edge, extending to the left of the main board: `[module N] … [module 2][module 1][main]`. Terminal rows line up with the main board's.
- The last module in the chain has its DS tied to 3v3 with a jumper in its J2 socket (pin 4 to pin 5), so bits read past the end of the chain are 1 (= inactive).
- Each main board will have 8-10 modules (not decided yet), and always at least one.
- The modules are mounted by other means (no mounting holes on purpose).

Reference GND and 3v3 for pots and switches will be taken from the single power screw terminal (J1) and will be distributed by means of external terminal blocks or something like that.

The rotary encoders (turned by hand) are read by the shift-register chain.

The USB and RJ45 connectors don't go through the enclosure wall. They connect to separate panel-mounted counterparts inside the box.

ESP32-S3-Zero pin map (both boards):
- GPIO1: ADDR2 (4051 S2, also drives the rotary-switch transistors)
- GPIO2: ADDR1 (4051 S1)
- GPIO3: ADDR0 (4051 S0)
- GPIO4: SR_PL, GPIO5: SR_CP, GPIO6: SR_Q7
- GPIO7: 4051 output, analog in (ADC1_CH6)
- GPIO8-13: AUX5-AUX0, spare, on the expansion header J4
- GPIO43/44: UART TX/RX
- GPIO21: on-module RGB LED
(ADDR0 and ADDR2 are on GPIO3 and GPIO1 so the traces don't have to cross.)

Weird rotary switches: 12 positions, 7 contacts, rotate infinitely (no end stops), make-before-break with a very wide wiper. Read in two phases (pin 1 pulled up / pin 1 sunk via the transistor). Transition readings are either garbage or one of the two adjacent positions, so a short debounce (~20 ms, tuned on the bench) is enough. Exception: halfway between 12 and 1 the contacts give the real code of position 6 for as long as the knob sits there, so non-adjacent jumps need a long stable time (~1 s, also blocks phase-mix artefacts).

Board A also has these system switches:
- Master-mode switch: 12 positions with end stop, resistor ladder on the last 4051 channel (7). It selects which mapping is used.
- Filter switches (on-off): show/hide absolute switch positions, show/hide up/down pulses. More may come later.
- Zero switch (on-off-on): one side zeroes everything and re-reports the current state when returned; the other side is an "isolated binding mode" (each logical button pressed and released in it gives one pulse).

The firmware plan is in `firmware/FIRMWARE_PLAN.md` (decisions and open questions in §13). Key points: one joystick per unit with 128 buttons + keyboard; mappings are hand-written C++ per master mode as standalone m:n bindings; a central 100 ms minimum pulse length.

This is my first PCB ever. Designing in KiCad 10. I have done some Arduino projects before with perfboard and such. Nothing complex. Basic understanding of electronics in terms of the logic and static stuff. I'm lost when it comes to EDC and reflections etc. I am a C# programmer by trade.
