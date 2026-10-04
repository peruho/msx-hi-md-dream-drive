# Makefile - Hi-MD Dream Drive
#
# Builds the cartridge firmware with Nestor80 (N80) and Konamiman's mknexrom:
#
#   make own    -> build/DDFIRMWA.ROM   (192K: our bootloader + recovery in
#                                        physical bank 0, banks 1-3 free,
#                                        Nextor + Hi-MD driver in banks 4-11).
#                                        This is the file you flash.
#   make rom    -> build/NEXTOR-HIMD.ROM (128K: plain Nextor + Hi-MD driver,
#                                        no bootloader/recovery; handy for
#                                        running the driver in an emulator)
#   make clean  -> remove the build outputs
#
# Toolchain (all overridable):
#   * N80       - Nestor80 assembler. Download from
#                 https://github.com/Konamiman/Nestor80/releases and either put
#                 the binary in toolchain/ or point N80 at it.
#   * MKNEXROM  - Konamiman's mknexrom, and KERNEL - the Nextor kernel base
#                 file. Both are produced by tools/fetch-nextor.sh.
#
# So the first-time flow is:  tools/fetch-nextor.sh  (kernel + mknexrom)
#                       then:  install Nestor80 into toolchain/  and  make own
#
# The absolute (abs) build type emits raw binaries directly, so no linker is
# needed.
#
# Reproducible builds: the only thing that changes from one day to the next
# is the build date in the boot banner (src/version.inc, written by make).
# Two builds of the same sources made on the same day are byte-identical.

N80        ?= ./toolchain/N80
MKNEXROM   ?= ./toolchain/mknexrom
KERNEL     ?= toolchain/kernels/Nextor-2.1.4.base.dat

SRCDIR   := src
BUILDDIR := build

# CH376 ports can be overridden, e.g.:
#   make own CH_DATA_PORT=22h CH_COMMAND_PORT=23h
DEFINES  :=
ifdef CH_DATA_PORT
DEFINES += --define-symbols CH_DATA_PORT=$(CH_DATA_PORT)
endif
ifdef CH_COMMAND_PORT
DEFINES += --define-symbols CH_COMMAND_PORT=$(CH_COMMAND_PORT)
endif

DRIVERSRC  := $(SRCDIR)/driver.asm
DRIVERBIN  := $(BUILDDIR)/driver.bin
CHGBNKSRC  := $(SRCDIR)/chgbnk_rd.asm
CHGBNKBIN  := $(BUILDDIR)/chgbnk_rd.bin
NEXTORROM  := $(BUILDDIR)/NEXTOR-HIMD.ROM
OWNROM     := $(BUILDDIR)/DDFIRMWA.ROM

.PHONY: own rom clean

own: $(OWNROM)

rom: $(NEXTORROM)

# --- Nextor driver ----------------------------------------------------------
# Driver binary: 256 dummy bytes + driver code, padded to exactly 16336
# bytes inside driver.asm itself (org 4000h, ds 3ED0h-... at the end).
$(DRIVERBIN): $(DRIVERSRC) $(SRCDIR)/iso9660.asm $(SRCDIR)/constants.asm \
              $(SRCDIR)/ch376.asm $(SRCDIR)/usb_enum.asm $(SRCDIR)/scsi.asm | $(BUILDDIR)
	$(N80) $(DRIVERSRC) $(DRIVERBIN) --build-type abs $(DEFINES)
	@python3 -c "import sys,os; n=os.path.getsize('$(DRIVERBIN)'); \
sys.exit('ERROR: driver.bin is %d bytes, expected 16336 (code too big?)' % n) if n != 16336 else print('driver.bin OK (16336 bytes)')"

# --- Bank-switching modules (48 bytes each, incl. the mknexrom header) -------
# chgbnk_rd.bin : Nextor in physical banks 0-7 (plain NEXTOR-HIMD.ROM)
# chgbnk_rd4.bin: Nextor in physical banks 4-11 (DDFIRMWA.ROM, +4 shift)
$(CHGBNKBIN): $(CHGBNKSRC) | $(BUILDDIR)
	$(N80) $(CHGBNKSRC) $(CHGBNKBIN) --build-type abs
	@python3 -c "import sys,os; n=os.path.getsize('$(CHGBNKBIN)'); \
sys.exit('ERROR: chgbnk is %d bytes, expected 48' % n) if n != 48 else None"

$(BUILDDIR)/chgbnk_rd4.bin: $(SRCDIR)/chgbnk_rd4.asm | $(BUILDDIR)
	$(N80) $(SRCDIR)/chgbnk_rd4.asm $@ --build-type abs

# --- Bootloader + in-ROM recovery (physical bank 0) -------------------------
# The build date goes into the boot banner through src/version.inc.
$(BUILDDIR)/bootrd0.bin: $(SRCDIR)/bootrd0.asm $(SRCDIR)/recovery.asm \
                         $(SRCDIR)/ch376.asm $(SRCDIR)/ch376_disk.asm \
                         $(SRCDIR)/constants.asm | $(BUILDDIR)
	@printf '    db "%s"\n' "$$(date +%Y%m%d)" > $(SRCDIR)/version.inc
	$(N80) $(SRCDIR)/bootrd0.asm $@ --build-type abs $(DEFINES) --define-symbols HAVE_RECOVERY
	@python3 -c "import sys,os; n=os.path.getsize('$@'); \
sys.exit('ERROR: bootrd0.bin is %d bytes, expected 16384' % n) if n != 16384 else print('bootrd0.bin OK (16384 bytes)')"

# --- DDFIRMWA.ROM: the cartridge firmware -----------------------------------
# Bootloader (+recovery) in bank 0, banks 1-3 free (FFh), Nextor + driver in
# banks 4-11. The only third-party bytes in it are the unmodified Nextor
# kernel's. The bootloader sets both 6000h and 7000h when it launches Nextor,
# so this ROM also boots in an emulator (romtype ascii16).
# The output already has the name our recovery looks for on the pendrive:
# DDFIRMWA.ROM. The FIRST time you flash it from the cartridge's factory
# recovery, rename the pendrive copy to RDFIRMWA.ROM (see the README).
$(OWNROM): $(BUILDDIR)/bootrd0.bin $(DRIVERBIN) $(BUILDDIR)/chgbnk_rd4.bin $(KERNEL)
	$(MKNEXROM) $(KERNEL) $(BUILDDIR)/nextor_shift4.rom /d:$(DRIVERBIN) /m:$(BUILDDIR)/chgbnk_rd4.bin
	@python3 -c "b=open('$(BUILDDIR)/bootrd0.bin','rb').read(); \
s=open('$(BUILDDIR)/nextor_shift4.rom','rb').read(); \
open('$(OWNROM)','wb').write(b + b'\xff'*49152 + s); \
print('Built $(OWNROM) (192K: bootloader+recovery, banks 1-3 free, Nextor)')"

# --- NEXTOR-HIMD.ROM: Nextor 2.1.4 kernel + Hi-MD driver --------------------
$(NEXTORROM): $(DRIVERBIN) $(CHGBNKBIN) $(KERNEL)
	$(MKNEXROM) $(KERNEL) $(NEXTORROM) /d:$(DRIVERBIN) /m:$(CHGBNKBIN)
	@echo "Built $(NEXTORROM)"
	@ls -l $(NEXTORROM)

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

clean:
	rm -f $(DRIVERBIN) $(CHGBNKBIN) $(NEXTORROM) $(OWNROM) \
	      $(BUILDDIR)/bootrd0.bin $(BUILDDIR)/chgbnk_rd4.bin \
	      $(BUILDDIR)/nextor_shift4.rom
