# Sega Master System for Ulx3s ECP5 FPGA

## Introduction

This is a version of the Sega Master System 8-bit games console for the Ulx3s board, written entirely in Verilog.

It has HDMI and optional VGA output. The resolution is 640x480 at 60MHz.

Joypad 1 is implemented by using the buttons.

There is audio output, but it needs improving.

It currently uses the Europe/USA 1.3 BIOS, which, on power-up,  displays the Sega trademark and then looks for a game cartridge.

Games are loaded via an On-Screen Display (OSD) overlaid on the HDMI output. The OSD is started by pressing all four direction buttons. 

To run the OSD you need micropython on the ESP32, and then do `import osd`.

The OSD displays a file browser showing files on the ESP32 flash memory and an SD card. You navigate to a .sms file using the direction buttons, and select it with the right button. The game should then start.

There are lots of games on the [planetemu](https://www.planetemu.net/roms/sega-master-system) site.

## Implementation

It is written entirely in Verilog. The top level and VDP implementation are new.

The rom cartridge is loaded into the SDRAM and executed from there, using the Sega mapper. The few games that do not use the Sega mapper will not work.

The VDP implementation generates VGA output, which is then converted to HDMI. It does not use the timing of the original VDP chip. Legacy modes compatible with Texas Instruments TMS9918 chip are implemented for compatibility with the Sega SG 1000.

Console memory (8KB) uses BRAM, as does the video ram (16KB), and the bios rom (32KB).

Top-level parameters allow the VGA output to be selected, and also LCD and LED diagnostics.

## Installation

You need recent versions of Yosys, nextpnr-ecp5, project trellis and fujprog.

To build do:

```
cd ulx3s
make prog
```

It currently defaults to an 85F board. To use a 12F add `DEVICE = 12k` to the Makefile.

The python files from esp32/osd should be uploaded to the ESP32.

## Bugs

Audio needs improving.

Only joypad 1 is supported and seems to have some problems.

There is a vertical colored bar down the left of some games.

Various edge cases in the VDP are not correct.

Not all games run.

These are some of the games that seem to have problems:

- Asterix - hangs
- Babu Baku Animal - does not respond to start button
- Chop Lifter - hangs
- Dracula - screen corruption
- Fantastic Dizzy - Software Error
- Jungle Book - screen corruption
- Lemmings - screen corruption
- Lion King - crashes
- Miracle World - hangs
- Ms Pacman - hangs
- Outrun - screen corruption
- Space Harrier - hangs
- Spell Caster - hangs
- Wanted - screen corruption
- Zaxxon 3D - screen corruption
