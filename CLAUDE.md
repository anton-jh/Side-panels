I'm planning an HID device for games and whatnot. Indoors. Reads physical switches/buttons/joysticks/encoders and such. Two separate devices (A and B) with A connected to the computer and B connected to A.

Two identical custom PCBs (boards A and B) + a keypad PCB closely tied to board A.
Both boards should be identical in terms of layout (same manufactured board) but not necessarily components (I will be assembling them myself).

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
The two 100 Ω UART series resistors (R2/R3) are fitted crossed on board B ("Cross on board B" silkscreen), so both firmwares use the same TX/RX pins and no crossover cable is needed.

The PCB's are 4-layer, with 3v3 and GND planes in the middle. The 5V to/from the Cat5 cable will have to run in its own trace between the RJ45 jack and the ESP32's 5V pin.

All logic should be 3v3. 5V is only used to power the ESP32 currently not connected by USB (but instead the Cat5 cable).

Both boards will have the following (each):
8x 74HC165 with one 8-channel screw terminal bank and pull-up resistor network each for reading buttons and switches.
4x BC547 NPN transistor (with base pull-down) for controlling a few pins (floating or GND) that are used for reading/scanning some weird rotary switches. Only signal level. Also has its own screw terminal bank. All four bases are driven together from ADDR2 (no separate phase pin).
1x 74HC4051 for reading joysticks and other pots + screw terminals. 100 nF caps on the analog inputs will be fitted.
1x RJ45 jack for connecting to the other board.

Board A (and most probably board B too) has a short (10-20cm) IDC ribbon cable connecting an 8x3 keypad with its own shift register, chained "outside" the ones on the board so data only goes *from* the keypad.
The cable transmits power, shift-register stuff and 3 lines for scanning the rows.
Every other conductor in the IDC cable is GND.

Reference GND and 3v3 for pots and switches will be taken from a single screw terminal and will be distributed by means of external terminal blocks or something like that.

The 3 lines for scanning the rows on the keypad are also the address lines of the 74HC4051, and ADDR2 also sets the rotary-switch phase.

The keypad Q7 line has a pull-up (R8), so the IDC header can be left unpopulated. The firmware detects whether a keypad is present.

The rotary encoders (turned by hand) will be read by the main shift-register chain.

ESP32-S3-Zero pin map (both boards):
- GPIO1-3: ADDR0-2 (4051 S0-S2, keypad rows 1-3; ADDR2 also drives the rotary-switch transistors)
- GPIO4: SR_PL, GPIO5: SR_CP, GPIO6: SR_Q7
- GPIO7: 4051 output, analog in (ADC1_CH6)
- GPIO8-13: AUX5-AUX0, spare, on the expansion grid
- GPIO43/44: UART TX/RX
- GPIO21: on-module RGB LED

Weird rotary switches: 12 positions, 7 contacts, rotate infinitely (no end stops), make-before-break with a very wide wiper. Read in two phases (pin 1 pulled up / pin 1 sunk via the transistor). Transition readings are either garbage or one of the two adjacent positions, so a short debounce (~20 ms, tuned on the bench) is enough. Exception: halfway between 12 and 1 the contacts give the real code of position 6 for as long as the knob sits there, so non-adjacent jumps need a long stable time (~1 s, also blocks phase-mix artefacts).

Board A also has these system switches:
- Master-mode switch: 12 positions with end stop, resistor ladder on the last 4051 channel (7). It selects which mapping is used.
- Filter switches (on-off): show/hide absolute switch positions, show/hide up/down pulses. More may come later.
- Zero switch (on-off-on): one side zeroes everything and re-reports the current state when returned; the other side is an "isolated binding mode" (each logical button pressed and released in it gives one pulse).

The firmware plan is in `firmware/FIRMWARE_PLAN.md` (decisions and open questions in §13). Key points: one joystick per unit with 128 buttons + keyboard; mappings are hand-written C++ per master mode as standalone m:n bindings; a central 100 ms minimum pulse length.

This is my first PCB ever. Designing in KiCad 10. I have done some Arduino projects before with perfboard and such. Nothing complex. Basic understanding of electronics in terms of the logic and static stuff. I'm lost when it comes to EDC and reflections etc. I am a C# programmer by trade.
