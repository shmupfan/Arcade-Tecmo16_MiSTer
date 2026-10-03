# Tecmo 16 - MiSTer FPGA Core (draft)

Final Star Force, Riot and Ganbare Ginkun (Tecmo 16 hardware). Not yet
released; see docs/PLAN.md and the milestone findings in docs/.

## Controls and options

Buttons 1 to 3, Start and Coin, as in the MAME driver. Keyboard uses the
MAME defaults; P pauses and resumes.

OSD: DIP switches per set (from the MAME driver), aspect ratio,
orientation, scandoubler options, HDMI scale (Normal, V-Integer, Narrower
or Wider HV-Integer), pause while the OSD is open (on by default), and for
Final Star Force (vertical) a Rotate option, CW (the MAME direction) or
CCW, for monitors mounted for the opposite rotation. Riot, Ganbare Ginkun,
and Final Star Force with Orientation set to Horizontal can crop the
224-line picture to 216 lines (an exact 5x on 1080p) with an adjustable
offset.

Rotate only turns the HDMI picture (the frame buffer). On a CRT the
picture is not rotated: if your monitor is mounted for ROT270 games
(1945k III and most other vertical games), set Final Star Force's Flip
Screen DIP switch to On instead, as you would on the original cabinet.
