# Third-party notices

Hi-MD Dream Drive is licensed under the GNU General Public License v3 (see
[`LICENSE`](LICENSE)). That choice is not optional: the CH376 / USB host code in
`src/` is derived from S0urceror's **MSX-USB** driver sources, which are
GPLv3-only, so any derivative must also be GPLv3.

This project does **not** redistribute any of the third-party components below.
They are downloaded from their upstream projects at build time by
[`tools/fetch-nextor.sh`](tools/fetch-nextor.sh), or supplied by you. Their
copyrights and licenses are their own; the notices are reproduced here.

---

## Nextor (kernel ROM) — Nestor Soriano (Konamiman)

- Project: https://github.com/Konamiman/Nextor
- Used as: the Nextor 2.1.4 kernel base file (`Nextor-2.1.4.base.dat`) that our
  driver is linked into to produce `DDFIRMWA.ROM` and `NEXTOR-HIMD.ROM`. Fetched
  from the official v2.1.4 release; never modified.

The Nextor kernel is distributed under the following terms (verbatim from the
Nextor repository `LICENSE.md`):

> MSX-DOS is (c) 2018 The MSX Licensing Corporation
> Nextor is (c) 2018 Nestor Soriano Vilchez
>
> Nextor is a fork of MSX-DOS and as such it makes extensive use of the MSX-DOS
> source code. The MSX Licensing Corporation authorizes this usage under the
> following terms:
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of
> this software and associated documentation files (the "Software"), to deal in
> the Software without restriction, including without limitation the rights to
> use, copy, modify, merge, publish and/or distribute the Software, and to permit
> persons to whom the Software is furnished to do so, subject to the following
> conditions:
>
> - The above copyright notice and this permission notice shall be included in
>   all copies or substantial portions of the Software.
>
> - Commercial usage of the Software is not allowed without explicit permission
>   from the copyright holders. "Commercial usage" means selling copies of the
>   Software, either in source code form or in binary form.
>
> - Producing and distributing hardware that includes the Software in ROM (or in
>   an equivalent built-in storage media) is allowed as long as no fee is charged
>   for the Software itself. That is, the selling price of the hardware must be
>   the same it would be if it didn't include the Software.
>
> - Derivative works are not allowed without explicit permission from the
>   copyright holders. "Derivative works" means independent projects that are
>   created as forks of the original source code for the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
> FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
> COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
> IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
> CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Note: this project is an **independent driver linked against the unmodified
Nextor kernel**, not a fork of the Nextor source, and it charges no fee for the
software. The Nextor license explicitly permits redistributing the compiled ROM
for free and building it into hardware at no software surcharge.

## mknexrom / Nestor80 — Nestor Soriano (Konamiman)

- mknexrom: https://github.com/Konamiman/Nextor (buildtools) — the ROM-assembly
  tool that stitches the kernel, our driver and the bank-switch mapper together.
  Built from source by `tools/fetch-nextor.sh`.
- Nestor80 (N80): https://github.com/Konamiman/Nestor80 — the Z80 assembler
  used to build `src/`. You download the release binary for your platform and
  drop it in `toolchain/` (see the README).

## MSX-USB — Mario Smit (S0urceror)

- Project: https://github.com/S0urceror/MSX-USB
- License: GNU General Public License v3 (the driver source files are marked
  "version 3").
- Used as: the CH376 USB-host and mass-storage driver code in this project's
  `src/ch376*.asm` / `src/usb_enum.asm` / `src/scsi.asm` is **derived from**
  MSX-USB. This is the reason Hi-MD Dream Drive is GPLv3.

## Rookie Drive NX — hardware

The Rookie Drive NX (and other CH376-based USB host cartridges wired to MSX I/O
ports 0x20/0x21) is **compatible hardware**, not a code dependency: none of this
project's code is derived from any Rookie Drive firmware. It is mentioned only so
you know what to plug in.
