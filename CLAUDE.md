I'm planning an HID device for games and whatnot. Indoors. Reads physical switches/buttons/joysticks/encoders and such. Two separate devices (A and B) with A connected to the computer and B connected to A.

Two identical custom PCBs (boards A and B) + a keypad PCB closely tied to board A. 
Both boards should be identical in terms of layout (same manufactured board) but not necessarily components (I will be assembling them myself).

Both boards use ESP32-S3-Zero controllers. The two ESP32s will probably have completely different firmware. I want to only use the normal though-hole/header pins on the ESP32s, no POGO-pins or direct soldering to the PCB.

When in use, Board A is connected to the computer via the USB connector on the ESP32 and Board B is connected to A with a normal Cat5 UTP cable.
When programming ESP32 B, it will be connected with its own USB to the computer and ESP32 A will no longer be connected to the computer. The two boards will still be connected with the Cat5 but I'm assuming that's fine (B will power A but A can't do its USB stuff). If really needed, I can make sure to disconnect the Cat5 cable before connecting B to the computer.

The ESP32's will either be powered by their own USB or incoming 5V from the other board via the Cat5 cable

The ESP32 on board A does the HID/USB stuff.
The ESP32 on board B reports switch/button/joystick state changes via UART (over the Cat5 cable) to board A.

The Cat5 cable is at most 2 meters long.
- Pair 1 (pins 1&2) carry data from ESP32 A's TX + GND.
- Pair 2 (pins 3&6) carry data from ESP32 B's TX + GND.
- Pairs 3&4 each carry +5V + GND.
Board B's firmware will swap its TX/RX pins in relation to A so no crossover cable is needed.

The PCB's are 4-layer, with 3v3 and GND planes in the middle. The 5V to/from the Cat5 cable will have to run in its own trace between the RJ45 jack and the ESP32's 5V pin.

All logic should be 3v3. 5V is only used to power the ESP32 currently not connected by USB (but instead the Cat5 cable).

Both boards will have the following (each):
8x 74HC165 with one 8-channel screw terminal bank and pull-up resistor network each for reading buttons and switches.
4x BC547 NPN transistor (with base pull-down) for controlling a few pins (floating or GND) that are used for reading/scanning some weird rotary switches. Only signal level. Also has its own screw terminal bank.
1x 74HC4051 for reading joysticks and other pots + screw terminals.
1x RJ45 jack for connecting to the other board.

Board A (or possibly both boards) also has a short (10-20cm) IDC ribbon cable connecting an 8x3 keypad with its own shift register, chained "outside" the ones on the board so data only goes *from* the keypad.
The cable transmits power, shift-register stuff and 3 lines for scanning the rows.
Every other conductor in the IDC cable is GND.

Reference GND and 3v3 for pots and switches will be taken from a single screw terminal (one for GND, one for 3V3) and will be distributed by means of external terminal blocks or something like that.

The 3 lines for scanning the rows on the keypad will also be used for setting the address on the 74HC4051.

The IDC header for the keypad will not be populated on board B (or possibly will be of board B also gets a keypad). It might need a pull-up resistor on the Q7 line to keep it stable.

The rotary encoders (turned by hand) will be read by the main shift-register chain.

This is my first PCB ever. Designing in KiCad 10. I have done some Arduino projects before with perfboard and such. Nothing complex. Basic understanding of electronics in terms of the logic and static stuff. I'm lost when it comes to EDC and reflections etc. I am a C# programmer by trade.