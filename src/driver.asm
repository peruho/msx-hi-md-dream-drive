;
; driver.asm - Nextor device-based driver for 2048-byte USB discs: the Sony
;               Hi-MD walkman and (read-only) USB CD/DVD drives
; MSX Hi-MD Drive project
;
; Copyright (c) 2026 MSX Hi-MD Drive project
; Parts derived from MSX-USB (S0urceror) and RookieDrive-FDD-ROM (Konamiman);
; see the GPLv3 headers in the included src/*.asm layers.
;
; This program is free software under the GNU General Public License v3.
;
; ==========================================================================
; ARCHITECTURE
;
;  * Device-based driver (DRV_TYPE=1), 1 device, 1 LUN.
;  * Transport: the hardware-validated manual stack (usb_enum.asm manual
;    enumeration + scsi.asm manual BOT). The CH376 auto-pilot is NOT used
;    for data (DISK_BOC_CMD cannot move >64-byte payloads on the Sony).
;  * Sector translation: Nextor sees 512-byte sectors; the Hi-MD has 2048.
;      physical = logical >> 2 ; offset = (logical & 3) << 9
;  * FASE 3 = READ/WRITE. Writes are WRITE-THROUGH: every DEV_RW write goes
;    to the device immediately (no dirty flag, no deferred flush). Partial
;    physical blocks use read-modify-write through BUF2K; whole aligned
;    blocks go straight from the caller's buffer (or staged through BUF2K
;    when the source sits in page 2). A write failure leaves the cache
;    invalid, never stale.
;
; MEMORY MODEL - THE KEY DECISION
;
;  The src/ layers use absolute addressing for their work RAM (they were
;  written for HIMDTEST, where WORKRAM is a constant). A Nextor page-3 work
;  area has a run-time-only address, so it cannot back those labels.
;  Instead, ALL driver state lives in a 16K RAM MAPPER SEGMENT reserved
;  with ALL_SEG (system segment) during DRV_INIT and mapped at page 2
;  (8000h-BFFFh) with PUT_P2 for the duration of every driver entry point:
;
;      8000h-87FFh  BUF2K   - one physical 2048-byte sector (read cache)
;      8800h-....   WORKRAM - all mutable state of the src/ layers + driver
;
;  The 8-byte SLTWRK entry that Nextor gives every driver (GWORK) holds only
;  what is needed BEFORE the segment is mapped:
;      (ix+0) flags: bit0=HAVE_SEG bit1=DEV_READY bit2=CHG_PENDING bit3=CAP_OK
;      (ix+1) segment number of our mapper segment
;      (ix+2) v3.3.4: last page-2 segment of a caller (MSX-DOS 1 probe guess)
;      (ix+3) v3.3.4: slot (FxxxSSPP) of the mapper our segment belongs to
;
;  While our segment is mapped, interrupts stay DISABLED (DI at ENTER_SEG,
;  EI at EXIT_SEG): an ISR could depend on the kernel's page-2 segment.
;  Nextor's own page-2 segment is saved with GET_P2 and restored on exit.
;
;  v3.3.4 - MSX-DOS 1 MODE (Nextor's disk emulation mode, the "1" key, a DOS 1
;  boot sector): the DOS 2 mapper support (F200h jump table, P2_SEG image,
;  ALL_SEG) does not exist there - F200h is MSX-DOS 1 work area. ENTER_SEG
;  asks MAPPER_MODE and, in DOS 1 mode, keeps the segment allocated earlier
;  in DOS 2 mode (the kernel always reads the emulation data file in DOS 2
;  mode first), switches page 2 with direct OUTs to port FEh, and FINDS the
;  caller's page-2 segment with a marker probe (see ENTER_SEG). The segment
;  is then unprotected (DOS 1 has no allocator): SEG_CANARY detects a program
;  that overwrote it and the state is rebuilt. COPY_OUT/COPY_IN never call
;  the jump table any more (CP_OSEG comes from ENTER_SEG, byte loops use
;  direct OUTs), so they are mode-independent.
;
;  Data is moved to/from Nextor's buffer (HL of DEV_RW etc., never in page 1)
;  by COPY_OUT/COPY_IN. Both split the range at 16K page boundaries and route
;  each chunk (semantics identical to the old per-byte page test):
;    * caller side in page 0/1/3: LDIR. Our segment only occupies page 2, so
;      the caller's page and our page-2 source/dest are BOTH visible at once.
;    * caller side in page 2 (the hot path, since BASIC/DOS buffers live at
;      8000h-BFFFh): the two segments share the page-2 window and cannot both
;      be mapped, so a STACK BOUNCE moves 8 bytes per batch - SP walks the
;      source (segment A mapped), four POPs fill the register file, page 2 is
;      flipped to segment B, four PUSHes lay the bytes down byte-identically,
;      page 2 is flipped back. Interrupts are already DI and page 3 is never
;      switched, so the flip is a direct `out (0FEh),a` (exactly what the
;      kernel's _PUT_P2 does: P2_REG=0FEh, no slot switching); P2_SEG's image
;      is never touched (it keeps saying "our segment") and the register is
;      set back to our segment after each bounce, so DOS2/Nextor accounting
;      is consistent on exit. Runs shorter than 8 bytes and the <8-byte tail
;      of a batch fall back to the old per-byte loop (_CO_/_CI_BYTELOOP; since
;      v3.3.4 two direct OUTs per byte instead of WR_SEG/RD_SEG).
;      Timing: the bounce is ~27 T-states/byte (220 T per 8-byte batch) versus
;      >150 T/byte for per-byte WR_SEG - a ~5x cut on the byte-moving cost.
;
; SONY RULES (all mandatory, learned in Fase 0 on real hardware):
;    * START STOP UNIT (Start=1) after EVERY bus reset, else eternal NAK.
;    * TEST UNIT READY loop after START (spin-up takes seconds).
;    * REQUEST SENSE after every failure (clears the device error state).
;    * Preventive ABORT_NAK on init (a stuck NAK-forever wait deafens the
;      chip to every command, even CHECK_EXIST).
;    * Mechanical budget during reads: CH_WAIT_MULT=8 (~10 s per token) and
;      NAK-retry-forever, restored to (1, limited) afterwards.
;    * Emulator infidelity: its BOT state survives the bus reset, so the
;      manual START UNIT may "fail" there. It is treated as NON-FATAL.
; ==========================================================================

    org 4000h

    ds 256              ; 256 dummy bytes expected by mknexrom before the sign

; --------------------------------------------------------------------------
; CH376 port and protocol constants (EQU only, emits no bytes)
; --------------------------------------------------------------------------
CHD_MOUNT_RETRIES:  equ 10  ; DISK_MOUNT budget (~2-4 s): enough for the
                            ; Hi-MD spin-up, short enough for discless boots
    include "constants.asm"

; --------------------------------------------------------------------------
; Kernel/BIOS entry points and fixed addresses
; --------------------------------------------------------------------------
GWORK:      equ 4045h   ; get SLTWRK entry pointer (via CALBNK)
CALBNK:     equ 4042h   ; call routine in another kernel bank
CHPUT:      equ 00A2h   ; BIOS: print char in A (usable in CALL context too:
                        ; BASIC keeps the BIOS in page 0). Needs no interrupts.
PROCNM:     equ 0FD89h  ; BASIC expanded-statement ("CALL") name buffer:
                        ; uppercase, null-terminated (page 3, always visible)
INITXT:     equ 006Ch   ; BIOS: SCREEN 0 with LINL40 columns (clears screen)
MSXVER:     equ 002Dh   ; BIOS ROM: machine generation (0=MSX1, 1=MSX2, ...)
LINL40:     equ 0F3AEh  ; system var: SCREEN 0 width
INTFLG:     equ 0FC9Bh  ; 3 = CTRL+STOP pressed (must be cleared, see guide)
EXPTBL:     equ 0FCC1h  ; expanded-slot flags (4 bytes, one per primary slot)
SLTTBL:     equ 0FCC5h  ; current subslot register value per primary slot

; Page-3 system variables + VDP I/O ports used by the RW_DIAG on-screen
; error line (DEV_RW cannot use the BIOS: page 0 is not the BIOS there)
SCRMOD:     equ 0FCAFh  ; current screen mode (0 = text)
NAMBAS:     equ 0F922h  ; name-table base of the current text screen
LINLEN:     equ 0F3B0h  ; text width: <=40 -> TEXT1 40-byte rows, else TEXT2 80
VDP_DATA:   equ 98h     ; VDP data port (VRAM read/write)
VDP_CTRL:   equ 99h     ; VDP control port (address/register setup)

; Nextor keeps a fixed copy of the DOS2 mapper support jump table at F200h
; (MAP_VECT in source/kernel/data.mac, verified for v2.1.4). Page 3 is never
; switched, so these can be called directly even with our segment in page 2.
JT_ALL_SEG: equ 0F200h+00h  ; A=0 user/1 system, B=0 primary -> Cy=1 no seg, A=seg
JT_RD_SEG:  equ 0F200h+06h  ; A=segment, HL=addr -> A=byte
JT_WR_SEG:  equ 0F200h+09h  ; A=segment, HL=addr, E=byte
JT_PUT_P2:  equ 0F200h+24h  ; A=segment -> mapped at 8000h-BFFFh
JT_GET_P2:  equ 0F200h+27h  ; -> A=segment currently in page 2
; v3.3.4: the jump table above only exists in DOS 2 mode AFTER DOSINIT. The
; kernel zeroes F1C9h-F37Fh at the start of its init (INIWRK), and in MSX-DOS 1
; mode (disk emulation mode, "1" key, DOS 1 boot sector) F200h becomes MSX-DOS
; 1 work area ("AUX CON..." names, days-per-month table): calling F224h/F227h
; there executes data. MAPPER_MODE tells the three cases apart.
MAIN_BANK:  equ 0F319h      ; Nextor 2.1.4 kernel var (data.mac, in the 16 bytes
                            ; DOS 1 leaves free): 0 = DOS 2 mode, 3 = MSX-DOS 1
                            ; mode (set by OLDDOS, bank0/init.mac)
MAPPER_PORT_P2: equ 0FEh    ; mapper register of page 2 (write-only for us)
TPA_P0:     equ 0F2CBh      ; Nextor 2.1.4 kernel vars P0_TPA, P1_TPA, P2_TPA
TPA_P2:     equ 0F2CDh      ;  (data.mac): the segments the kernel treats as
                            ;  "the user's" pages 0-2 (see _ES_ALLOC)

; v3.3.6: the CH376 INT wait (src/ch376.asm) calls WAIT_TICK every ~0.13 s
; of waiting, and src/ch376_disk.asm gives up on WAKE_ABORT (ESC / time cap).
CH_WAIT_HOOKED: equ 1

; v3.3.6: time caps of a bring-up session (HW_INIT_PATIENT), in WAIT_TICK
; ticks of ~0.13 s (one 8192-poll slice of the CH376 INT wait at 3.58 MHz,
; or one ~0.125 s step of a pause). They bound the whole session - attempts,
; waits, pauses - whatever the unit does; time spent in commands that answer
; at once is not counted (it is small). When the budget runs out the session
; ends exactly like on ESC.
CAP_BOOT:   equ 1350    ; ~3 min: the walkman's own boot at power-on can cost
                        ;  a minute and more of our waits (v2.2 .. v3.3.1 logs)
CAP_HOT:    equ 680     ; ~90 s: hot plug, and any other bring-up (one attempt)

; SLTWRK flag bits ((ix+0) after MY_GWORK)
F_HAVESEG:  equ 0       ; mapper segment reserved
F_READY:    equ 1       ; USB device enumerated and started
F_CHANGED:  equ 2       ; media change pending, not yet reported to Nextor
F_CAPOK:    equ 3       ; TOTAL_SEC/MB16 hold a valid READ CAPACITY result
F_BOOTWAIT: equ 4       ; first bring-up after DRV_INIT: wait for the walkman
                        ; to finish ITS OWN boot (VBUS arrives with MSX power)
F_HOTWAIT:  equ 5       ; the unit vanished (unplugged/swapped): the next
                        ; bring-up of whatever gets plugged in is patient too

; Nextor device-based error codes (DEV_RW output in A)
NX_ENCOMP:  equ 0FFh
NX_EWRERR:  equ 0FEh
NX_EDISK:   equ 0FDh
NX_ENRDY:   equ 0FCh
NX_EDATA:   equ 0FAh
NX_ERNF:    equ 0F9h
NX_EWPROT:  equ 0F8h
NX_EIDEVL:  equ 0B5h

; --------------------------------------------------------------------------
; Layout of our mapper segment while mapped in page 2.
; BUF2K holds one physical sector (the read cache). WORKRAM backs every
; work-RAM label required by src/ch376.asm, src/usb_enum.asm and src/scsi.asm
; (same contract as himdtest_workram.asm) plus the driver's own state.
; --------------------------------------------------------------------------
BUF2K:      equ 8000h   ; 2048 bytes: cached physical sector
WORKRAM:    equ 8800h

USB_DEV_ADDR:       equ WORKRAM+0
USB_EP0_SIZE:       equ WORKRAM+1
USB_BULK_IN_EP:     equ WORKRAM+2
USB_BULK_OUT_EP:    equ WORKRAM+3
USB_BULK_MAXPKT:    equ WORKRAM+4
USB_BULK_IN_TOG:    equ WORKRAM+5
USB_BULK_OUT_TOG:   equ WORKRAM+6
USB_CONFIG_VALUE:   equ WORKRAM+7
USB_IFACE_NUM:      equ WORKRAM+8
USB_VID:            equ WORKRAM+9    ; 2 bytes
USB_PID:            equ WORKRAM+11   ; 2 bytes
SCSI_TAG:           equ WORKRAM+13
SCSI_CBW:           equ WORKRAM+14   ; 31 bytes
SCSI_CSW:           equ WORKRAM+45   ; 13 bytes
_SCSI_SENT_TAG:     equ WORKRAM+58
_SCSI_DATA_BUF:     equ WORKRAM+59   ; 2 bytes
_SCSI_DATA_LEN:     equ WORKRAM+61   ; 2 bytes
_SCSI_DIR:          equ WORKRAM+63
_CDB_RW:            equ WORKRAM+64   ; 10 bytes
_MS_IN_WANTED_IFACE: equ WORKRAM+74
ENUM_STEP:          equ WORKRAM+75
LAST_CH_STATUS:     equ WORKRAM+76
CTL_STAGE:          equ WORKRAM+77
CH_WAIT_MULT:       equ WORKRAM+78
USB_SETUP_BUF:      equ WORKRAM+79   ; 8 bytes
INQ_BUF:            equ WORKRAM+87   ; 36 bytes (kept: feeds DEV_INFO strings)
SENSE_BUF:          equ WORKRAM+123  ; 18 bytes
CAP_BUF:            equ WORKRAM+141  ; 8 bytes
USB_DESC_BUF:       equ WORKRAM+149  ; 256 bytes descriptor scratch

; Driver-private state
NEXTOR_SEG:         equ WORKRAM+405  ; kernel's page-2 segment (to restore)
SECNUM:             equ WORKRAM+406  ; 4 bytes LE: current logical sector
RWDEST_CUR:         equ WORKRAM+410  ; 2 bytes: current destination pointer
COUNT:              equ WORKRAM+412  ; logical sectors still to transfer
DONE:               equ WORKRAM+413  ; logical sectors transferred OK
PHYS_LBA_BE:        equ WORKRAM+414  ; 4 bytes BE: physical LBA for the CDB
CACHED_PHYS:        equ WORKRAM+418  ; 4 bytes BE: LBA held in BUF2K
CACHE_OK:           equ WORKRAM+422  ; 1 = BUF2K valid
TOTAL_SEC:          equ WORKRAM+423  ; 4 bytes LE: logical sectors (phys*4)
MB16:               equ WORKRAM+427  ; 2 bytes: capacity in MB (for boot msg)
RW_NBLK:            equ WORKRAM+429  ; physical blocks for READ_PHYS_RETRY
RW_DEST:            equ WORKRAM+430  ; 2 bytes: buffer for READ_PHYS_RETRY
RETRY:              equ WORKRAM+432
RECOVERED:          equ WORKRAM+433  ; re-enumeration already tried this cmd
INFO_TMP:           equ WORKRAM+434  ; 64 bytes: LUN_INFO/DEV_INFO staging

; Work RAM of the CH376 auto-pilot layer (src/ch376_disk.asm), used only
; during the warm-up phase of HW_FULL_INIT (DISK_CONNECT + DISK_MOUNT)
CHD_CBW:            equ WORKRAM+498  ; 31 bytes
CHD_DATA_PTR:       equ WORKRAM+529  ; 2 bytes
CHD_DATA_LEN:       equ WORKRAM+531  ; 2 bytes
CHD_DATA_DIR:       equ WORKRAM+533  ; 1 byte
CHD_MOUNT_NAME:     equ WORKRAM+534  ; 36 bytes: DISK_MOUNT reply
CHD_WAIT_ROUNDS:    equ WORKRAM+570  ; 1 byte
CHD_PROBE:          equ WORKRAM+571  ; 1 byte
BOCINQ:             equ WORKRAM+572  ; 1 = INQ_BUF filled by the BOC phase
BOCCAP:             equ WORKRAM+573  ; 1 = capacity obtained by the BOC phase
INIT_FAIL:          equ WORKRAM+574  ; HW_FULL_INIT failure code (1..7) when a
                                     ; DEV_RW error came from device bring-up;
                                     ; 0 = error came from a SCSI command
RW_ISWRITE:         equ WORKRAM+575  ; current DEV_RW op: 0=read 1=write
XFER_OP:            equ WORKRAM+576  ; XFER_PHYS_RETRY op: 0=READ10 1=WRITE10
                                     ; (separate from RW_ISWRITE: a WRITE's
                                     ;  read-modify-write pre-read is a READ)
WAKE_TRIES:         equ WORKRAM+577  ; HW_INIT_PATIENT retries left
WAKE_ACTIVE:        equ WORKRAM+578  ; 1 = boot wake-up window in progress
WAKE_FAST:          equ WORKRAM+579  ; 1 = window retry: shortened budgets
WAKE_ABORT:         equ WORKRAM+580  ; 1 = ESC seen inside a wait loop
WAKE_SPIN:          equ WORKRAM+581  ; spinner phase 0-3 (| / - \)
WAKE_CODE:          equ WORKRAM+582  ; last failed-attempt code (0 = none)
WAKE_HOT:           equ WORKRAM+583  ; 1 = hot-plug window (not the boot one)
CHG_SEEN:           equ WORKRAM+584  ; v3.3.2: 1 = NOTE_CHANGE ran since the last
                                     ; clear (sticky). A caller that must not go
                                     ; on with the old medium clears it, waits
                                     ; (TUR_WAIT / HW_FULL_INIT), then checks it
CHG_GUARD:          equ WORKRAM+585  ; v3.3.2: 1 = the medium changed (NOTE_CHANGE,
                                     ; _CF_OTHER) and DEV_STATUS has not reported
                                     ; it yet: DEV_RW refuses the medium (every
                                     ; request is meant for the OLD disc). Only
                                     ; DEV_STATUS answering 2 clears it
                                     ; (HW_FULL_INIT preserves it)
; v3.3.5 - "verify the identity before trusting the medium" (see VERIFY_ID).
; Hardware 2026-09-25: a CD/DVD drive failing to load a scratched disc never
; sends 06/28/00 - it goes 02/04/01 -> 03/10/00 -> "ready" - and v3.3.4 then
; answered "unchanged": the OLD disc's listing was shown for the new one.
VFY_PEND:           equ WORKRAM+586  ; 1 = the unit went through a not-ready
                                     ; phase (TUR/START failed, spin-up wait,
                                     ; re-init) since the medium was last known:
                                     ; nothing may be answered "unchanged" nor
                                     ; served until VERIFY_ID says "same disc".
                                     ; Cleared by VERIFY_ID (same/other disc),
                                     ; NOTE_CHANGE and a change report (2)
MID_OK:             equ WORKRAM+587  ; 1 = MID_* = identity of the disc last
                                     ; probed (ISO_PROBE): the one whose data
                                     ; Nextor may hold. 0 = none since the last
                                     ; change report (nothing to protect)
MID_ISO:            equ WORKRAM+588  ; 1 = it was ISO9660-mounted: ISO_ID (8E01h,
                                     ; v3.3.3) completes its identity
MID_TOT:            equ WORKRAM+589  ; 4: its TOTAL_SEC (capacity)
MID_SIG:            equ WORKRAM+593  ; 4: signature of its logical sector 0 (the
                                     ; first 512 bytes of block 0). MUST follow
                                     ; MID_TOT (one LDIR chain in ISO_PROBE)
VFY_SIG:            equ WORKRAM+597  ; 4: signature being computed (SIG0)
VFY_BUF:            equ WORKRAM+601  ; 2: VERIFY_ID's 2048-byte read buffer
MID_CUR:            equ WORKRAM+603  ; 1 = the current mount (ISO_STATE != 0)
                                     ; comes from a probe that took MID_*: a
                                     ; change report keeps it; 0 = probed while
                                     ; a verification was pending (CALL DREAM):
                                     ; the report forces a re-probe
; v3.3.6 - "a drive that talks but cannot use its disc is no reason to wait".
; Hardware 2026-09-26 (UJ8B0 DVD drive, a badly scratched CD put in with the
; drive's button): every command answered, slowly, 04/09/02 (HARDWARE ERROR,
; focus servo failure); the driver kept waiting for it, declared the
; transport dead once and then sat 15+ minutes in the hot-plug window (8
; attempts of ~5 min) with ESC ignored.
DISC_BAD:           equ WORKRAM+604  ; 1 = a CD/DVD drive answered MEDIUM ERROR
                                     ; (03) or HARDWARE ERROR (04) while we
                                     ; waited for it (CHK_UNUSABLE): it cannot
                                     ; use the disc it holds. Cleared by every
                                     ; bring-up and by a TEST UNIT READY that
                                     ; succeeds
WAKE_LEFT:          equ WORKRAM+605  ; 2: ticks left in the bring-up session
                                     ; (WAIT_TICK; armed by HW_INIT_PATIENT)
WAKE_SHOWN:         equ WORKRAM+607  ; 1 = the session drew its wait line
; v3.3.7: Nextor's "dirty disk" flag (byte 25h of logical sector 0, the
; undelete flag of MSX-DOS 2) on a Sony-formatted disc. Nextor rewrites the
; boot sector to set it before a delete frees clusters (and to clear it again
; before the next allocation); the disc's real boot block is never written
; (walkman/Mac compatibility), so the flag lives here and SERVE_SECTOR0 hands
; it back: Nextor re-reads what it wrote. Forgotten at every disc change.
DIRTY0_ON:          equ WORKRAM+608  ; 1 = DIRTY0_VAL replaces byte 25h
DIRTY0_VAL:         equ WORKRAM+609  ; the flag as Nextor last wrote it
; v3.4.1: a CD/DVD drive answering a POSITIONING error to a READ(10) ("no
; seek complete" 03/02/00 and kin: the mechanics not settled yet - hardware
; 2026-10-04, UJ8B0 drive just powered, the first long FAT read) gets spaced
; retries instead of one (_CF_SEEK). Both are set by READ_PHYS_RETRY.
SEEK_LEFT:          equ WORKRAM+610  ; positioning retries still allowed
SEEK_TK:            equ WORKRAM+611  ; 2: WAIT_TICK slices since the request
                                     ;  began (~0.12 s each: a clock that works
                                     ;  with interrupts disabled)
                                     ; (WORKRAM+613..639 free)
TRANS_BUF:          equ WORKRAM+640  ; 512 bytes: caller's view of logical
                                     ; sector 0 (BPB translated when the
                                     ; medium is Sony-formatted, Fase 4)

; Scratch for the fast COPY_OUT/COPY_IN engine (Fase 7 speed). All of these
; are read/written only while OUR segment is mapped in page 2, so they can
; live in WORKRAM like the rest of the driver state. TRANS_BUF ends at
; WORKRAM+1152, so this block starts there.
CP_OSEG:            equ WORKRAM+1152 ; our mapper segment (set by ENTER_SEG)
CP_KSEG:            equ WORKRAM+1153 ; kernel page-2 segment (= NEXTOR_SEG copy)
SEG_DOS1:           equ WORKRAM+1154 ; v3.3.4: 1 = this call runs in MSX-DOS 1
                                     ; mode: no mapper jump table, page 2 is
                                     ; switched with direct OUTs (EXIT_SEG)
                                     ; WORKRAM+1155 free (real SP rides IY)
CP_RUN:             equ WORKRAM+1156 ; 2 bytes: bytes handled this chunk
CP_FAST:            equ WORKRAM+1158 ; 2 bytes: bytes handled by the stack bounce
CP_SRC:             equ WORKRAM+1160 ; 2 bytes: source cursor saved across a bounce
CP_DST:             equ WORKRAM+1162 ; 2 bytes: dest cursor saved across a bounce
CP_CNT:             equ WORKRAM+1164 ; 2 bytes: remaining count saved across a bounce

; Fase 6 (CALL HIMD) state. Only touched while our segment is mapped.
FMT_ACTIVE:         equ WORKRAM+1166 ; 1 = FORMAT in progress: bypass the Sony
                                     ; block-0 write protection for this session
FMT_FATSZ:          equ WORKRAM+1167 ; sectors per FAT (low byte; <=31 on Hi-MD)
FMT_F1:             equ WORKRAM+1168 ; physical LBA of FAT #2 = 1 + FATsz
FMT_ROOT:           equ WORKRAM+1169 ; physical LBA of the root dir = 1 + 2*FATsz
FMT_LAST:           equ WORKRAM+1170 ; one past the last physical sector to write
FMT_LBA:            equ WORKRAM+1171 ; current physical LBA in the write loop
FMT_TOT:            equ WORKRAM+1172 ; 4 bytes: total32 (physical block count) for
                                     ; the BPB = TOTAL_SEC >> 2
INFO_WHY:           equ WORKRAM+1176 ; CALL DREAM: bring-up code of its refresh
                                     ; (7 = unusable sector size)
IDSNAP:             equ WORKRAM+1184 ; 32 bytes: INQUIRY vendor/product/rev +
                                     ; TOTAL_SEC before a mid-command re-init

; CALL DREAM LOG (v3.3.1): sense/event log in the free WORKRAM tail between
; IDSNAP and the ISO state: LOG_N = 8CC0h, LOG_RING = 8CC1h-8CFCh (60 bytes),
; then SEG_CANARY (8CFDh-8CFEh, v3.3.4), 8CFFh still free. Cleared when the
; segment is allocated (ENTER_SEG) and by CALL DREAM LOG itself. See LOG_ADD
; for the entry layout.
LOG_N:              equ WORKRAM+1216 ; entries in use, 0..LOG_MAX (oldest first)
LOG_RING:           equ WORKRAM+1217 ; LOG_MAX entries x LOG_ESZ bytes
LOG_MAX:            equ 12
LOG_ESZ:            equ 5            ; tag, key/event, ASC/aux, ASCQ, count
LEV_START:          equ 1            ; event codes (tag bit 7 set)
LEV_INIT:           equ 2
LEV_NOSENSE:        equ 3
LEV_HALT:           equ 4            ; v3.3.3: "B HALT ok/fail" - a bulk pipe
                                     ;  STALLed (bad sector) and was cleared
LEV_ISONEW:         equ 5            ; v3.3.3: "M ISO new" - ISO mounted afresh
LEV_ISOKEEP:        equ 6            ; v3.3.3: "M ISO kept" - the SAME disc came
                                     ;  back: its cluster tables were kept
LEV_VSAME:          equ 7            ; v3.3.5: "V same" - VERIFY_ID: same disc
LEV_VDIFF:          equ 8            ; v3.3.5: "V DIFF" - another disc (change)
LEV_VFAIL:          equ 9            ; v3.3.5: "V fail" - identity unreadable
LEV_ESC:            equ 10           ; v3.3.6: "R ESC" - ESC ended a bring-up
LEV_TIMEUP:         equ 11           ; v3.3.6: "R time up" - its time cap did
LEV_BADDISC:        equ 12           ; v3.3.6: "D unusable" - the CD/DVD drive
                                     ;  cannot use its disc (03/04): no waiting
LEV_SEEK:           equ 13           ; v3.4.1: "P seek ok/fail" - a READ that
                                     ;  met positioning errors (03/02...) was
                                     ;  retried: it read in the end / gave up

; v3.3.4: two known bytes written when the segment is allocated. In MSX-DOS 1
; mode nothing reserves our segment any more (DOS 1 has no allocator): a
; program that uses the mapper on its own may overwrite it. ENTER_SEG checks
; the canary there and, if it is gone, rebuilds the driver state (cache, ISO
; tables, USB bring-up) instead of running on garbage (a zeroed WORKRAM made
; v3.3.3 loop forever in the CH376 layer).
SEG_CANARY:         equ LOG_RING+LOG_MAX*LOG_ESZ ; 8CFDh, 2 bytes
SEG_CANARY_VAL:     equ 4D44h        ; "DM"

; ISO9660 native mount (v3.3, src/iso9660.asm). WORKRAM ends at 8CFFh (the
; log and canary above); the ISO state starts at 8D00h, the DIRBLK table fills
; 9000h-BFFCh.
ISO_BASE:   equ 8D00h
    if SEG_CANARY+2 gt ISO_BASE
    .error "CALL DREAM LOG ring / SEG_CANARY overlap the ISO state"
    endif
ISO_STATE:  equ ISO_BASE+0      ; 0 = not probed, 1 = not ISO, 2 = ISO mounted
ISO_SPC:    equ ISO_BASE+1      ; sectors per cluster (4..128)
ISO_SPCSH:  equ ISO_BASE+2      ; log2(SPC)
ISO_N:      equ ISO_BASE+3      ; 2: clusters (4096..65524)
ISO_MAXV:   equ ISO_BASE+5      ; 2: last valid cluster = N+1
ISO_F:      equ ISO_BASE+7      ; 2: sectors per FAT
ISO_RB:     equ ISO_BASE+9      ; root blocks served (1..63)
ISO_ROOTS:  equ ISO_BASE+10     ; 2: first root sector = 4 + F
ISO_DS:     equ ISO_BASE+12     ; 2: first data sector = ROOTS + 4*RB
ISO_TOTAL:  equ ISO_BASE+14     ; 4: logical sectors of the virtual volume
ISO_ROOT:   equ ISO_BASE+18     ; 4: first block of the root directory
ISO_SERIAL: equ ISO_BASE+22     ; 4: volume serial (PVD hash)
ISO_LABEL:  equ ISO_BASE+26     ; 11: volume label
ISO_BOOT:   equ ISO_BASE+37     ; 1 = NEXTOR.SYS/MSXDOS2.SYS in the root
ISO_VNEXT:  equ ISO_BASE+38     ; 2: next free virtual cluster
ISO_NROWS:  equ ISO_BASE+40     ; 2: DIRBLK rows in use
ISO_LOST:   equ ISO_BASE+42     ; bit0 table full, bit1 space exhausted,
                                ;  bit2 file too big: entries were hidden
ISO_LCLBA:  equ ISO_BASE+43     ; 3: last lba looked up in DIRBLK...
ISO_LCROW:  equ ISO_BASE+46     ; 2: ...and its row (0 = nothing cached)
ISO_RCNEXT: equ ISO_BASE+48     ; resolution cache: next slot (round robin)
W_FLAGS:    equ ISO_BASE+49     ; walk: bit0 no row, bit1 classify only
W_POS:      equ ISO_BASE+50     ; 2: walk cursor in BUF2K
W_I:        equ ISO_BASE+52     ; walk: next record index
W_CURSOR:   equ ISO_BASE+53     ; 2: walk: next virtual cluster
W_PREV:     equ ISO_BASE+55     ; 2: previous record (multi-extent check)
W_REC:      equ ISO_BASE+57     ; 2: current record
W_KIND:     equ ISO_BASE+59     ; K_* of the current record
W_RI:       equ ISO_BASE+60     ; index of the current record
W_VSTART:   equ ISO_BASE+61     ; 2: its first cluster (0 = none)
W_VLEN:     equ ISO_BASE+63     ; 2: its clusters
S_LBA:      equ ISO_BASE+65     ; 4: block to fetch / synthesize (LE)
S_K:        equ ISO_BASE+69     ; 2: block index inside its directory
S_O:        equ ISO_BASE+71     ; 2: cluster of the directory (0 = root)
S_P:        equ ISO_BASE+73     ; 2: cluster of its parent
S_ROOT:     equ ISO_BASE+75     ; 1 = synthesizing the root
S_Q:        equ ISO_BASE+76     ; quarter (0..3) of the block wanted
S_VBASE:    equ ISO_BASE+77     ; 2: vbase of the block being synthesized
S_FIRST:    equ ISO_BASE+79     ; first record index of the quarter
S_OUT:      equ ISO_BASE+80     ; 2: output cursor in TRANS_BUF
S_CNT:      equ ISO_BASE+82     ; entry slots left in the quarter
S_SZ:       equ ISO_BASE+83     ; 1 = entry carries the record's size
R_V:        equ ISO_BASE+84     ; 2: cluster being resolved
R_S:        equ ISO_BASE+86     ; sector inside that cluster
R_ENT:      equ ISO_BASE+87     ; 2: (spare)
R_ROW:      equ ISO_BASE+89     ; 2: DIRBLK row of the parent block
T_A:        equ ISO_BASE+91     ; 4: 32-bit scratch
T_B:        equ ISO_BASE+95     ; 4: 32-bit scratch
N_PTR:      equ ISO_BASE+99     ; 2: name83: identifier start
N_LEN:      equ ISO_BASE+101    ; name83: identifier length after cuts
N_LB:       equ ISO_BASE+102    ; name83: base length
N_LE:       equ ISO_BASE+103    ; name83: extension length
N_SUB:      equ ISO_BASE+104    ; name83: 1 = a character was substituted
N_NAME:     equ ISO_BASE+105    ; 11: the 8.3 name built
N_DIG:      equ ISO_BASE+116    ; 5: name83: decimal digits of n
W_RESUME:   equ ISO_BASE+121    ; 1 = the walk state W_* stopped right before
W_RQ:       equ ISO_BASE+122    ;  quarter W_RQ of block W_RLBA (4, LE):
W_RLBA:     equ ISO_BASE+123    ;  ISO_SYNTH continues it (sequential reads)
ISO_RCACHE: equ ISO_BASE+128    ; 8 x 16: resolved children (round robin)
; v3.3.3: who the allocation tables belong to. ISO_STATE=0
; only means "probe the medium again"; the tables (DIRBLK, VNEXT, NROWS,
; LOST, BOOT) are kept while ISO_TVALID=1 and are reused when the probe finds
; the SAME disc (identical ISO_ID) - so cluster numbers Nextor already holds
; (open files, buffered directory sectors) keep their meaning across any
; re-probe: a re-init after errors, a transport death, CALL DREAM EJECT, a
; tray reload of the same disc. Only a different ISO disc resets them.
ISO_TVALID: equ ISO_BASE+256    ; 8E00h: 1 = the tables belong to ISO_ID
ISO_ID:     equ ISO_BASE+257    ; 16: serial(4) volume size(4) root(4) PVD hash(4)
ISO_NID:    equ ISO_BASE+273    ; 16: identity of the disc being probed
ISO_IDLEN:  equ 16
DIRBLK:     equ 9000h           ; 1755 rows x 7 bytes: lba(3) vbase(2) owner(2)
    if ISO_NID+ISO_IDLEN gt DIRBLK
    .error "ISO identity state overlaps DIRBLK"
    endif
; Test hooks (make rom-cap): DIRBLK_CAP / ISO_NMAX can be lowered at build
; time (--define-symbols) to exercise "table full" and "space exhausted"
; against the model's --dirblk-cap / --n. The normal build uses the design values.
    ifndef DIRBLK_CAP
DIRBLK_CAP: equ 1755
    endif
    ifndef ISO_NMAX
ISO_NMAX:   equ 65524           ; max clusters (N_MAX of the model)
    endif

; ==========================================================================
; Driver header (must sit exactly at 4100h)
; ==========================================================================
DRV_START:

    db "NEXTOR_DRIVER",0         ; 4100h DRV_SIGN
    db 1                         ; 410Eh DRV_FLAGS: device-based, no DRV_CONFIG
    db 0                         ; 410Fh reserved

DRV_NAME:
    db "Hi-MD Dream Drive MD/CD/DVD"
    ds 32-($-DRV_NAME)," "       ; 4110h, padded to 32 chars

    ; 4130h: common jump table
    jp DRV_TIMI
    jp DRV_VERSION
    jp DRV_INIT
    jp DRV_BASSTAT
    jp DRV_BASDEV
    jp DRV_EXTBIO
    jp DRV_DIRECT0
    jp DRV_DIRECT1
    jp DRV_DIRECT2
    jp DRV_DIRECT3
    jp DRV_DIRECT4
    jp DRV_CONFIG

    ds 12                        ; 4154h-415Fh reserved

    ; 4160h: device-based entries
    jp DEV_RW                    ; 4160h
    jp DEV_INFO                  ; 4163h
    jp DEV_STATUS                ; 4166h
    jp LUN_INFO                  ; 4169h

; ==========================================================================
; Trivial common routines
; ==========================================================================
DRV_TIMI:                        ; not hooked (DRV_INIT returns Cy=0)
    ret

DRV_VERSION:
    ld a,3
    ld b,4
    ld c,1                       ; v3.4.1: spaced retries for a CD/DVD drive's
                                 ;  positioning errors (03/02/00, cold drive);
                                 ;  v3.4: release build (= v3.3.7 + diagnostic
                                 ;  lines blank row 23 before printing);
                                 ;  v3.3.7: an empty USB bus is seen as such
                                 ;  (TEST_CONNECT 16h, code 3); v3.3.6: a
                                 ;  drive that cannot use its disc is no
                                 ;  reason to wait, capped bring-ups, ESC
    ret

; DRV_BASSTAT - BASIC expanded-statement ("CALL") handler. BASIC copies the
; WHOLE uppercase statement text after CALL (name AND any keyword) into PROCNM,
; null-terminated - verified on the emulator: "CALL HIMD FORMAT" leaves PROCNM =
; 48 49 4D 44 20 46 4F 52 4D 41 54 00 ("HIMD FORMAT"). So we parse PROCNM, not
; the program text pointer; HL is handed straight back (BASIC already advanced
; it past the whole statement). We own two names, "DREAM" (the generic one,
; fits MD/CD/DVD alike) and "HIMD" (the original, kept as an alias for good):
; unique on purpose - a bare FORMAT/EJECT is swallowed by the Sanyo disk ROM
; before Nextor sees it. Cy=1 passes the statement on (an unclaimed CALL surfaces as a BASIC
; "Syntax error"); Cy=0 = handled. Runs in CALL context: the EI/DI state at
; entry is NOT guaranteed (kernel source does EI before CALBNK, but CHGET was
; observed dead here - treat as unknown; use KEY_YN under DI, never CHGET).
; BIOS is in page 0 (CHPUT works). Our segment NOT mapped - each DO_* maps
; its own, and every handled exit returns with EI (EXIT_SEG or explicit).
DRV_BASDEV:
    scf
    ret
DRV_BASSTAT:
    push hl                      ; preserve the BASIC text pointer (returned as-is)
    ld hl,PROCNM
    ld de,S_DREAMNAME
    call PREFIXMATCH             ; Cy=0 if PROCNM starts with "DREAM"; HL -> rest
    jr nc,_BS_NAME
    ld hl,PROCNM                 ; (a mismatch leaves HL partly advanced)
    ld de,S_HIMDNAME
    call PREFIXMATCH             ; or with "HIMD"
    jr c,_BS_PASS
_BS_NAME:
    ld a,(hl)                    ; the char after the name must be a word boundary
    or a
    jr z,_BS_INFO               ; exactly "DREAM"/"HIMD" -> info screen
    cp ' '
    jr nz,_BS_PASS             ; "HIMDxxx": a different name, not ours
    call SKIPSPC
    or a
    jr z,_BS_INFO               ; name + trailing spaces only -> info screen
    ld de,S_EJECT
    call WORDMATCH
    jr nc,_BS_EJECT
    ld de,S_FORMAT
    call WORDMATCH
    jr nc,_BS_FORMAT
    ld de,S_LOG
    call WORDMATCH
    jr nc,_BS_LOG
_BS_PASS:
    pop hl
    scf                          ; not handled -> BASIC "Syntax error"
    ret
_BS_LOG:
    call DO_LOG
    pop hl
    or a
    ret
_BS_INFO:
    call DO_INFO
    pop hl
    or a
    ret
_BS_EJECT:
    call DO_EJECT
    pop hl
    or a
    ret
_BS_FORMAT:
    call DO_FORMAT
    pop hl
    or a
    ret

DRV_EXTBIO:
DRV_DIRECT0:
DRV_DIRECT1:
DRV_DIRECT2:
DRV_DIRECT3:
DRV_DIRECT4:
    ret

DRV_CONFIG:
    ld a,1                       ; not implemented (DRV_FLAGS bit2 = 0)
    ret

; ==========================================================================
; GET_P2_SLOT - slot address (FxxxSSPP format) of the slot currently
; selected in Z80 page 2 (8000h-BFFFh). Uses the BIOS mirrors, so it works
; with interrupts disabled and from any slot.
; Output: A = slot address. Corrupts BC, HL, F.
; ==========================================================================
GET_P2_SLOT:
    in a,(0A8h)                  ; primary slot register
    rrca
    rrca
    rrca
    rrca
    and 03h                      ; A = primary slot of page 2
    ld c,a
    ld b,0
    ld hl,EXPTBL
    add hl,bc
    bit 7,(hl)
    ret z                        ; not expanded: A = 000000PP
    ld hl,SLTTBL                 ; expanded: fetch the subslot register
    add hl,bc                    ;  mirror kept by the BIOS
    ld a,(hl)
    rrca
    rrca
    rrca
    rrca
    and 03h                      ; A = subslot of page 2
    rlca
    rlca                         ; to bits 3-2
    or c                         ; add primary slot bits
    or 80h                       ; expanded-slot flag
    ret

; ==========================================================================
; MY_GWORK - IX -> our 8-byte SLTWRK entry (page 3, always visible).
; Same canonical sequence as SunriseIDE. Corrupts AF, AF', IX.
; ==========================================================================
MY_GWORK:
    xor a
    ex af,af'
    xor a
    ld ix,GWORK
    call CALBNK
    ret

; ==========================================================================
; ENTER_SEG - map our segment in page 2 (interrupts off), saving Nextor's.
;
; The segment is allocated LAZILY on the first call: DRV_INIT runs BEFORE
; DOSINIT/MAP_INIT in the Nextor 2.1 boot sequence (verified in
; bank0/init.mac), so neither ALL_SEG nor the F200h jump table exist yet at
; driver-init time. The first DEV_* call (drive automapping) happens after
; DOSINIT, when the mapper support is guaranteed ready.
;
; ALL_SEG is asked for a segment of the mapper in the CURRENT page-2 slot
; (= Nextor's primary mapper): with B=0 it would allocate from the mapper
; in the page-3 slot, whose segment numbers are meaningless for PUT_P2 and
; end up mapping live TPA memory (both failure modes seen in openMSX).
;
; v3.3.4 - MSX-DOS 1 MODE (disk emulation mode: EMUFILE; the "1" key; a DOS 1
; boot sector). The kernel reads the emulation data file in DOS 2 mode (from
; DOSINIT/AUTODRV: our segment gets allocated there as usual), then switches
; to MSX-DOS 1 (OLDDOS) and reads the disk image through DEV_RW. From then on
; F200h is MSX-DOS 1 work area, not a jump table: v3.3.3 called F227h/F224h
; anyway, executed that data (it ended in the BIOS, printing), never mapped
; its segment, ran the USB layer on the caller's page-2 RAM (all zeros ->
; endless CH376 loop: the hardware "blue screen"). Now MAPPER_MODE picks:
;   DOS 2 + table  -> the DOS 2 code below, unchanged.
;   MSX-DOS 1      -> _ES_DOS1: direct OUTs to port FEh, like the stack bounce.
;                     There is no P2_SEG image and the mapper registers are
;                     not reliably readable, so the caller's page-2 segment
;                     is FOUND: a 3-byte marker is written at BFFDh in the
;                     current page 2, then segments are mapped one by one
;                     (last known one first) until the marker shows up; the
;                     caller's 3 bytes are put back before anything else.
;                     The segment is the one allocated in DOS 2 mode (a
;                     system segment, the highest free one); DOS 1 cannot
;                     allocate, so without one the driver stays inert.
;   no table yet   -> fail (pre-DOSINIT: COUNTDRV). v3.3.3 called F200h
;                     there too and only survived because INIWRK zeroes it:
;                     NOPs slid into the RET at H.PROMPT (F24Fh), A=1 < 4.
;
; Output: Cy=1 if no segment could be obtained (driver inert).
; Corrupts AF, BC, HL, IX (DE preserved).
; ==========================================================================
ENTER_SEG:
    call MY_GWORK
    call MAPPER_MODE             ; A = 0 DOS 2 / 1 MSX-DOS 1 / 2 no support
    or a
    jp nz,_ES_NOT2
    bit F_HAVESEG,(ix+0)
    jr z,_ES_ALLOC
_ES_MAP:
    di
    call JT_GET_P2
    ld (ix+2),a                  ; (first guess for a later MSX-DOS 1 call)
    push af
    ld a,(ix+1)
    push af
    call JT_PUT_P2
    pop af
    ld (CP_OSEG),a               ; our segment is mapped now: RAM write works
    pop af
    ld (NEXTOR_SEG),a
    xor a
    ld (SEG_DOS1),a              ; Cy=0; EXIT_SEG restores through PUT_P2
    ret
_ES_ALLOC:
    di
    ; v3.3.4: ALL_SEG runs through the kernel's _PUT_BDOS, which records the
    ; segments now in pages 0-2 as "the TPA" (P0_TPA..P2_TPA) and pages its
    ; own. Our first call comes from INSIDE DOSINIT (AUTODRV), where pages 0/2
    ; already hold the kernel's CODE/DATA segments: they became "the TPA" and
    ; DOSINIT's final restore left them paged in (emulator: 62/63 instead of
    ; 3/1). DOS 2 heals it by chance later on; MSX-DOS 1 (disk emulation mode
    ; enters it right after DOSINIT) kept the kernel segments as its TPA and
    ; the game crashed. Save the kernel's three bytes and put them back.
    ld hl,(TPA_P0)               ; P0_TPA, P1_TPA
    push hl
    ld a,(TPA_P2)
    push af
    call GET_P2_SLOT             ; A = slot visible in page 2 (primary mapper)
    push af
    ld b,a                       ; B = that slot, type bits 000 = only it
    ld a,1                       ; system segment (persists forever)
    call JT_ALL_SEG
    pop bc                       ; B = page-2 slot (flags and A untouched)
    pop hl                       ; H = P2_TPA before the call
    push af                      ; ALL_SEG's result (A, Cy)
    ld a,h
    ld (TPA_P2),a
    pop af
    pop hl
    ld (TPA_P0),hl               ; P0_TPA/P1_TPA as they were (flags kept)
    jr c,_ES_FAIL
    cp 4                         ; defensive: segments 0-3 are TPA; a result
    jr c,_ES_FAIL                ;  there means broken accounting - refuse
    push af
    push bc
    call MY_GWORK                ; (ALL_SEG/GWORK corrupt AF/BC/IX)
    pop bc
    pop af
    ld (ix+1),a
    ld (ix+3),b                  ; its slot: MSX-DOS 1 mode checks page 2
    set F_HAVESEG,(ix+0)
    call _ES_MAP
_ES_FRESH:                       ; segment RAM is garbage (fresh or overwritten)
    push hl
    ld hl,SEG_CANARY_VAL
    ld (SEG_CANARY),hl
    pop hl
    xor a
    ld (ISO_STATE),a             ; fresh segment: no medium probed yet
    ld (ISO_TVALID),a            ;  no ISO allocation tables (RAM is garbage)
    ld (LOG_N),a                 ;  and an empty CALL DREAM LOG
    ld (CHG_GUARD),a             ;  and no unreported disc change
    ld (VFY_PEND),a              ;  and no identity to verify (v3.3.5)
    ld (MID_OK),a                ;  against nothing served yet
    ld (CACHE_OK),a              ;  and nothing cached
    ld (FMT_ACTIVE),a            ;  and the Sony block-0 guard closed
    ld (DIRTY0_ON),a             ;  and the disc's own dirty flag (v3.3.7)
    ld (WAKE_ACTIVE),a           ;  and no bring-up session (v3.3.6: every
    ld (WAKE_ABORT),a            ;  CH376 wait asks WAIT_TICK, which reads it)
    ret                          ; (xor a: Cy=0)
_ES_FAIL:
    ei
    scf
    ret
_ES_NOT2:
    dec a
    jr nz,_ES_FAIL               ; 2: no mapper support at all (pre-DOSINIT)
    bit F_HAVESEG,(ix+0)
    jr z,_ES_FAIL                ; MSX-DOS 1 cannot allocate: stay inert
    ; ---- MSX-DOS 1 mode ----
    ; (interrupts: EXIT_SEG does EI as in DOS 2 - a floppy DSKIO returns with
    ; interrupts on too, measured on the Sanyo's own disk ROM with Quinpl)
    di
    ld hl,0
    add hl,sp
    ld a,h
    and 0C0h
    cp 80h
    jr z,_ES_FAIL                ; stack in page 2: switching it would lose it
    call GET_P2_SLOT             ; (corrupts BC, HL)
    cp (ix+3)
    jr nz,_ES_FAIL               ; page 2 is not the RAM our segment lives in
    push de
    ld hl,(0BFFDh)
    push hl                      ; caller's bytes at BFFDh/BFFEh
    ld a,(0BFFFh)
    push af                      ; caller's byte at BFFFh
    ld a,r
    ld b,a                       ; B = marker, different on every call
    ld hl,0BFFDh
    ld (hl),b                    ; BFFD = B
    inc hl
    cpl
    ld (hl),a                    ; BFFE = NOT B
    inc hl
    ld (hl),0A5h                 ; BFFF = A5h
    dec hl
    dec hl
    ld c,(ix+2)                  ; the caller's segment last time (or DOS 2's)
    call _ES_PROBE
    jr z,_ES_HIT
    ld c,0
_ES_SCAN:                        ; then every segment number
    call _ES_PROBE
    jr z,_ES_HIT
    inc c
    jr nz,_ES_SCAN
    ld c,(ix+2)                  ; nowhere (cannot happen with RAM in page 2):
    call _ES_PROBE               ;  map the best guess back and give up
    scf
_ES_HIT:                         ; page 2 = segment C; Cy=0 found, Cy=1 not
    pop de                       ; D = caller's BFFFh byte (E = flags, unused)
    ld a,d
    ld (0BFFFh),a
    pop de
    ld (0BFFDh),de               ; caller's 3 bytes are back (flags kept)
    pop de
    jr c,_ES_FAIL
    ld (ix+2),c
    ld a,(ix+1)
    out (MAPPER_PORT_P2),a       ; our segment in page 2
    ld (CP_OSEG),a
    ld a,c
    ld (NEXTOR_SEG),a
    ld a,1
    ld (SEG_DOS1),a              ; EXIT_SEG: restore with a direct OUT
    push hl
    ld hl,(SEG_CANARY)
    ld bc,SEG_CANARY_VAL
    or a
    sbc hl,bc
    pop hl
    ret z                        ; segment intact (Cy=0)
    ; a DOS 1 program used our segment: rebuild the state and re-enumerate
    ; the device on the next access instead of trusting garbage
    res F_READY,(ix+0)
    res F_CAPOK,(ix+0)
    jp _ES_FRESH

; _ES_PROBE - map segment C in page 2 (direct OUT); Z=1 if the marker B, NOT B,
; A5h is at (HL)=BFFDh there. Preserves BC, DE, HL. Corrupts AF.
_ES_PROBE:
    ld a,c
    out (MAPPER_PORT_P2),a
    ld a,(hl)
    cp b
    ret nz
    inc hl
    ld a,(hl)
    cpl
    inc hl
    cp b
    jr nz,_EP_OUT
    ld a,(hl)
    cp 0A5h
_EP_OUT:
    dec hl
    dec hl                       ; (16-bit dec: flags kept)
    ret

; ==========================================================================
; MAPPER_MODE - which page-2 mapping services exist right now (v3.3.4).
; Out: A = 0 DOS 2 mode with the mapper support jump table at F200h
;          1 MSX-DOS 1 mode (MAIN_BANK = 3): direct port FEh only
;          2 neither (before DOSINIT: F1C9h-F37Fh were zeroed by INIWRK)
; The table is recognised by its JP opcodes (ALL_SEG, PUT_P2, GET_P2).
; Corrupts AF only.
; ==========================================================================
MAPPER_MODE:
    ld a,(MAIN_BANK)
    cp 3
    ld a,1
    ret z
    ld a,(JT_ALL_SEG)
    cp 0C3h
    jr nz,_MM_NONE
    ld a,(JT_PUT_P2)
    cp 0C3h
    jr nz,_MM_NONE
    ld a,(JT_GET_P2)
    cp 0C3h
    ld a,0
    ret z
_MM_NONE:
    ld a,2
    ret

; ==========================================================================
; EXIT_SEG - restore Nextor's page-2 segment and re-enable interrupts.
; DOS 2: through PUT_P2 (keeps P2_SEG's image right). MSX-DOS 1 (v3.3.4): a
; direct OUT - there is no jump table and no image to keep.
; Corrupts AF.
; ==========================================================================
EXIT_SEG:
    ld a,(SEG_DOS1)
    or a
    jr nz,_XS_DOS1
    ld a,(NEXTOR_SEG)
    call JT_PUT_P2
    ei
    ret
_XS_DOS1:
    ld a,(NEXTOR_SEG)
    out (MAPPER_PORT_P2),a
    ei
    ret

; ==========================================================================
; _CP_BOUNCE - the stack-bounce inner loop shared by COPY_OUT and COPY_IN.
;
; Moves D*8 bytes from the source cursor to the dest cursor, 8 bytes per
; batch, when BOTH sides live in page 2 but in DIFFERENT mapper segments (so
; they cannot be mapped at the same time). The register file is the courier:
; four POPs read the source with segment B mapped, page 2 is flipped to
; segment C with a direct `out (0FEh),a` (identical to the kernel's _PUT_P2,
; which is just `ld (P2_SEG),a / out (0FEh),a` - P2_REG=0FEh, no slot work),
; and four PUSHes lay the same eight bytes down byte-identically.
;
; SP is used purely as the data pointer here: there is NOT one CALL/RET/PUSH
; of control flow inside the loop, so no page-3 stack is needed mid-batch.
; The caller MUST have interrupts disabled (ENTER_SEG did DI); page 3 is never
; switched. SP is used as a data pointer inside, so _CP_BOUNCE snapshots the
; real SP (with the CALL return address on top) in IY on entry and restores it
; before RET - it clobbers IY, which the COPY_* prologue already saved.
;
; In:  HL = source cursor (lowest source byte)
;      IX = dest cursor + 8 (PUSH fills downward, so it points one batch past
;                            the first dest byte)
;      D  = batch count, 1..256 (0 encodes 256 for the dec/jr loop)
;      B  = "pop segment": mapped before reading the source
;      C  = "push segment": mapped before writing the dest
; Out: HL = source + D*8 ; page 2 = segment C ; IX,IY,BC,DE,AF and all shadow
;      registers trashed; SP restored to the caller's value.
;
; Batch timing (documented target): 220 T-states / 8 bytes = 27.5 T/byte.
;   out+ld sp,hl 21 | 4 pop 40 | ex af,af'+exx 8 | ld hl,0+add hl,sp 21
;   | out+ld sp,ix 25 | ex af,af'+push af 15 | exx+3 push 37 | ld ix,16
;   +add ix,sp 29 | exx 4 | dec d+jr 16 = 216-220.
; ==========================================================================
_CP_BOUNCE:
    ld iy,0
    add iy,sp                    ; IY = real SP (the RET address sits on top);
                                 ;   restored just before RET below
_CP_B_LOOP:
    ld a,b                       ; A = pop segment
    out (0FEh),a                 ; map the source segment into page 2
    ld sp,hl                     ; SP -> source (data pointer, not a stack)
    exx                          ; use the shadow set as the courier
    pop bc                       ; s0,s1
    pop de                       ; s2,s3
    pop hl                       ; s4,s5
    pop af                       ; s6,s7  (POP AF hits the ACTIVE AF: exx does
                                 ;         not switch it; SP is now source+8)
    ex af,af'                    ; park s6,s7 in the shadow AF (survives the
                                 ;   flag-clobbering address maths below)
    exx                          ; back to the main set: HL=source, B/C/D live
    ld hl,0
    add hl,sp                    ; HL = source + 8 = next source cursor
    ld a,c                       ; A = push segment
    out (0FEh),a                 ; map the dest segment into page 2
    ld sp,ix                     ; SP -> dest + 8 (PUSH walks downward)
    ex af,af'                    ; active AF = s6,s7
    push af                      ; -> dest+6, dest+7
    exx                          ; courier set again (s0..s5)
    push hl                      ; s4,s5 -> dest+4, dest+5
    push de                      ; s2,s3 -> dest+2, dest+3
    push bc                      ; s0,s1 -> dest+0, dest+1  (SP = dest start)
    ld ix,16
    add ix,sp                    ; IX = dest_start + 16 = next dest cursor + 8
    exx                          ; back to the main set (HL = next source)
    dec d
    jr nz,_CP_B_LOOP
    ld sp,iy                     ; restore SP to the RET address on the page-3
                                 ;   stack (page 2 = push segment, WORKRAM not
                                 ;   readable yet - the caller remaps our seg)
    ret

; ==========================================================================
; _CP_RUNLEN - chunk length so a copy never straddles a 16K page boundary.
;   run = min(BC, 4000h - (DE & 3FFFh))  ->  (CP_RUN)
; DE is the caller-side cursor (the only side that can wander across pages;
; our page-2 buffers are contiguous). Preserves BC, DE, HL. Corrupts AF.
; ==========================================================================
_CP_RUNLEN:
    push hl
    ld a,d
    and 3Fh                      ; A = high byte of the in-page offset
    cpl
    and 3Fh                      ; A = 3Fh - offset_hi
    ld h,a
    ld a,e
    cpl                          ; L = ~offset_lo
    ld l,a
    inc hl                       ; HL = 4000h - (DE & 3FFFh) = distance to boundary
    ; run = min(HL=dist, BC=count)
    ld a,h
    cp b
    jr c,_CP_RL_STORE            ; dist < count -> run = dist (already in HL)
    jr nz,_CP_RL_CNT             ; dist > count -> run = count
    ld a,l
    cp c
    jr c,_CP_RL_STORE            ; dist < count -> run = dist
_CP_RL_CNT:
    ld h,b                       ; run = count
    ld l,c
_CP_RL_STORE:
    ld (CP_RUN),hl
    pop hl
    ret

; ==========================================================================
; COPY_OUT - copy BC bytes from HL (our segment, contiguous in page 2) to DE
; (Nextor's buffer, any page but 1). Runs with our segment mapped and MUST
; leave it mapped (P2_SEG consistent) on return: the callers keep reading our
; WORKRAM and eventually call EXIT_SEG.
;   * dest in page 0/1/3: LDIR straight into it (our page-2 source is visible
;     at the same time).
;   * dest in page 2: stack bounce (source=our seg -> dest=kernel seg), with
;     the <8-byte tail and sub-8-byte runs going through the old per-byte
;     WR_SEG loop (_CO_BYTELOOP).
; Corrupts AF, BC, DE, HL only: IX/IY and the shadow set are used as scratch
; but saved and restored here. BC must be <= 2048: the bounce batch counter
; is 8 bits (N = run/8, 0 encodes 256) - a larger count would truncate.
; ==========================================================================
COPY_OUT:
    ld a,b
    or c
    ret z                        ; nothing to copy: page 2 untouched
    di                           ; the stack bounce parks SP inside page-2 data;
                                 ;   an IRQ there would corrupt. ENTER_SEG
                                 ;   already DI'd (and the old WR_SEG path DI'd
                                 ;   too) - this only re-asserts the invariant.
    push ix                      ; preserve the caller's IX/IY and shadow set
    push iy                      ;  (once per call - negligible)
    exx
    push bc
    push de
    push hl
    exx
    ex af,af'
    push af
    ex af,af'
    ld a,(NEXTOR_SEG)            ; (CP_OSEG = our segment: set by ENTER_SEG -
    ld (CP_KSEG),a               ;  v3.3.4, no GET_P2 in MSX-DOS 1 mode)
_CO_CHUNK:
    ld a,b
    or c
    jp z,_CO_EPILOGUE
    call _CP_RUNLEN              ; (CP_RUN) = bytes until the next page boundary
    ld a,d                       ; dest page
    cp 0C0h
    jp nc,_CO_LDIR               ; page 3
    cp 80h
    jp c,_CO_LDIR                ; page 0/1
    ; ---- dest in page 2: stack bounce ----
    ld (CP_SRC),hl
    ld (CP_DST),de
    ld (CP_CNT),bc
    ld hl,(CP_RUN)
    ld a,l
    and 0F8h                     ; fast bytes = run & ~7 (H unchanged, run<=2048)
    ld l,a
    ld (CP_FAST),hl
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l                         ; HL = N = fast / 8
    ld a,h
    or l
    jr z,_CO_P2_BYTES            ; run < 8: whole run through the byte loop
    ld d,l                       ; D = N (256 -> 0, handled by the dec/jr loop)
    ld hl,(CP_DST)
    ld bc,8
    add hl,bc
    push hl
    pop ix                       ; IX = dest + 8
    ld a,(CP_OSEG)
    ld b,a                       ; pop segment = our segment
    push af                      ; our segment, on the page-3 stack
    ld a,(CP_KSEG)
    ld c,a                       ; push segment = kernel segment
    ld hl,(CP_SRC)               ; HL = source cursor (our segment)
    call _CP_BOUNCE              ; N batches; restores SP itself. Page 2 ends on
                                 ;   the kernel segment, so WORKRAM is NOT
                                 ;   readable right after.
    pop af                       ; A = our segment (v3.3.4: from the stack, not
                                 ;   GET_P2 - no jump table in MSX-DOS 1 mode;
                                 ;   in DOS 2 P2_SEG's image still says ours:
                                 ;   the direct-out bounce never touched it)
    out (MAPPER_PORT_P2),a       ; remap our segment -> page 2 matches the image
    ; advance the cursors by the fast bytes and re-dispatch (tail + rest)
    push hl                      ; HL = source + fast (from the bounce)
    ld hl,(CP_DST)
    ld bc,(CP_FAST)
    add hl,bc
    ex de,hl                     ; DE = dest + fast
    ld hl,(CP_CNT)
    ld bc,(CP_FAST)
    or a
    sbc hl,bc
    ld b,h
    ld c,l                       ; BC = count - fast
    pop hl                       ; HL = source + fast
    jp _CO_CHUNK
_CO_P2_BYTES:
    ld hl,(CP_SRC)
    ld de,(CP_DST)
    ld bc,(CP_RUN)
    call _CO_BYTELOOP            ; copies run bytes; HL,DE advance; BC = 0
    push hl
    ld hl,(CP_CNT)
    ld bc,(CP_RUN)
    or a
    sbc hl,bc
    ld b,h
    ld c,l                       ; BC = count - run
    pop hl                       ; HL = source + run (DE = dest + run already)
    jp _CO_CHUNK
_CO_LDIR:
    ; LDIR run bytes: HL = our-segment source, DE = page-0/1/3 dest
    push hl
    ld a,c                       ; count - run -> BC, computed without touching HL
    ld hl,CP_RUN
    sub (hl)
    ld c,a
    ld a,b
    inc hl
    sbc a,(hl)
    ld b,a
    ld (CP_CNT),bc               ; new count
    ld bc,(CP_RUN)
    pop hl
    ldir                         ; HL -> source+run, DE -> dest+run, BC = 0
    ld bc,(CP_CNT)
    jp _CO_CHUNK
_CO_EPILOGUE:
    ex af,af'
    pop af
    ex af,af'
    exx
    pop hl
    pop de
    pop bc
    exx
    pop iy
    pop ix
    ret

; Old per-byte COPY_OUT loop, kept as the fallback for sub-8-byte page-2 runs
; and the tail of a bounce. Copies BC bytes HL->DE, deciding per byte (page
; 0/1/3 direct, page 2 into CP_KSEG); needs our segment mapped (CP_OSEG).
; v3.3.4: the page-2 byte is written with two direct OUTs (kernel segment,
; store, our segment back) instead of WR_SEG: same effect under DI, and it
; works in MSX-DOS 1 mode where the jump table does not exist.
; On return HL,DE advance by the count and BC = 0. Corrupts AF, BC, DE, HL.
_CO_BYTELOOP:
    ld a,b
    or c
    ret z
_CO_LOOP:
    ld a,d
    cp 80h
    jr c,_CO_DIRECT              ; dest in page 0/1
    cp 0C0h
    jr nc,_CO_DIRECT             ; dest in page 3
    ; dest in page 2: the byte goes into the kernel's segment
    push bc
    ld a,(CP_OSEG)
    ld b,a                       ; B = our segment
    ld c,(hl)                    ; C = data byte (our segment is mapped)
    ld a,(CP_KSEG)
    out (MAPPER_PORT_P2),a       ; kernel segment in page 2
    ld a,c
    ld (de),a
    ld a,b
    out (MAPPER_PORT_P2),a       ; our segment back
    pop bc
    jr _CO_NEXT
_CO_DIRECT:
    ld a,(hl)
    ld (de),a
_CO_NEXT:
    inc hl
    inc de
    dec bc
    ld a,b
    or c
    jr nz,_CO_LOOP
    ret

; ==========================================================================
; COPY_IN - copy BC bytes from DE (Nextor's buffer, any page but 1) to HL
; (our segment, contiguous in page 2). Mirror of COPY_OUT for the write path.
;   * source in page 0/1/3: LDIR straight from it.
;   * source in page 2: stack bounce (source=kernel seg -> dest=our seg), with
;     the sub-8-byte remainder through the old per-byte RD_SEG loop.
; Routes on the SOURCE page (DE), the only side that can straddle pages.
; Corrupts AF, BC, DE, HL only; IX/IY + shadow set saved/restored. BC must
; be <= 2048 (same 8-bit batch-counter limit as COPY_OUT).
; ==========================================================================
COPY_IN:
    ld a,b
    or c
    ret z
    di                           ; see COPY_OUT: re-assert the DI invariant the
                                 ;   stack bounce relies on
    push ix
    push iy
    exx
    push bc
    push de
    push hl
    exx
    ex af,af'
    push af
    ex af,af'
    ld a,(NEXTOR_SEG)            ; (CP_OSEG = our segment: set by ENTER_SEG)
    ld (CP_KSEG),a
_CI_CHUNK:
    ld a,b
    or c
    jp z,_CI_EPILOGUE
    call _CP_RUNLEN              ; (CP_RUN) from the SOURCE cursor (DE)
    ld a,d                       ; source page
    cp 0C0h
    jp nc,_CI_LDIR               ; page 3
    cp 80h
    jp c,_CI_LDIR                ; page 0/1
    ; ---- source in page 2: stack bounce ----
    ld (CP_SRC),de               ; caller source cursor
    ld (CP_DST),hl               ; our-segment dest cursor
    ld (CP_CNT),bc
    ld hl,(CP_RUN)
    ld a,l
    and 0F8h
    ld l,a
    ld (CP_FAST),hl
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l                         ; HL = N = fast / 8
    ld a,h
    or l
    jr z,_CI_P2_BYTES
    ld d,l                       ; D = N (256 -> 0)
    ld hl,(CP_DST)
    ld bc,8
    add hl,bc
    push hl
    pop ix                       ; IX = our-segment dest + 8
    ld a,(CP_KSEG)
    ld b,a                       ; pop segment = kernel segment (caller source)
    ld a,(CP_OSEG)
    ld c,a                       ; push segment = our segment (dest)
    ld hl,(CP_SRC)               ; HL = source cursor (caller buffer)
    call _CP_BOUNCE              ; restores SP itself; page 2 ends on OUR segment
                                 ;   (the push segment): nothing to remap
    ; HL = source + fast ; advance the cursors and re-dispatch
    ex de,hl                     ; DE = source + fast (new caller cursor)
    ld hl,(CP_DST)
    ld bc,(CP_FAST)
    add hl,bc                    ; HL = our dest + fast (new dest cursor)
    push hl
    ld hl,(CP_CNT)
    ld bc,(CP_FAST)
    or a
    sbc hl,bc
    ld b,h
    ld c,l                       ; BC = count - fast
    pop hl                       ; HL = dest + fast
    jp _CI_CHUNK
_CI_P2_BYTES:
    ld de,(CP_SRC)
    ld hl,(CP_DST)
    ld bc,(CP_RUN)
    call _CI_BYTELOOP            ; copies run bytes; HL,DE advance; BC = 0
    push hl
    ld hl,(CP_CNT)
    ld bc,(CP_RUN)
    or a
    sbc hl,bc
    ld b,h
    ld c,l                       ; BC = count - run
    pop hl
    jp _CI_CHUNK
_CI_LDIR:
    ; LDIR run bytes: DE = page-0/1/3 source, HL = our-segment dest.
    ; LDIR always copies HL->DE, so swap the cursors around it.
    push hl                      ; save our-segment dest
    ld a,c
    ld hl,CP_RUN
    sub (hl)
    ld c,a
    ld a,b
    inc hl
    sbc a,(hl)
    ld b,a
    ld (CP_CNT),bc               ; new count
    pop hl                       ; HL = our-segment dest
    ex de,hl                     ; HL = source, DE = dest (LDIR direction)
    ld bc,(CP_RUN)
    ldir                         ; HL -> source+run, DE -> dest+run
    ex de,hl                     ; back to COPY_IN convention (HL=dest, DE=source)
    ld bc,(CP_CNT)
    jp _CI_CHUNK
_CI_EPILOGUE:
    ex af,af'
    pop af
    ex af,af'
    exx
    pop hl
    pop de
    pop bc
    exx
    pop iy
    pop ix
    ret

; Old per-byte COPY_IN loop, kept as the fallback (mirror of _CO_BYTELOOP).
; Copies BC bytes DE->HL; page 0/1/3 direct, page 2 from CP_KSEG with two
; direct OUTs (v3.3.4, was RD_SEG). Corrupts AF, BC, DE, HL.
_CI_BYTELOOP:
    ld a,b
    or c
    ret z
_CI_LOOP:
    ld a,d
    cp 80h
    jr c,_CI_DIRECT              ; source in page 0/1
    cp 0C0h
    jr nc,_CI_DIRECT             ; source in page 3
    ; source in page 2: the byte comes from the kernel's segment
    push bc
    ld a,(CP_OSEG)
    ld b,a                       ; B = our segment
    ld a,(CP_KSEG)
    out (MAPPER_PORT_P2),a       ; kernel segment in page 2
    ld a,(de)
    ld c,a                       ; C = data byte
    ld a,b
    out (MAPPER_PORT_P2),a       ; our segment back
    ld (hl),c
    pop bc
    jr _CI_NEXT
_CI_DIRECT:
    ld a,(de)
    ld (hl),a
_CI_NEXT:
    inc hl
    inc de
    dec bc
    ld a,b
    or c
    jr nz,_CI_LOOP
    ret

; ==========================================================================
; Budget helpers: mechanical MiniDisc operations need ~10 s per USB token
; and endless NAK patience; everything else uses the normal budget.
; Corrupt AF.
; ==========================================================================
BUDGET_MECH:
    ld a,8
    ld (CH_WAIT_MULT),a
    scf                          ; NAK retry forever
    jp CH_CONFIGURE_NAK_RETRY

BUDGET_NORMAL:
    ld a,1
    ld (CH_WAIT_MULT),a
    or a                         ; NAK retry limited (~3 s)
    jp CH_CONFIGURE_NAK_RETRY

; ==========================================================================
; DRV_INIT
;  1st call (A=0): request no page-3 work area beyond the default 8 bytes
;                  (HL=0) and no DRV_TIMI hook (Cy=0).
;  2nd call (A=1): print the banner and check that the CH376 responds.
;
;  NOTHING ELSE can happen here: DRV_INIT runs BEFORE DOSINIT in Nextor's
;  boot (bank0/init.mac), so the mapper support routines do not exist yet
;  and no RAM segment can be reserved. The real device bring-up happens on
;  the first DEV_STATUS/LUN_INFO call (drive automapping, after DOSINIT)
;  via ENTER_SEG's lazy allocation + HW_FULL_INIT. The CH376 presence test
;  is pure I/O (no work RAM), so it is safe here and gives the user boot
;  feedback.
; ==========================================================================
DRV_INIT:
    or a
    jr nz,_DI_SECOND
    ld hl,0                      ; default 8-byte SLTWRK entry is enough
    or a                         ; Cy=0: no timer interrupt hook
    ret

_DI_SECOND:
    ; The BIOS runs extension-ROM inits in SCREEN 1 (32 cols, MSX1 look).
    ; On MSX2+ switch to SCREEN 0 x 80 before the banner: nicer, and the
    ; RW_DIAG/DS_DIAG snitches (SCREEN 0 only) become visible from boot.
    ; If OUR bootloader (bootrd0) already set 80-column text, keep the
    ; screen as-is: one coherent boot screen, kernel banner preserved.
    ld a,(MSXVER)                ; BIOS visible in page 0 during DRV_INIT
    or a
    jr z,_DI_BANNER              ; MSX1: keep the BIOS mode as-is
    ld a,(SCRMOD)
    or a
    jr nz,_DI_SETTXT
    ld a,(LINLEN)
    cp 80
    jr nc,_DI_BANNER             ; already 80-col text: don't clear it
_DI_SETTXT:
    ld a,80
    ld (LINL40),a
    call INITXT
_DI_BANNER:
    ld de,S_BANNER
    call PRINT
    call MY_GWORK
    ld (ix+0),10h                ; only F_BOOTWAIT set: the first bring-up
                                 ;  gets the walkman wake-up window
    call CH_HW_TEST              ; register/IO-only presence probe
    jr c,_DI_NOCHIP
    ld de,S_CHIPOK
    jr _DI_PRT
_DI_NOCHIP:
    ld de,S_NOCHIP
_DI_PRT:
    call PRINT
    ; CTRL+STOP held during init would freeze Nextor (known bug):
    ; clear INTFLG like SunriseIDE does.
    ld a,(INTFLG)
    cp 3
    ret nz
    xor a
    ld (INTFLG),a
    ret

; ==========================================================================
; HW_INIT_PATIENT - HW_FULL_INIT inside a bring-up SESSION (v2.2, v3.3.6).
; The walkman only gets VBUS the instant the MSX powers on and needs
; several seconds of its OWN boot before it appears on the USB bus; the
; first bring-up after DRV_INIT (flag F_BOOTWAIT) therefore retries the
; full init (up to 8 attempts) so that "plug walkman + power on" boots
; straight from the disc; a unit that vanished (F_HOTWAIT) gets the same
; window once for whatever is plugged in next (hot plug).
; v3.3.6 - hardware 2026-09-26: a CD/DVD drive holding a scratched CD
; answered every command, slowly, with 04/09/02 (focus failure); the hot
; window retried it 8 times at ~5 minutes per attempt, and ESC - polled only
; between commands - did nothing. Now:
;   * EVERY bring-up is a session: the boot window, the hot-plug window and
;     a plain one-shot bring-up (1 attempt) alike. While it runs, every CH376
;     wait, every pause and every wait-loop round goes through WAIT_TICK:
;     ESC ends the session within ~0.13 s, and a hard time cap (CAP_BOOT
;     ~3 min, CAP_HOT ~90 s) ends it whatever the unit does. An abandoned
;     session returns code 8 with the device dropped (F_READY=0, the chip
;     told to stop NAK-retrying): the next access starts from scratch.
;   * a CD/DVD drive that talks but cannot use its disc (DISC_BAD: sense key
;     03/04 heard while waiting) fails with code 6 at once and is NOT
;     retried: waiting does not repair a disc. The walkman is unchanged (a
;     code 6 of a walkman still booting/loading - 02/04/xx, 02/3A, no sense -
;     retries as before; its FORMAT-ERROR tantrum wants the fresh bus reset).
;   * the wait line appears only once something is actually waited for (a
;     wait-loop round or a slow command: WAIT_TICK repaints it every 4th
;     tick), except at boot, where it shows before the first attempt; it is
;     cleared at the end unless it is the boot window's.
; v3.3.7: code 3 ("nothing on the bus", TEST_CONNECT 16h) really arrives
; now (until v3.3.6 HW_FULL_INIT lost it and an empty bus came back as 4).
; Its handling is unchanged: the boot window retries it like 3/4/6 (8
; attempts: the walkman shows up on the bus seconds after our VBUS wakes
; it); the hot-plug window fails on it at once, quietly, and stays armed
; (F_HOTWAIT) for the unit plugged in later; a one-shot bring-up fails.
; Same contract as HW_FULL_INIT, plus code 8 = abandoned (ESC / time cap).
; Requires segment mapped, interrupts off.
; ==========================================================================
HW_INIT_PATIENT:
    call MY_GWORK
    ld hl,CAP_BOOT
    ld b,8                       ; attempts of a patient window
    xor a                        ; WAKE_HOT = 0: the boot window
    bit F_BOOTWAIT,(ix+0)
    res F_BOOTWAIT,(ix+0)        ; one boot window per power-on (res: flags
    jr nz,_HIP_ARM               ;  untouched)
    ld hl,CAP_HOT
    inc a                        ; WAKE_HOT = 1: the hot-plug window
    ; hot plug: a unit vanished earlier, so whatever is being plugged in
    ; (a walkman needs seconds of its own boot) gets the same visible,
    ; ESC-able window - once, and only while something is on the bus
    bit F_HOTWAIT,(ix+0)
    res F_HOTWAIT,(ix+0)
    jr nz,_HIP_ARM
    inc a                        ; WAKE_HOT = 2: a plain bring-up, ONE
    ld b,1                       ;  attempt - ESC-able and capped all the same
_HIP_ARM:
    ld (WAKE_HOT),a
    ld (WAKE_LEFT),hl
    ld a,b
    ld (WAKE_TRIES),a
    ld a,1
    ld (WAKE_ACTIVE),a           ; arms ESC, the time cap and the strike-outs
    xor a
    ld (WAKE_FAST),a             ; attempt 1 runs with the full, proven
    ld (WAKE_ABORT),a            ;  Fase-2 budgets (healthy cold walkman)
    ld (WAKE_SPIN),a
    ld (WAKE_CODE),a
    ld (WAKE_SHOWN),a
    ld a,(WAKE_HOT)
    or a
    call z,_HIP_TICK             ; boot: notice BEFORE the first attempt (v2.2
                                 ;  hardware: it only showed after minutes);
                                 ;  otherwise: only once something is waited
                                 ;  for (an empty bus fails silently)
_HIP_TRY:
    call HW_FULL_INIT
    jr nc,_HIP_DONE              ; device up: done
    cp 3
    jr c,_HIP_FAIL               ; 1/2: the CH376 itself is broken - hopeless
    cp 7
    jr nc,_HIP_FAIL              ; 7: wrong device (512-byte pendrive etc.),
                                 ;  8: the session was abandoned
    cp 6
    jr nz,_HIP_NOT6
    ld b,a
    ld a,(DISC_BAD)              ; v3.3.6: a CD/DVD drive that answers but
    or a                         ;  cannot use its disc: another attempt only
    ld a,b                       ;  repeats the same minutes of retries
    jr nz,_HIP_FAIL
_HIP_NOT6:
    cp 3
    jr nz,_HIP_RETRY
    ld b,a
    ld a,(WAKE_HOT)
    dec a
    ld a,b
    jr nz,_HIP_RETRY
    ; hot plug and nothing on the bus (yet): don't stall every access,
    ; stay armed for when the unit does show up. (v3.3.7: this branch is
    ; live now - until v3.3.6 HW_FULL_INIT never returned 3, an empty bus
    ; came back as 4 and spent the whole window, 8 attempts, on it.)
    push af
    call MY_GWORK
    set F_HOTWAIT,(ix+0)
    pop af
    jr _HIP_FAIL
_HIP_RETRY:
    ; 3 (no device) / 4 (enum failed) / 6 (medium not ready): the walkman
    ; may still be booting - or mid FORMAT-ERROR tantrum after being woken
    ; by our own VBUS. Show progress and redo the init from scratch: the
    ; fresh bus reset is what recovers a post-tantrum walkman (the
    ; "already-awake" scenario works, so that state is reachable).
    push af
    ld hl,WAKE_TRIES
    dec (hl)
    jr z,_HIP_STOP               ; out of attempts (a plain bring-up: at once)
    call _HIP_PROG               ; "NN/cc": attempts left / last code
    ld a,1
    ld (WAKE_FAST),a             ; retries: shortened TUR/warm-up budgets
    call _HIP_PAUSE              ; ~2.7 s breather; Cy=1: ESC / time cap
    jr c,_HIP_STOP
    pop af
    jr _HIP_TRY
_HIP_STOP:
    pop af                       ; A = last failure code
_HIP_FAIL:
    scf
_HIP_DONE:
    push af                      ; success (Cy=0,A=0) or failure (Cy=1,code)
    jr nc,_HD_LINE
    ld a,(WAKE_ABORT)
    or a
    jr z,_HD_LINE
    ; v3.3.6: abandoned (ESC or the time cap). Whatever the half-done
    ; bring-up left behind is dropped: the chip stops NAK-retrying, the
    ; budget is back to normal and the next access starts from scratch
    ; (bus reset + enumeration). Code 8.
    ld a,CH_CMD_ABORT_NAK
    out (CH_COMMAND_PORT),a
    call BUDGET_NORMAL
    call MY_GWORK
    res F_READY,(ix+0)
    res F_CAPOK,(ix+0)
    pop af
    ld a,8                       ; (Cy=1 kept)
    push af
_HD_LINE:
    ld a,(WAKE_HOT)
    or a
    jr z,_HD_END                 ; boot: the notice stays on the boot screen
    ld a,(WAKE_SHOWN)
    or a
    call nz,_HIP_CLEAR           ; otherwise leave no wait line behind
_HD_END:
    xor a
    ld (WAKE_ACTIVE),a           ; normal budgets/behaviour from here on
    ld (WAKE_FAST),a             ; (a stale 1 would shorten normal warm-ups)
    ld (WAKE_ABORT),a
    ld (WAKE_HOT),a
    pop af
    ret

_HIP_TICK:                       ; repaint the row-23 wait line: message +
                                 ; "NN/cc" (tries/last code, once a retry
                                 ; happened) + an ASCII spinner that proves
                                 ; the machine is alive during long waits.
                                 ; Corrupts AF, C, DE, HL.
    call _RD_SETUP
    ret c
    ld a,1
    ld (WAKE_SHOWN),a            ; (v3.3.6: _HIP_DONE clears only a drawn line)
    ld hl,_HIP_S
    call _RD_PUTS
    ld a,(WAKE_CODE)
    or a
    jr z,_HT_SPIN                ; no failed attempt yet: clean line
    ld c,a
    ld a,(WAKE_TRIES)
    call _RD_PUTHEX
    ld a,"/"
    call _RD_PUTC
    ld a,c
    call _RD_PUTHEX
    ld a," "
    call _RD_PUTC
_HT_SPIN:
    ld a,(WAKE_SPIN)
    inc a
    and 3
    ld (WAKE_SPIN),a
    ld hl,_SPIN_TAB
    add a,l
    ld l,a
    jr nc,_HT_PUT
    inc h
_HT_PUT:
    ld a,(hl)
    jp _RD_PUTC
_HIP_S: db "Waiting for the disc drive... (ESC to skip) ",0
_SPIN_TAB: db ".oOo"             ; pulse loader (art direction 2026-07-09;
                                 ;  the classic \ renders as yen on JP fonts)

_HIP_CLEAR:                      ; blank the row-23 wait line
    call _RD_SETUP
    ret c
    ld b,80
    ld a,(LINLEN)
    cp 41
    jr nc,_HC_LOOP
    ld b,40
_HC_LOOP:
    ld a," "
    call _RD_PUTC
    djnz _HC_LOOP
    ret

_HIP_PROG:                       ; record the failed attempt, repaint line
    ld (WAKE_CODE),a
    jp _HIP_TICK

_HIP_PAUSE:                      ; ~2.7 s breather between two attempts,
    ld d,20                      ;  CPU-timed (the chip may be wedged right
_HP_OUT:                         ;  now). Cy=1 if ESC / the time cap cut it
    ld bc,4000h                  ;  short. ~0.14 s at 3.58 MHz
_HP_IN:
    dec bc
    ld a,b
    or c
    jr nz,_HP_IN
    call WAIT_TICK               ; ESC, time budget, spinner (every 4th tick)
    ret c
    dec d
    jr nz,_HP_OUT
    ret                          ; Cy=0 (WAIT_TICK): full pause elapsed

_HIP_ESC:                        ; Z=1 if ESC is held. Direct PPI scan (no
    in a,(0AAh)                  ;  BIOS in page 0 here): select keyboard
    and 0F0h                     ;  row 7 preserving the PPI's upper bits
    or 7
    out (0AAh),a
    in a,(0A9h)
    and 4                        ; bit 2 = ESC, 0 when pressed
    ret

; ==========================================================================
; WAIT_TICK (v3.3.6) - one ~0.13 s slice of waiting inside a bring-up
; session (WAKE_ACTIVE, see HW_INIT_PATIENT). Called by the CH376 INT wait
; after every 8192 polls (CH_WAIT_HOOKED, src/ch376.asm), by every step of
; WAIT_PAUSE, by _HIP_PAUSE and at the top of every wait-loop round. Outside
; a session it returns at once (Cy=0): nothing changes for normal I/O.
; Inside one:
;   * ESC held (direct PPI scan) ends the session: WAKE_ABORT = 1, "R ESC";
;   * each call spends one tick of the session's budget (WAKE_LEFT); when it
;     is spent: WAKE_ABORT = 1, "R time up" - the hard cap on the session;
;   * every 4th tick repaints the wait line (the spinner shows the machine
;     is alive while a command takes seconds).
; Once WAKE_ABORT is set every call answers Cy=1 at once and tells the
; CH376 to stop NAK-retrying (ABORT_NAK): each remaining wait of the
; abandoned bring-up ends within one slice and the chip stays responsive.
; Out: Cy=1 abandon the wait / Cy=0 go on.
; Preserves BC, DE, HL, IX, IY (the INT wait runs in the middle of a
; transfer); corrupts AF only.
; ==========================================================================
WAIT_TICK:
    push hl                      ; v3.4.1: every slice also ticks SEEK_TK (the
    ld hl,(SEEK_TK)              ;  time cap of the positioning retries),
    inc hl                       ;  session or not
    ld (SEEK_TK),hl
    pop hl
    ld a,(WAKE_ACTIVE)
    or a
    ret z                        ; no session: Cy=0
    ld a,(WAKE_ABORT)
    or a
    jr nz,_WT_STOP
    call _HIP_ESC
    jr z,_WT_ESC
    push hl
    ld hl,(WAKE_LEFT)
    ld a,h
    or l
    jr z,_WT_TIME                ; the session's time is up
    dec hl
    ld (WAKE_LEFT),hl
    ld a,l
    pop hl
    and 3
    ret nz                       ; Cy=0
    push bc
    push de
    push hl
    call _HIP_TICK               ; every 4th tick: the spinner
    pop hl
    pop de
    pop bc
    or a                         ; Cy=0 (_HIP_TICK may return Cy=1)
    ret
_WT_TIME:
    pop hl
    call LOG_EVT                 ; CALL DREAM LOG "R time up"
    db 'R'+80h,LEV_TIMEUP
    jr _WT_SET
_WT_ESC:
    call LOG_EVT                 ; CALL DREAM LOG "R ESC"
    db 'R'+80h,LEV_ESC
_WT_SET:
    ld a,1
    ld (WAKE_ABORT),a
_WT_STOP:
    ld a,CH_CMD_ABORT_NAK        ; the token being waited for is given up
    out (CH_COMMAND_PORT),a
    scf
    ret

; WAIT_PAUSE (v3.3.6) - B steps of ~0.125 s (CH376 hardware delay), one
; WAIT_TICK after each: the same length as before outside a session, cut
; short by ESC / the time cap inside one. Out: Cy=1 cut short. Corrupts
; AF, BC.
WAIT_PAUSE:
    push bc
    ld bc,1250
    call CH_DELAY
    pop bc
    call WAIT_TICK
    ret c
    djnz WAIT_PAUSE
    ret                          ; Cy=0 (WAIT_TICK)

; ==========================================================================
; HW_FULL_INIT - full CH376 + USB device bring-up. Requires our segment
; mapped and interrupts disabled. Also used to recover from a transport
; death (device unplugged/replugged) in DEV_RW/DEV_STATUS.
;
; Output: Cy=0, A=0  device ready, capacity valid (flags updated)
;         Cy=1, A=1  CH376 not present          (F_READY=0)
;               A=2  CH376 mode/reset failure   (F_READY=0)
;               A=3  no USB device connected    (F_READY=0)
;               A=4  USB error during enumeration (F_READY=0)
;               A=6  device OK but READ CAPACITY failed - no/bad disc
;                    (F_READY=1! LUN exists, medium absent; F_CAPOK=0)
;               A=7  medium sector size is not 2048 (F_READY=0)
;               A=8  (v3.3.6) the bring-up session was abandoned - ESC or
;                    its time cap (WAKE_ABORT, see HW_INIT_PATIENT)
; Corrupts: everything.
; v3.3.6: a CD/DVD drive that answers MEDIUM/HARDWARE ERROR while it is
; waited for (DISC_BAD, CHK_UNUSABLE) gets no further waits nor START UNIT:
; code 6 as soon as the transport is up (F_READY=1, the drive stays known).
; v3.3.2: CHG_GUARD comes out as it went in - a bring-up neither raises it
; (a 28h in its own waits after the bus reset is no change Nextor must hear
; first: boot must work) nor lifts it (a change still unreported survives a
; transport re-init; only DEV_STATUS answering 2 lifts it).
; v3.3.5: whatever answers after a bring-up has to prove its identity before
; DEV_RW serves it (VFY_PEND = 1): a re-init is the strongest "not ready"
; phase of all (DEV_STATUS reports it as a change anyway: F_CHANGED).
; ==========================================================================
HW_FULL_INIT:
    ld a,(CHG_GUARD)
    push af
    call _HFI_BODY
    pop bc                       ; B = CHG_GUARD on entry
    push af                      ; the result: A + Cy
    ld a,b
    ld (CHG_GUARD),a
    pop af
    ret
_HFI_BODY:
    call LOG_EVT                 ; CALL DREAM LOG: "R INIT" (keeps all regs)
    db 'R'+80h,LEV_INIT
    ld a,1
    ld (VFY_PEND),a              ; v3.3.5 (see above)
    call MY_GWORK
    res F_READY,(ix+0)
    res F_CAPOK,(ix+0)
    xor a
    ld (CACHE_OK),a
    ld (ISO_STATE),a             ; whatever comes up gets probed again
    ld (FMT_ACTIVE),a            ; guard the Sony boot until a FORMAT clears it
    ld (DIRTY0_ON),a             ; v3.3.7: Nextor re-reads the disc's own flag
    ld (DISC_BAD),a              ; v3.3.6: nothing heard from this unit yet
    call _HFI_BLANKINQ           ; v3.3.6: IS_OPTICAL now steers the waits:
                                 ;  never from a previous unit's INQUIRY
    ld a,1
    ld (SCSI_TAG),a
    ld (CH_WAIT_MULT),a
    ; Preventive ABORT_NAK: an aborted NAK-forever wait leaves the chip deaf
    ; to every command. Then a soft (CPU-timed) delay: CH_DELAY needs a
    ; responsive chip, which is exactly what we cannot assume yet.
    ld a,CH_CMD_ABORT_NAK
    out (CH_COMMAND_PORT),a
    ld bc,0
_HFI_PRE:
    dec bc
    ld a,b
    or c
    jr nz,_HFI_PRE               ; ~0.5 s at 3.58 MHz
    ; chip present?
    call CH_HW_TEST
    ld a,1
    ret c
    ; full reset + host mode without SOF
    call CH_RESET_ALL
    call CH_DO_SET_NOSOF_MODE
    ld a,2
    ret c
    ; anything connected? v3.3.7: until v3.3.6 a "ld a,3" stood between
    ; TEST_CONNECT and the compare, so the chip's "nothing attached" (16h)
    ; was never seen: an empty bus went on through bus reset + enumeration
    ; and failed there, with code 4. Now an empty bus is code 3 at once.
    call _HFI_ATTACHED
    ld a,3
    ret c                        ; nothing attached (or no answer at all)
_HFI_CONN:
    ; ---- WARM-UP phase: the FULL auto-pilot suite of HIMDTEST (steps 3-7b,
    ; every one hardware-validated with the Sony). v1.1 only did
    ; CONNECT+MOUNT and the walkman never spun; HIMDTEST proves the Sony
    ; needs the whole conversation - crucially the auto-pilot START UNIT
    ; (7b), which is what actually wakes the mechanism - before the manual
    ; transport is usable. All BOC transfers here are <=64 bytes (the only
    ; kind the Sony services through the auto-pilot).
    ; Failures are non-fatal: the manual phase redoes what it can.
    xor a
    ld (BOCINQ),a
    ld (BOCCAP),a
    call CH_BUS_RESET
    ld a,4
    ret c
    call CHD_CONNECT
    jr c,_HFI_MANUAL             ; auto-pilot not available: try manual
    call CHD_MOUNT
    jr c,_HFI_MANUAL             ; no mount: try manual anyway
    call _HFI_ABORTED            ; v3.3.6: ESC / time cap meanwhile
    ret c
    ; INQUIRY (36 bytes, short BOC: works on real hardware)
    ld ix,INQ_BUF
    call CHD_INQUIRY
    jr c,_HFI_B_NOINQ
    ld a,1
    ld (BOCINQ),a
_HFI_B_NOINQ:
    ; TEST UNIT READY loop, 0.5 s pauses (HIMDTEST step 6)
    ld b,10
    ld a,(WAKE_FAST)
    or a
    jr z,_HFI_B_TUR
    ld b,2                       ; window retry: attempt 1 already paid this
_HFI_B_TUR:
    push bc
    ; keep ESC alive inside the warm-up too (v3.0 hardware: cold boots
    ; spent many seconds here with the keyboard dead); v3.3.6: WAIT_TICK,
    ; which also counts the session's time (no-op outside a session)
    call WAIT_TICK
    jr c,_HFI_B_OUT
    call CHD_TEST_UNIT_READY
    jr nc,_HFI_B_READY
    ld ix,SENSE_BUF
    call CHD_REQUEST_SENSE       ; clears the error condition
    call LOG_RQS                 ; CALL DREAM LOG (keeps all regs and flags)
    db 'H'
    jr c,_HFI_B_PAUSE
    ld a,(BOCINQ)                ; v3.3.6: a CD/DVD drive (INQUIRY above)
    or a                         ;  that cannot use its disc: no more rounds,
    jr z,_HFI_B_PAUSE            ;  and no capacity/START UNIT (a START
    call CHK_UNUSABLE            ;  makes it retry its focus all over again)
    jr z,_HFI_B_OUT
_HFI_B_PAUSE:
    ld b,4
    call WAIT_PAUSE              ; ~0.5 s (cut short by ESC / time cap)
    pop bc
    jr c,_HFI_MANUAL
    djnz _HFI_B_TUR
    jr _HFI_B_CAP                ; not ready: capacity may still answer
_HFI_B_OUT:
    pop bc
    jr _HFI_MANUAL
_HFI_B_READY:
    pop bc
_HFI_B_CAP:
    ; READ CAPACITY (8 bytes, short BOC) (HIMDTEST step 7)
    ld ix,CAP_BUF
    call CHD_READ_CAPACITY
    jr c,_HFI_B_NOCAP
    call RECOMPUTE_TOTALS        ; sets F_CAPOK when 2048 B/sector
    jr c,_HFI_B_NOCAP
    ld a,1
    ld (BOCCAP),a
_HFI_B_NOCAP:
    ; START UNIT via auto-pilot (HIMDTEST step 7b): THE SPIN-UP.
    call CHD_START_UNIT          ; result ignored: TUR below confirms
    call LOG_EVT                 ; CALL DREAM LOG: "U START ok/fail"
    db 'U'+80h,LEV_START
_HFI_MANUAL:
    ; ---- MANUAL phase (HIMDTEST steps 9-10): fresh bus reset + manual
    ; enumeration + manual START UNIT (the reset stops the motor again:
    ; Sony rule) + TUR. This is the transport the driver uses for data.
    call _HFI_ABORTED            ; v3.3.6: ESC / time cap in the warm-up
    ret c
    call CH_BUS_RESET
    ld a,4
    ret c
    call USB_ENUMERATE
    or a
    jr z,_HFI_ENUM_OK
    ld a,4
    scf
    ret
_HFI_ENUM_OK:
    call _HFI_ABORTED
    ret c
    call BUDGET_MECH
    ld a,(DISC_BAD)              ; v3.3.6: the warm-up already heard the
    or a                         ;  drive say it cannot use this disc: no
    jr nz,_HFI_SPUN              ;  START UNIT, no waiting for it
    call START_UNIT_L            ; non-fatal (emulator BOT-state quirk)
    call TUR_WAIT                ; wait until the unit reports ready
_HFI_SPUN:
    call _HFI_ABORTED
    ret c
    ; INQUIRY: only needed if the BOC phase did not get it
    ld a,(BOCINQ)
    or a
    jr nz,_HFI_INQ_OK
    ld ix,INQ_BUF
    call SCSI_INQUIRY
    call c,_HFI_BLANKINQ
_HFI_INQ_OK:
    ; capacity: only needed if the BOC phase did not get it - or if the
    ; TUR_WAIT above heard 28h (v3.3.2: NOTE_CHANGE dropped F_CAPOK; the
    ; disc measured by the BOC phase may not be the one that is ready now).
    ; F_CAPOK=1 here <=> BOCCAP=1 and no 28h since.
    call MY_GWORK
    bit F_CAPOK,(ix+0)
    jr nz,_HFI_OK2
    ld a,(DISC_BAD)              ; v3.3.6: known unusable: code 6 at once
    or a
    jr nz,_HFI_NOCAP
    ld ix,CAP_BUF
    call SCSI_READ_CAPACITY
    jr nc,_HFI_CAP_OK
    call TUR_WAIT                ; one more round of patience, then retry
    call _HFI_ABORTED
    ret c
    ld a,(DISC_BAD)              ; v3.3.6: ...unless the drive just said it
    or a                         ;  cannot use the disc
    jr nz,_HFI_NOCAP
    ld ix,CAP_BUF
    call SCSI_READ_CAPACITY
    jr nc,_HFI_CAP_OK
_HFI_NOCAP:
    call BUDGET_NORMAL
    ; the device is alive but the medium is not readable (or absent):
    ; keep the LUN visible so Nextor maps a drive letter and DEV_STATUS
    ; can pick the disc up when it appears.
    call MY_GWORK
    set F_READY,(ix+0)
    set F_CHANGED,(ix+0)
    ld a,6
    scf
    ret
_HFI_CAP_OK:
    call RECOMPUTE_TOTALS        ; validates 2048 B/sector, fills TOTAL/MB16
    jr nc,_HFI_OK2
    call BUDGET_NORMAL
    ld a,7                       ; medium exists but is not 2048 B/sector
    scf
    ret
_HFI_OK2:
    call BUDGET_NORMAL
_HFI_OK:
    call MY_GWORK
    set F_READY,(ix+0)
    set F_CHANGED,(ix+0)         ; a (re)appeared device counts as a change
    xor a
    ret

; _HFI_ABORTED - v3.3.6: Cy=1 with A=8 (and the normal budget back) if the
; bring-up session was abandoned (ESC / time cap); else Cy=0. Corrupts AF.
_HFI_ABORTED:
    ld a,(WAKE_ABORT)
    or a
    ret z
    call BUDGET_NORMAL
    ld a,8
    scf
    ret

; _HFI_ATTACHED - v3.3.7: is a USB device attached? CH376 TEST_CONNECT; a
; "disconnected" (16h) is asked twice more, ~50 ms apart, before it is
; believed. This runs right after RESET_ALL + SET_USB_MODE: the chip has had
; no time at all to look at the bus lines. Trusting the first answer there
; usually works, but on our side a false "nothing there"
; would cost a hot-plugged unit its whole bring-up (code 3 fails at once in
; the hot-plug and one-shot sessions), and the two extra looks cost ~0.1 s
; on an empty bus only - less than the two bus resets + DISK_CONNECT +
; enumeration an empty bus went through until v3.3.6.
; Out: Cy=0 something is attached / Cy=1 nothing (or TEST_CONNECT never
; answered). Corrupts AF, BC, D.
_HFI_ATTACHED:
    ld d,3
_HFA_LOOK:
    call CH_TEST_CONNECT         ; A = 15h/18h attached, 16h nothing; Cy=1:
    ret c                        ;  no answer at all (as before: code 3)
    cp CH_ST_INT_DISCONNECT
    jr z,_HFA_NONE
    or a                         ; Cy=0 (15h < 16h left Cy=1 after the cp)
    ret
_HFA_NONE:
    dec d
    scf
    ret z                        ; three "disconnected" in a row: Cy=1
    ld bc,500                    ; ~50 ms (CH_DELAY keeps DE)
    call CH_DELAY
    jr _HFA_LOOK

; _HFI_BLANKINQ - INQ_BUF = 36 spaces (reads as a direct-access device that
; is not a walkman: IS_OPTICAL / IS_HIMD both answer "no"). Corrupts B, HL.
_HFI_BLANKINQ:
    ld hl,INQ_BUF
    ld b,36
_HFI_BLANK:
    ld (hl)," "
    inc hl
    djnz _HFI_BLANK
    ret

; ==========================================================================
; RECOMPUTE_TOTALS - from a fresh CAP_BUF (READ CAPACITY, big-endian):
; verify block size == 2048, compute TOTAL_SEC = (lastLBA+1)*4 (little-
; endian) and MB16 = physical blocks / 512. Sets/clears F_CAPOK.
; Output: Cy=1 if the block size is not 2048. Corrupts everything.
; ==========================================================================
RECOMPUTE_TOTALS:
    ld a,(CAP_BUF+4)
    or a
    jr nz,_RT_BAD
    ld a,(CAP_BUF+5)
    or a
    jr nz,_RT_BAD
    ld a,(CAP_BUF+6)
    cp 08h
    jr nz,_RT_ALT
    ld a,(CAP_BUF+7)
    or a
    jr z,_RT_OK
    jr _RT_BAD
_RT_ALT:
    ; Some CD drives report the raw sector size (2340/2352) or 0 for a data
    ; disc while READ(10) still returns 2048-byte user data - Linux' sr
    ; driver treats all three as 2048 for the same reason.
    ld c,a                       ; C = high byte, A = high byte
    ld a,(CAP_BUF+7)
    or c
    jr z,_RT_OK                  ; 0
    ld a,c
    cp 09h
    jr nz,_RT_BAD
    ld a,(CAP_BUF+7)
    cp 24h                       ; 0924h = 2340
    jr z,_RT_OK
    cp 30h                       ; 0930h = 2352
    jr nz,_RT_BAD
_RT_OK:
    ; DE:HL = last LBA (convert from big-endian), then +1 = physical blocks
    ld a,(CAP_BUF+3)
    ld l,a
    ld a,(CAP_BUF+2)
    ld h,a
    ld a,(CAP_BUF+1)
    ld e,a
    ld a,(CAP_BUF+0)
    ld d,a
    inc hl
    ld a,h
    or l
    jr nz,_RT_NC
    inc de
_RT_NC:
    ; MB = blocks/512 (2048-byte blocks) = (E:H) >> 1 (D=0 for any Hi-MD)
    ld a,h
    ld c,a
    ld a,e
    ld b,a
    srl b
    rr c
    ld (MB16),bc
    ; TOTAL_SEC = blocks * 4, stored little-endian
    add hl,hl
    rl e
    rl d
    add hl,hl
    rl e
    rl d
    ld a,l
    ld (TOTAL_SEC+0),a
    ld a,h
    ld (TOTAL_SEC+1),a
    ld a,e
    ld (TOTAL_SEC+2),a
    ld a,d
    ld (TOTAL_SEC+3),a
    call MY_GWORK
    set F_CAPOK,(ix+0)
    or a
    ret
_RT_BAD:
    call MY_GWORK
    res F_CAPOK,(ix+0)
    scf
    ret

; ==========================================================================
; TUR_WAIT - TEST UNIT READY loop: up to 40 tries, REQUEST SENSE after each
; failure (clears the device's error condition), ~0.5 s pause in between.
; v3.3.2: ASC 28h ("medium may have changed", 06/28/00) is NOT "still warming
; up": it calls NOTE_CHANGE (cache/ISO mount/capacity dropped, F_CHANGED and
; CHG_SEEN set) and keeps waiting - the unit is talking. Hardware 2026-09-24
; (UJ8B0 DVD, disc swapped with the drive's button, FILES at once): 02/04/01
; x18, then ONE 06/28/00, then ready; v3.3.1 swallowed that 28h and DEV_STATUS
; said "unchanged" -> the old disc's mount on the new one.
; v3.3.5: EVERY failed TEST UNIT READY sets VFY_PEND - the same drive with a
; scratched CD (hardware 2026-09-25) went 02/04/01 -> 03/10/00 -> ready and
; never sent a 28h at all: the only safe reading of a not-ready phase is "the
; disc may be another one" until VERIFY_ID proves otherwise.
; v3.3.6: a CD/DVD drive answering MEDIUM ERROR (03) or HARDWARE ERROR (04)
; is not warming up: it cannot use its disc (hardware 2026-09-26: 04/09/02,
; focus servo failure, for ever). Like 3Ah, that ends the wait at once
; (DISC_BAD = 1, "D unusable"); the walkman keeps waiting as before. A
; REQUEST SENSE that fails gets RQS_RETRY once per wait (a CD/DVD drive busy
; retrying its focus answers nothing for seconds: resync, then ask again)
; before it counts as a transport strike. Every round, and every step of the
; pause, goes through WAIT_TICK: inside a bring-up session ESC and the time
; cap end the wait.
; Output: Cy=0 unit ready, Cy=1 still not ready. Corrupts everything.
; ==========================================================================
TUR_WAIT:
    ld b,40                      ; ~20 s: a fully stopped Hi-MD needs to
                                 ;  focus + read the TOC (v1.3 hardware:
                                 ;  ~5 s was not enough after auto-stop)
    ld a,(WAKE_ACTIVE)
    or a
    jr z,_TW_START               ; normal operation: full patience
    ld a,(WAKE_ABORT)
    or a
    jr nz,_TW_ABORT              ; ESC already seen: stop stalling
    ld a,(WAKE_FAST)
    or a
    jr z,_TW_START
    ld b,8                       ; window retry: the first attempt already
                                 ;  paid the full spin-up wait
_TW_START:
    ld c,0                       ; C = consecutive transport failures
_TW_LOOP:
    push bc
    ; while a bring-up session is active, ESC must work INSIDE the wait too
    ; (v2.2 hardware: a wedged walkman kept us here for many minutes with
    ; the keyboard dead); v3.3.6: also inside every command (WAIT_TICK)
    call WAIT_TICK
    jr c,_TW_FAIL
    call SCSI_TEST_UNIT_READY
    jr nc,_TW_OK
    ld a,1
    ld (VFY_PEND),a              ; v3.3.5: not ready = identity to re-prove
    ld ix,SENSE_BUF
    call SCSI_REQUEST_SENSE      ; also clears the device error condition
    call LOG_RQS                 ; CALL DREAM LOG (keeps all regs and flags)
    db 'W'
    jr nc,_TW_SENSE
    pop bc
    push bc
    inc c
    dec c
    jr nz,_TW_STRIKE             ; (one resync per run of failures)
    call RQS_RETRY               ; v3.3.6: CD/DVD - resync, ask once more
    jr c,_TW_STRIKE              ; sense unreadable: transport strike
_TW_SENSE:
    ld a,(SENSE_BUF+12)          ; ASC
    cp 3Ah
    jr z,_TW_FAIL                ; no medium: waiting cannot help, and
                                 ;  discless boots must stay fast
    call CHK_UNUSABLE            ; v3.3.6: a CD/DVD drive that cannot use
    jr z,_TW_FAIL                ;  its disc (03/04): waiting cannot help
    ld a,(SENSE_BUF+12)
    cp 28h
    call z,NOTE_CHANGE           ; a disc change: never swallow it (corrupts
                                 ;  AF, AF', IX only; BC is on the stack)
    pop bc
    ld c,0                       ; device talking: genuinely warming up
    push bc
    jr _TW_NEXT
_TW_STRIKE:
    ; TUR failed AND the device cannot even answer REQUEST SENSE: it is
    ; not spinning up, it is gone/wedged. Three in a row = stop burning
    ; rounds (each one costs two full mechanical-budget timeouts) and let
    ; the caller re-init from scratch with a fresh bus reset.
    pop bc
    inc c
    push bc
    ld a,c
    cp 3
    jr nc,_TW_FAIL
_TW_NEXT:
    ld b,4
    call WAIT_PAUSE              ; ~0.5 s (cut short by ESC / time cap)
    pop bc
    jr c,_TW_ABORT
    djnz _TW_LOOP
    scf
    ret
_TW_FAIL:
    pop bc
_TW_ABORT:
    scf
    ret
_TW_OK:
    pop bc
    xor a
    ld (DISC_BAD),a              ; v3.3.6: the unit is ready: it can use it
    ret                          ; Cy=0

; ==========================================================================
; CHK_UNUSABLE (v3.3.6) - after a successful REQUEST SENSE: Z=1 if a CD/DVD
; drive says it cannot use the disc it holds - sense key 03 (MEDIUM ERROR:
; 03/10/00 lead-in/TOC unreadable...) or 04 (HARDWARE ERROR: 04/09/02 focus
; servo failure on a badly scratched CD, hardware 2026-09-26). The drive is
; present and talking: this is neither a dead transport nor a reason to
; wait - it retries by itself, for minutes, whatever we do. Sets DISC_BAD
; (and logs "D unusable" the first time). The walkman never matches: its
; waits stay as they were (a MiniDisc cannot get scratched; a data read error
; is CLASSIFY_FAIL's business, not this).
; Out: Z=1 unusable, Z=0 not. Corrupts AF.
; ==========================================================================
CHK_UNUSABLE:
    call IS_OPTICAL
    ret nz                       ; not a CD/DVD drive (Z=0)
    ld a,(SENSE_BUF+2)
    and 0Fh
    sub 3
    cp 2
    jr c,_CU_YES                 ; key 03 or 04
    or 1                         ; Z=0
    ret
_CU_YES:
    ld a,(DISC_BAD)
    or a
    jr nz,_CU_Z                  ; already known: log it once
    inc a
    ld (DISC_BAD),a
    call LOG_EVT                 ; CALL DREAM LOG "D unusable"
    db 'D'+80h,LEV_BADDISC
_CU_Z:
    xor a                        ; Z=1
    ret

; ==========================================================================
; RQS_RETRY (v3.3.6) - a REQUEST SENSE has just failed right after a failed
; command. The walkman: nothing is tried (Cy=1 at once: the proven "transport
; died" path follows - bus reset + full bring-up). A CD/DVD drive: hardware
; 2026-09-26 (UJ8B0 behind an Initio bridge, a scratched CD): while the drive
; retries its focus it answers nothing for seconds; our wait for the failed
; command gave up first, so the CH376 is still NAK-retrying that token (deaf
; to anything else until told) and the bridge may still hold the command's
; CSW. v3.3.5 called that a dead transport ("HIMD DS:02") and re-initialised
; into the 15-minute window. Now, before anything is declared dead:
;   1. ABORT_NAK (the chip listens again) and ~1 s for the drive to breathe;
;   2. Bulk-Only Reset Recovery (USB MSC BOT 5.3.4, what Linux does on a
;      timeout): Bulk-Only Mass Storage Reset on EP0 + CLEAR_FEATURE(HALT) on
;      both bulk pipes (toggles back to DATA0). This is also the liveness
;      check: a unit that does not answer EP0 at its address is gone (Cy=1);
;      a STALL there (request not supported) still proves it is present;
;   3. REQUEST SENSE again, with the mechanical budget (~10 s per packet).
; Out: Cy=0 SENSE_BUF fresh (logged "Q kk/aa/qq") / Cy=1 dead (or the
; bring-up session was abandoned meanwhile). The budget on entry is restored.
; Corrupts everything.
; ==========================================================================
RQS_RETRY:
    call IS_OPTICAL
    scf
    ret nz                       ; the walkman: the proven path
    ld a,CH_CMD_ABORT_NAK
    out (CH_COMMAND_PORT),a
    ld b,8
    call WAIT_PAUSE              ; ~1 s (cut short by ESC / time cap)
    ret c
    call CH_CHECK_INT_IS_ACTIVE
    call z,CH_GET_STATUS         ; drop the aborted token's late result
    ld a,(CH_WAIT_MULT)
    push af                      ; the budget on entry
    call BUDGET_MECH
    ld hl,_RQ_BOTRESET
    ld de,USB_SETUP_BUF
    ld bc,8
    ldir                         ; (setup packets are patched in RAM)
    ld a,(USB_IFACE_NUM)
    ld (USB_SETUP_BUF+4),a       ; wIndex = the mass-storage interface
    ld hl,USB_SETUP_BUF
    ld de,USB_DESC_BUF           ; (no data stage: wLength = 0)
    ld a,(USB_EP0_SIZE)
    ld b,a
    ld a,(USB_DEV_ADDR)
    call HW_CONTROL_TRANSFER     ; A = USB error code
    or a
    jr z,_RQ_ALIVE
    cp USB_ERR_STALL             ; refused: present all the same
    scf
    jr nz,_RQ_OUT                ; no answer on EP0: the unit is gone
_RQ_ALIVE:
    ld c,80h
    call SCSI_CLEAR_HALT_Q       ; bulk IN: unhalted, DATA0
    ld c,0
    call SCSI_CLEAR_HALT_Q       ; bulk OUT: the same
    ld ix,SENSE_BUF
    call SCSI_REQUEST_SENSE
    call LOG_RQS                 ; CALL DREAM LOG "Q kk/aa/qq" / "Q no sense"
    db 'Q'
_RQ_OUT:
    pop bc                       ; B = the multiplier on entry
    push af                      ; the verdict (Cy)
    ld a,b
    dec a
    jr nz,_RQ_MECH
    call BUDGET_NORMAL           ; it was the normal budget
    jr _RQ_RET
_RQ_MECH:
    ld a,b
    ld (CH_WAIT_MULT),a          ; a mechanical one: NAK-forever stays
_RQ_RET:
    pop af
    ret
_RQ_BOTRESET: db 21h,0FFh,0,0,0,0,0,0 ; Bulk-Only Mass Storage Reset (class,
                                      ;  interface: wIndex patched in RAM)

; ==========================================================================
; DEV_RW - the central routine.
;  In:  Cy=0 read / Cy=1 write, A=device (1), B=sectors, C=LUN (1),
;       HL=destination, DE=address of the 4-byte logical sector number (LE).
;  Out: A=error (0=OK), B=sectors actually transferred on error.
; ==========================================================================
DEV_RW:
    push af
    ld a,c
    dec a
    jp nz,_RW_BADDEV
    pop af
    push af
    dec a
    jp nz,_RW_BADDEV
    pop af
    ld a,0                       ; (keep the caller's flags intact)
    adc a,a                      ; A = Cy: 0=read 1=write
    ld c,a                       ; C = op (LUN already validated away)
    ld a,b
    or a
    jr nz,_RW_HAVECNT
    xor a                        ; zero sectors: trivially OK
    ret
_RW_HAVECNT:
    ; Stash the inputs BEFORE mapping our segment: HL/DE may point into
    ; page 2, which is about to be switched away.
    push bc                      ; B = count, C = op
    push hl                      ; destination
    ex de,hl
    ld e,(hl)                    ; 32-bit logical sector number, little-endian
    inc hl
    ld d,(hl)
    inc hl
    ld c,(hl)
    inc hl
    ld b,(hl)                    ; B:C:D:E = byte3:byte2:byte1:byte0
    push bc                      ; high word
    push de                      ; low word
    call ENTER_SEG
    jr nc,_RW_SEGOK
    pop af
    pop af
    pop af
    pop af
    ld a,NX_ENRDY
    ld b,0
    ret
_RW_SEGOK:
    pop hl
    ld (SECNUM),hl               ; L=byte0 H=byte1
    pop hl
    ld (SECNUM+2),hl             ; L=byte2 H=byte3
    pop hl
    ld (RWDEST_CUR),hl
    pop bc
    ld a,b
    ld (COUNT),a
    ld a,c
    ld (RW_ISWRITE),a
    xor a
    ld (DONE),a
    ld (INIT_FAIL),a             ; assume SCSI-level until bring-up says else
    ; device usable? (first access after boot arrives here with the segment
    ; freshly allocated but the USB device untouched: bring it up now)
    call MY_GWORK
    bit F_READY,(ix+0)
    jr nz,_RW_READY
    call HW_INIT_PATIENT         ; patient at boot: walkman may be booting
    ld (INIT_FAIL),a             ; 0 = OK, 1..7 = bring-up failure code
    call MY_GWORK
    bit F_READY,(ix+0)
    ld a,NX_ENRDY
    jp z,_RW_ERR
    xor a
    ld (INIT_FAIL),a             ; device usable: later errors are SCSI-level
_RW_READY:
    ; v3.3.2: a disc change noted by the driver (NOTE_CHANGE: 28h, 3Ah mid-
    ; command, CALL DREAM...) that DEV_STATUS has not reported yet: this
    ; request is meant for the OLD disc - never serve it on the new one.
    ; Emulator test modelled on the hardware: after CLASSIFY_FAIL
    ; failed a write for that reason, Nextor 2.1.4 re-issued the same write
    ; at once, without any DEV_STATUS, and v3.3.2-rc served it on the new
    ; MiniDisc. Quiet "not ready" (no RW_DIAG line); the next DEV_STATUS
    ; reports the change (2) and lifts the guard.
    ld a,(CHG_GUARD)
    or a
    jp nz,_RW_UNREP
    call BUDGET_MECH             ; MiniDisc spin-up/seek budget for the media
    ; v3.3.5: the unit went through a not-ready phase (or a re-init) since
    ; the disc was last known and no DEV_STATUS verified it since (Nextor
    ; may even read sector 0 right after a "3", or re-issue a failed
    ; request without asking): the disc proves it is the one this request is
    ; meant for BEFORE anything is served or probed. Another disc -> quiet
    ; "not ready" (NOTE_CHANGE raised CHG_GUARD: DEV_STATUS reports it);
    ; unreadable identity -> "not ready" + "HIMD DS:03" (VFY_PEND stays; the
    ; DOS Retry goes through DEV_STATUS, which waits for the unit first).
    ld a,(VFY_PEND)
    or a
    jr z,_RW_VOK
    ld hl,BUF2K
    call VERIFY_ID               ; Z=1 same disc (or none known yet)
    jr z,_RW_VOK
    push af                      ; (BUDGET_NORMAL corrupts A: the verdict)
    call BUDGET_NORMAL
    pop af
    dec a
    jp z,_RW_UNREP               ; another disc: quiet (like CHG_GUARD)
    ld e,3
    call DS_DIAG                 ; "HIMD DS:03 S:kk/aa/qq": identity unreadable
    jp _RW_UNREP
_RW_VOK:
    ; v3.3: the first access to a medium decides how it is served (Sony/FAT
    ; as always, or an ISO9660 disc as a synthetic FAT16 volume)
    ld a,(ISO_STATE)
    or a
    jr nz,_RW_PROBED
    call ISO_PROBE
    jp c,_RW_ERR
_RW_PROBED:
    ld a,(ISO_STATE)
    cp 2
    jp z,ISO_RW                  ; ISO mode: its own read loop, no writes
    ld a,(RW_ISWRITE)
    or a
    jr z,_RW_LOOP
    call IS_OPTICAL
    jp nz,_RW_WLOOP
    ; CD/DVD: read-only medium. Refuse before any WRITE(10) reaches the
    ; drive, and quietly (no RW_DIAG line): Nextor already reports it.
    call BUDGET_NORMAL
    call EXIT_SEG
    ld a,NX_EWPROT
    ld b,0
    ret
_RW_LOOP:
    ld a,(COUNT)
    or a
    jp z,_RW_OK
    ld a,(SECNUM)
    and 3
    jr nz,_RW_SINGLE
    ld a,(COUNT)
    cp 4
    jr c,_RW_SINGLE
    ; physical block 0 may need BPB translation (Sony-formatted medium):
    ; always serve it through the buffered path
    ld a,(SECNUM)
    ld hl,SECNUM+1
    or (hl)
    inc hl
    or (hl)
    inc hl
    or (hl)
    jr z,_RW_SINGLE              ; SECNUM==0 -> block 0
    ; ---- aligned fast path: whole physical blocks straight to Nextor ----
    ld a,(COUNT)
    srl a
    srl a                        ; count/4 physical blocks available
    cp 9
    jr c,_RW_NBLK_OK
    ld a,8                       ; cap: 8 blocks = 16 KB per READ(10)
_RW_NBLK_OK:
    ld c,a                       ; C = nblk
    ld a,(RWDEST_CUR+1)
    cp 80h
    jr c,_RW_FAST                ; destination in page 0: OK
    cp 0C0h
    jr c,_RW_SINGLE              ; destination in page 2: buffered path
_RW_FAST:
    call CLAMP_NBLK              ; SCSI fills the range while OUR segment
    jp z,_RW_SINGLE              ;  sits in page 2: never spill into it
    call SECNUM_TO_PHYS          ; preserves BC
    ld a,c
    ld (RW_NBLK),a
    ld hl,(RWDEST_CUR)
    ld (RW_DEST),hl
    call READ_PHYS_RETRY
    jp c,_RW_ERR
    ld a,(RW_NBLK)
    add a,a
    add a,a                      ; logical sectors = nblk*4
    call ADVANCE_SECTORS
    ld a,(RW_NBLK)
    add a,a
    add a,a
    add a,a                      ; nblk*2048 in high-byte units (nblk*8)
    ld b,a
    ld hl,(RWDEST_CUR)
    ld a,h
    add a,b
    ld h,a
    ld (RWDEST_CUR),hl
    jp _RW_LOOP
_RW_SINGLE:
    ; ---- one logical sector through the 2048-byte cache ----
    call SECNUM_TO_PHYS
    call FETCH_CACHED
    jp c,_RW_ERR
_RW_HIT:
    ; logical sector 0 is served through TRANS_BUF: a Sony-formatted
    ; medium (2048-byte-sector FAT) gets its BPB translated for Nextor
    ld hl,(SECNUM)
    ld a,h
    or l
    jr nz,_RW_PLAIN
    ld hl,(SECNUM+2)
    ld a,h
    or l
    jr nz,_RW_PLAIN
    call SERVE_SECTOR0
    ld hl,TRANS_BUF
    jr _RW_COPYOUT
_RW_PLAIN:
    ; copy BUF2K + (SECNUM&3)*512 -> destination
    ld a,(SECNUM)
    and 3
    add a,a                      ; *2 -> offset in 256-byte pages
    add a,80h                    ; + BUF2K high byte (8000h)
    ld h,a
    ld l,0
_RW_COPYOUT:
    ld de,(RWDEST_CUR)
    ld bc,512
    call COPY_OUT
    ld a,1
    call ADVANCE_SECTORS
    ld hl,(RWDEST_CUR)
    inc h
    inc h                        ; += 512
    ld (RWDEST_CUR),hl
    jp _RW_LOOP
_RW_OK:
    call BUDGET_NORMAL
    call EXIT_SEG
    xor a
    ret
_RW_ERR:                         ; A = Nextor error code, segment mapped
    ld c,a
    call BUDGET_NORMAL
    ld a,(DONE)
    ld b,a
    push bc
    call RW_DIAG                 ; on-screen diagnostic line (needs the
    call EXIT_SEG                ;  segment still mapped to read SENSE_BUF)
    pop bc
    ld a,c
    ret
_RW_BADDEV:
    pop af
    ld a,NX_EIDEVL
    ld b,0
    ret
_RW_UNREP:                       ; segment mapped, budget still normal
    call EXIT_SEG
    ld a,NX_ENRDY
    ld b,0
    ret

; --------------------------------------------------------------------------
; WRITE loop (Fase 3). Write-through: every path ends in a WRITE(10) before
; moving on; no dirty state survives the call. Three sub-paths per pass:
;   * aligned + >=4 sectors + source outside page 2: direct multi-block
;     WRITE(10) from the caller's buffer (up to 8 blocks = 16 KB), cache
;     invalidated (the range may overlap the cached block).
;   * aligned + >=4 sectors + source in page 2: stage ONE whole block
;     through BUF2K (COPY_IN, no pre-read needed) and commit it.
;   * anything else: read-modify-write of one logical sector through BUF2K.
; CACHE_OK drops to 0 the moment BUF2K stops mirroring the disc and only
; returns to 1 after a successful commit: an error can never leave a stale
; cache behind.
; --------------------------------------------------------------------------
_RW_WLOOP:
    ld a,(COUNT)
    or a
    jp z,_RW_OK
    ld a,(SECNUM)
    and 3
    jp nz,_RW_WSINGLE
    ld a,(COUNT)
    cp 4
    jp c,_RW_WSINGLE
    ; physical block 0 holds the (possibly Sony) boot sector: always route
    ; it through the buffered path, which knows how to protect it
    ld a,(SECNUM)
    ld hl,SECNUM+1
    or (hl)
    inc hl
    or (hl)
    inc hl
    or (hl)
    jp z,_RW_WSINGLE             ; SECNUM==0 -> block 0
    ld a,(RWDEST_CUR+1)
    cp 80h
    jr c,_RW_WFAST               ; source in page 0: direct WRITE(10)
    cp 0C0h
    jr nc,_RW_WFAST              ; source in page 3: direct WRITE(10)
    ; ---- aligned, source hidden in page 2: stage one block via BUF2K ----
    call SECNUM_TO_PHYS
    xor a
    ld (CACHE_OK),a              ; BUF2K stops mirroring the disc now
    ld de,(RWDEST_CUR)           ; DE = caller's source
    ld hl,BUF2K
    ld bc,2048
    call COPY_IN
    call _RW_WCOMMIT
    jp c,_RW_ERR
    ld a,4
    call ADVANCE_SECTORS
    ld hl,(RWDEST_CUR)
    ld a,h
    add a,8                      ; += 2048
    ld h,a
    ld (RWDEST_CUR),hl
    jp _RW_WLOOP
_RW_WFAST:
    ; ---- aligned fast path: whole physical blocks straight from caller ----
    ld a,(COUNT)
    srl a
    srl a                        ; count/4 physical blocks available
    cp 9
    jr c,_RW_WNBLK_OK
    ld a,8                       ; cap: 8 blocks = 16 KB per WRITE(10)
_RW_WNBLK_OK:
    ld c,a
    call CLAMP_NBLK              ; SCSI reads the source while OUR segment
    jr z,_RW_WSINGLE             ;  sits in page 2: never read from it
    call SECNUM_TO_PHYS          ; preserves BC
    ld a,c
    ld (RW_NBLK),a
    ld hl,(RWDEST_CUR)
    ld (RW_DEST),hl
    xor a
    ld (CACHE_OK),a              ; written range may overlap the cached block
    call WRITE_PHYS_RETRY
    jp c,_RW_ERR
    ld a,(RW_NBLK)
    add a,a
    add a,a                      ; logical sectors = nblk*4
    call ADVANCE_SECTORS
    ld a,(RW_NBLK)
    add a,a
    add a,a
    add a,a                      ; nblk*2048 in high-byte units (nblk*8)
    ld b,a
    ld hl,(RWDEST_CUR)
    ld a,h
    add a,b
    ld h,a
    ld (RWDEST_CUR),hl
    jp _RW_WLOOP
_RW_WSINGLE:
    ; ---- read-modify-write of one logical sector through BUF2K ----
    call SECNUM_TO_PHYS
    call FETCH_CACHED            ; the block we are about to partially overwrite
    jp c,_RW_ERR
_RW_WHAVE:
    ; Sony-formatted medium: physical block 0 holds the real 2048-byte BPB
    ; that the walkman and the Mac rely on - MSX writes must never touch it
    ld hl,PHYS_LBA_BE
    ld a,(hl)
    inc hl
    or (hl)
    inc hl
    or (hl)
    inc hl
    or (hl)
    jr nz,_RW_WNOT0
    ld a,(FMT_ACTIVE)            ; CALL HIMD FORMAT bypasses the guard while it
    or a                        ;  lays down the new boot sector (it writes via
    jr nz,_RW_WNOT0             ;  the SCSI layer, so this is belt-and-braces)
    call CHK_SONY_BOOT           ; on the PRISTINE cached block
    jr nz,_RW_WNOT0
    ; v3.3.7: Nextor rewriting logical sector 0 only to set/clear its dirty
    ; disk flag (every DEL/KILL/RMDIR on a Sony disc: until v3.3.6 they all
    ; failed with "Write protected") is accepted WITHOUT touching the disc;
    ; any other write there (FDISK, EMUFILE /P...) is refused as always.
    call SONY_SEC0_WRITE
    ld a,NX_EWPROT
    jp c,_RW_ERR
    ld a,1
    call ADVANCE_SECTORS
    ld hl,(RWDEST_CUR)
    inc h
    inc h                        ; += 512
    ld (RWDEST_CUR),hl
    jp _RW_WLOOP
_RW_WNOT0:
    xor a
    ld (CACHE_OK),a              ; BUF2K stops mirroring the disc now
    ; caller's 512 bytes -> BUF2K + (SECNUM&3)*512
    ld a,(SECNUM)
    and 3
    add a,a                      ; *2 -> offset in 256-byte pages
    add a,80h                    ; + BUF2K high byte (8000h)
    ld h,a
    ld l,0
    ld de,(RWDEST_CUR)           ; DE = caller's source
    ld bc,512
    call COPY_IN
    call _RW_WCOMMIT
    jp c,_RW_ERR
    ld a,1
    call ADVANCE_SECTORS
    ld hl,(RWDEST_CUR)
    inc h
    inc h                        ; += 512
    ld (RWDEST_CUR),hl
    jp _RW_WLOOP

; Commit BUF2K (one whole physical block) to PHYS_LBA_BE and mark the cache
; as mirroring that block again. Cy=1 + A=error on failure (cache stays
; invalid: CACHE_OK was cleared before BUF2K was touched).
; v3.3.5: block 0 is the only way the MSX changes logical sector 0 (an MBR
; medium: EMUFILE /P, FDISK...): its new signature becomes the disc's
; identity (MID_SIG), or the next VERIFY_ID would take it for another disc.
_RW_WCOMMIT:
    ld a,1
    ld (RW_NBLK),a
    ld hl,BUF2K
    ld (RW_DEST),hl
    call WRITE_PHYS_RETRY
    ret c
    ld hl,PHYS_LBA_BE
    ld de,CACHED_PHYS
    ld bc,4
    ldir
    ld a,1
    ld (CACHE_OK),a
    ld hl,PHYS_LBA_BE
    ld a,(hl)
    inc hl
    or (hl)
    inc hl
    or (hl)
    inc hl
    or (hl)
    ret nz                       ; not block 0 (or: Cy=0 - success)
    ld hl,BUF2K
    call SIG0                    ; VFY_SIG = signature of logical sector 0
    ld hl,VFY_SIG
    ld de,MID_SIG
    ld bc,4
    ldir
    xor a                        ; Cy=0: success
    ret

; ==========================================================================
; FETCH_CACHED - make BUF2K hold physical block PHYS_LBA_BE: a hit costs
; nothing, a miss reads one block. Cy=1 + A = Nextor error on failure (the
; cache is then invalid). Corrupts everything.
; ==========================================================================
FETCH_CACHED:
    ld a,(CACHE_OK)
    or a
    jr z,_FC_MISS
    ld hl,PHYS_LBA_BE
    ld de,CACHED_PHYS
    ld b,4
_FC_CMP:
    ld a,(de)
    cp (hl)
    jr nz,_FC_MISS
    inc hl
    inc de
    djnz _FC_CMP
    ret                          ; hit (Cy=0: the last compare was equal)
_FC_MISS:
    xor a
    ld (CACHE_OK),a
    ld a,1
    ld (RW_NBLK),a
    ld hl,BUF2K
    ld (RW_DEST),hl
    call READ_PHYS_RETRY
    ret c
    ld hl,PHYS_LBA_BE
    ld de,CACHED_PHYS
    ld bc,4
    ldir
    ld a,1
    ld (CACHE_OK),a
    or a
    ret

; ==========================================================================
; CLAMP_NBLK - clamp C (physical block count) so that RWDEST_CUR + C*2048
; stays inside the buffer's own region (page 0 ends at 8000h, page 3 at
; 10000h). The fast paths hand the whole range to the SCSI layer while OUR
; segment sits in page 2: a transfer spilling into page 2 would trash
; BUF2K/WORKRAM (read) or send garbage to the disc (write). The per-sector
; buffered paths are immune (COPY_OUT/COPY_IN decide per byte).
; In:  C = wanted nblk (>=1); RWDEST_CUR high byte outside [80h,C0h).
; Out: C = safe nblk, Z=1 if not even one whole block fits.
; Preserves DE. Corrupts AF, B.
; ==========================================================================
CLAMP_NBLK:
    ld a,(RWDEST_CUR+1)
    cp 80h
    jr nc,_CN_P3
    ld b,a
    ld a,80h
    sub b                        ; 256-byte pages left before 8000h
    jr _CN_DIV
_CN_P3:
    ld b,a
    xor a
    sub b                        ; 256-byte pages left before 10000h (mod 256)
_CN_DIV:
    srl a
    srl a
    srl a                        ; /8 -> whole 2048-byte blocks that fit
    cp c
    jr nc,_CN_KEEP
    ld c,a                       ; clamp (possibly to zero)
_CN_KEEP:
    ld a,c
    or a                         ; Z=1 -> caller must use the buffered path
    ret

; ==========================================================================
; CHK_SONY_BOOT - Z=1 if BUF2K holds a Sony-format FAT boot sector (2048
; bytes/sector: how the walkman/Windows format Hi-MD discs, superfloppy
; layout). Checked on the PRISTINE cache: the cache never stores the
; translated view. Corrupts AF.
; ==========================================================================
CHK_SONY_BOOT:
    ld a,(BUF2K)
    cp 0EBh                      ; FAT boot sectors start with an x86 jump
    jr z,_CSB_BPS
    cp 0E9h
    ret nz
_CSB_BPS:
    ld a,(BUF2K+0Bh)
    or a                         ; bytes/sector low byte (2048 = 0800h)
    ret nz
    ld a,(BUF2K+0Ch)
    cp 08h
    ret

; ==========================================================================
; SERVE_SECTOR0 - build the caller's view of logical sector 0 in TRANS_BUF
; (Fase 4, "disco compartido"). Plain copy of BUF2K[0..511]; if the medium
; is Sony-formatted, rewrite the BPB so Nextor sees the SAME filesystem in
; 512-byte terms: only the sector-unit fields scale by 4 - FATs, directory
; entries and cluster chains are byte-identical in both views. The on-disc
; sector (and the cache) stay pristine: walkman and Mac keep their format.
; Requires: BUF2K caches physical block 0. Corrupts AF, BC, DE, HL.
; ==========================================================================
SERVE_SECTOR0:
    ld hl,BUF2K
    ld de,TRANS_BUF
    ld bc,512
    ldir
    call CHK_SONY_BOOT
    ret nz                       ; not Sony-formatted: serve as-is
    ld a,(TRANS_BUF+0Dh)
    cp 33
    ret nc                       ; spc>32 would translate past the FAT
                                 ;  limit of 128: serve as-is (Nextor will
                                 ;  reject the disc cleanly, never corrupt)
    ; bytes/sector: 2048 -> 512
    xor a
    ld (TRANS_BUF+0Bh),a
    ld a,2
    ld (TRANS_BUF+0Ch),a
    ; sectors/cluster x4 (Sony uses spc<=32, so the result fits in 128)
    ld a,(TRANS_BUF+0Dh)
    add a,a
    add a,a
    ld (TRANS_BUF+0Dh),a
    ; reserved sectors x4 (16-bit)
    ld hl,(TRANS_BUF+0Eh)
    add hl,hl
    add hl,hl
    ld (TRANS_BUF+0Eh),hl
    ; total sectors (16-bit field): x4 may overflow into the 32-bit field
    ld hl,(TRANS_BUF+13h)
    ld a,h
    or l
    jr z,_SS0_TOT32              ; zero: the 32-bit field is in use
    ld e,0                       ; E:HL = 24 bits are plenty (max 3FFFCh)
    add hl,hl
    rl e
    add hl,hl
    rl e
    ld a,e
    or a
    jr nz,_SS0_BIG
    ld (TRANS_BUF+13h),hl        ; still fits in 16 bits
    jr _SS0_FATSZ
_SS0_BIG:
    xor a
    ld (TRANS_BUF+13h),a
    ld (TRANS_BUF+14h),a
    ld (TRANS_BUF+20h),hl
    ld a,e
    ld (TRANS_BUF+22h),a
    xor a
    ld (TRANS_BUF+23h),a
    jr _SS0_FATSZ
_SS0_TOT32:
    ld hl,TRANS_BUF+20h          ; 32-bit total x4
    call _SS0_X4_32
_SS0_FATSZ:
    ; sectors per FAT x4 (16-bit)
    ld hl,(TRANS_BUF+16h)
    add hl,hl
    add hl,hl
    ld (TRANS_BUF+16h),hl
    ; hidden sectors x4 (32-bit; superfloppy: normally zero anyway)
    ld hl,TRANS_BUF+1Ch
    call _SS0_X4_32
    ; v3.3.7: Nextor's dirty disk flag as it last wrote it (SONY_SEC0_WRITE)
    ld a,(DIRTY0_ON)
    or a
    ret z
    ld a,(DIRTY0_VAL)
    ld (TRANS_BUF+25h),a
    ret

; ==========================================================================
; SONY_SEC0_WRITE (v3.3.7) - Nextor writes a logical sector of physical
; block 0 of a Sony-formatted disc (BUF2K caches that block, CHK_SONY_BOOT
; said yes). MSX-DOS 2 / Nextor mark a disc "dirty" before a delete frees
; clusters (FAT.MAC, DIRTY_DISK: byte 25h of the boot sector, the byte
; before the 29h extended signature; it keeps the last FAT copy untouched
; for UNDEL) and "clean" again (CLEAN_DISK) before the next allocation: the
; whole 512-byte sector it read, written back with that byte changed. The
; real 2048-byte boot block must stay byte-identical (walkman, Mac), so:
; logical sector 0 identical to what we serve (SERVE_SECTOR0) except byte
; 25h -> accepted, nothing written, the new value kept in DIRTY0_VAL and
; served from now on. Anything else (logical sectors 1-3, a new BPB, an
; MBR...) -> refused (.WPROT), as since v3.0.
; Out: Cy=0 accepted / Cy=1 refused. BUF2K's tail (600h..7FFh) is used as
; scratch: the cache is dropped (CACHE_OK=0). Corrupts AF, BC, DE, HL.
; ==========================================================================
SONY_SEC0_WRITE:
    ld a,(SECNUM)
    and 3
    scf
    ret nz                       ; sectors 1-3 of the boot block: refused
    call SERVE_SECTOR0           ; TRANS_BUF = what Nextor reads there now
    xor a
    ld (CACHE_OK),a              ; BUF2K+600h becomes scratch
    ld hl,BUF2K+600h
    ld de,(RWDEST_CUR)
    ld bc,512
    call COPY_IN                 ; the sector Nextor wants written
    ld hl,BUF2K+600h
    ld de,TRANS_BUF
    ld bc,512
_S0W_CMP:
    ld a,(de)
    cp (hl)
    jr z,_S0W_NEXT
    ld a,c                       ; offset = 512 - BC: 25h <=> BC = 01DBh
    cp 0DBh
    jr nz,_S0W_NO
    ld a,b
    dec a
    jr nz,_S0W_NO
_S0W_NEXT:
    inc hl
    inc de
    dec bc
    ld a,b
    or c
    jr nz,_S0W_CMP
    ld a,(BUF2K+600h+25h)
    ld (DIRTY0_VAL),a
    ld a,1
    ld (DIRTY0_ON),a
    or a                         ; Cy=0: accepted
    ret
_S0W_NO:
    scf
    ret

_SS0_X4_32:                      ; (HL) little-endian 32-bit *= 4
    push hl
    call _SS0_X2_32
    pop hl
_SS0_X2_32:                      ; (HL) little-endian 32-bit *= 2
    push hl
    ld b,4
    or a                         ; Cy=0
_SX2_LOOP:
    ld a,(hl)
    rla
    ld (hl),a
    inc hl
    djnz _SX2_LOOP
    pop hl
    ret

; ==========================================================================
; SECNUM_TO_PHYS - PHYS_LBA_BE (big-endian, for the CDB) = SECNUM >> 2.
; Preserves BC. Corrupts AF, DE, HL.
; ==========================================================================
SECNUM_TO_PHYS:
    ld hl,(SECNUM)               ; H:L = byte1:byte0
    ld de,(SECNUM+2)             ; D:E = byte3:byte2
    srl d
    rr e
    rr h
    rr l
    srl d
    rr e
    rr h
    rr l
    ld a,d
    ld (PHYS_LBA_BE+0),a
    ld a,e
    ld (PHYS_LBA_BE+1),a
    ld a,h
    ld (PHYS_LBA_BE+2),a
    ld a,l
    ld (PHYS_LBA_BE+3),a
    ret

; ==========================================================================
; ADVANCE_SECTORS - A = n: COUNT -= n, DONE += n, SECNUM += n (32-bit).
; Corrupts AF, C, HL.
; ==========================================================================
ADVANCE_SECTORS:
    ld c,a
    ld a,(COUNT)
    sub c
    ld (COUNT),a
    ld a,(DONE)
    add a,c
    ld (DONE),a
    ld a,(SECNUM)
    add a,c
    ld (SECNUM),a
    ret nc
    ld hl,SECNUM+1
    inc (hl)
    ret nz
    inc hl
    inc (hl)
    ret nz
    inc hl
    inc (hl)
    ret

; ==========================================================================
; RW_DIAG - one-line on-screen diagnostic for a FINAL DEV_RW error. The MSX
; screen is the only bug report we get from real hardware, so this line is
; the whole debugging channel:
;   "HIMD E:xx S:kk/aa/qq C:xx D:xx"  (SCSI-level failure)
;     E = Nextor error code, S = sense key/ASC/ASCQ of the last REQUEST
;     SENSE, C = last CH376 interrupt status, D = sectors OK before failing
;   "HIMD INIT:0n"                    (HW_FULL_INIT bring-up failure 1..7)
; In: C = Nextor error code, B = DONE. Our segment mapped, interrupts OFF
; (ENTER_SEG did DI - no EI here). Only prints in text mode (SCRMOD=0),
; writing directly to the VDP on row 23: no BIOS (page 0 is not the BIOS
; during DEV_RW), no RAM outside the mapped segment.
; Preserves BC. Corrupts AF, DE, HL.
; ==========================================================================
RW_DIAG:
    call _RD_SETUPCLR            ; v3.4: blank row 23 first
    ret c                        ; not a text screen: stay silent
    ; message body (VRAM address auto-increments on each data write)
    ld a,(INIT_FAIL)
    or a
    jr nz,_RD_INIT
    ld hl,_RD_S1                 ; "HIMD E:" (read)
    ld a,(RW_ISWRITE)
    or a
    jr z,_RD_OPSTR
    ld hl,_RD_S1W                ; "HIMD W:" (write - tells a screen report apart)
_RD_OPSTR:
    call _RD_PUTS
    ld a,c                       ; Nextor error code
    call _RD_PUTHEX
    ld hl,_RD_S2                 ; " S:"
    call _RD_PUTS
    call _RD_SENSE               ; "kk/aa/qq"
    ld hl,_RD_S3                 ; " C:"
    call _RD_PUTS
    ld a,(LAST_CH_STATUS)
    call _RD_PUTHEX
    ld hl,_RD_S4                 ; " D:"
    call _RD_PUTS
    ld a,b                       ; DONE
    jp _RD_PUTHEX
_RD_INIT:
    ld hl,_RD_SI                 ; "HIMD INIT:"
    call _RD_PUTS
    ld a,(INIT_FAIL)
    jp _RD_PUTHEX

; DS_DIAG - same on-screen channel for DEV_STATUS giving up on a device
; that WAS alive: "HIMD DS:0n S:kk/aa/qq". n=1 spin-up wait timed out,
; n=2 transport died (REQUEST SENSE itself failed; sense bytes are stale),
; n=3 (v3.3.5) the disc's identity could not be verified after a not-ready
; phase (VERIFY_ID: a READ CAPACITY / block read failed; S = why).
; n=4 (v3.3.6) the CD/DVD drive cannot use the disc it holds (MEDIUM or
; HARDWARE ERROR while waiting for it, S = the drive's words: 04/09/02 focus
; failure, 03/10/00 lead-in unreadable...): no waiting, "not available".
; In: E = reason code. Segment mapped, interrupts off. Corrupts AF, DE, HL.
DS_DIAG:
    push de                      ; _RD_SETUP corrupts DE, we need E after it
    call _RD_SETUPCLR            ; v3.4: blank row 23 first
    pop de
    ret c                        ; not a text screen: stay silent
    ld hl,_RD_SD                 ; "HIMD DS:"
    call _RD_PUTS
    ld a,e
    call _RD_PUTHEX
    ld hl,_RD_S2                 ; " S:"
    call _RD_PUTS
    jp _RD_SENSE                 ; NOT a fall-through: INIT_DIAG sits in between
                                 ;  (v1.4 bug: falling through printed
                                 ;  "HIMD INIT:00" over the DS line)
; INIT_DIAG - "HIMD INIT:0n" for a bring-up failure seen by DEV_STATUS
; (DEV_RW prints the same line itself via INIT_FAIL). In: A = code 1..8
; (v3.3.6: 08 = the bring-up was abandoned - ESC or its time cap).
; NOTE: fires on any boot where the connected USB device is not the
; walkman (e.g. INIT:07 = pendrive, sector size != 2048): harmless.
INIT_DIAG:
    ld e,a
    push de                      ; _RD_SETUP corrupts DE
    call _RD_SETUPCLR            ; v3.4: blank row 23 first
    pop de
    ret c                        ; not a text screen: stay silent
    ld hl,_RD_SI                 ; "HIMD INIT:"
    call _RD_PUTS
    ld a,e
    jp _RD_PUTHEX

_RD_SENSE:                       ; "kk/aa/qq" from the last REQUEST SENSE
    ld a,(SENSE_BUF+2)
    and 0Fh                      ; sense key
    call _RD_PUTHEX
    ld a,"/"
    call _RD_PUTC
    ld a,(SENSE_BUF+12)          ; ASC
    call _RD_PUTHEX
    ld a,"/"
    call _RD_PUTC
    ld a,(SENSE_BUF+13)          ; ASCQ
    jp _RD_PUTHEX

; _RD_SETUPCLR (v3.4) - _RD_SETUP after blanking the whole of row 23. The
; three diagnostic lines (RW_DIAG, DS_DIAG, INIT_DIAG) have different lengths
; and used to be written over each other: hardware 2026-10-03 showed
; "HIMD INIT:03:02/3A/00" = "HIMD INIT:03" painted over the tail of an older
; "HIMD DS:02 S:02/3A/00". Same contract as _RD_SETUP: Cy=1 not a text
; screen; corrupts AF, DE, HL; preserves BC (_HIP_CLEAR uses B for its loop).
; The wait line (_HIP_TICK) keeps plain _RD_SETUP: it repaints itself on
; every tick and is always the longest line.
_RD_SETUPCLR:
    push bc
    call _HIP_CLEAR              ; blank row 23 (returns at once if not text;
    pop bc                       ;  its Cy is not meaningful)
_RD_SETUP:                       ; screen check + VRAM address of row 23.
    ld a,(SCRMOD)                ; Out: Cy=1 not text mode (skip printing).
    or a                         ; Corrupts AF, DE, HL. Preserves BC.
    scf
    ret nz                       ; not a text screen
    ; VDP R14 (VRAM bank) = 0: SCREEN 0 tables live in the first 16K. On a
    ; TMS9918 (MSX1) this write aliases to R6 (sprite pattern base), which
    ; text mode ignores: harmless.
    xor a
    out (VDP_CTRL),a
    ld a,80h+14
    out (VDP_CTRL),a
    ; VRAM write address = NAMBAS + 23 * row-width
    ld hl,(NAMBAS)
    ld de,23*40                  ; TEXT1: 40-byte rows
    ld a,(LINLEN)
    cp 41
    jr c,_RD_ADDR
    ld de,23*80                  ; TEXT2 (WIDTH>40): 80-byte rows
_RD_ADDR:
    add hl,de
    ld a,l
    out (VDP_CTRL),a
    ld a,h
    and 3Fh
    or 40h                       ; bit 6 = VRAM write
    out (VDP_CTRL),a
    or a                         ; Cy=0: address set, ready for data writes
    ret

_RD_PUTHEX:                      ; A as two uppercase hex digits
    push af
    rrca
    rrca
    rrca
    rrca
    call _RD_PUTN
    pop af
_RD_PUTN:                        ; low nibble of A as one hex digit
    and 0Fh
    add a,"0"
    cp "9"+1
    jr c,_RD_PUTC
    add a,7                      ; 3Ah.. -> "A".."F"
_RD_PUTC:                        ; call/loop overhead >> VDP min access time
    out (VDP_DATA),a
    ret
_RD_PUTS:                        ; zero-terminated string at HL
    ld a,(hl)
    or a
    ret z
    inc hl
    call _RD_PUTC
    jr _RD_PUTS
_RD_S1: db "HIMD E:",0
_RD_S1W: db "HIMD W:",0
_RD_S2: db " S:",0
_RD_S3: db " C:",0
_RD_S4: db " D:",0
_RD_SI: db "HIMD INIT:",0
_RD_SD: db "HIMD DS:",0

; ==========================================================================
; READ_PHYS_RETRY / WRITE_PHYS_RETRY - READ(10)/WRITE(10) of RW_NBLK
; physical blocks at PHYS_LBA_BE from/to RW_DEST, with retries and full
; SCSI error handling (Sony rules). Shared body: only the SCSI opcode and
; the final error code differ.
; Requires: segment mapped, mechanical budget active.
; Output: Cy=0 OK - for a READ, EVERY byte of the RW_NBLK blocks arrived;
;         Cy=1 with A = Nextor error code. A failed multi-block READ(10) is
;         failed WHOLE (the caller does not advance DONE for any of it), so
;         no stale/zero bytes are ever reported as data.
; Corrupts everything.
; ==========================================================================
MULT_OPTREAD:   equ 40           ; ~51 s per USB token (see below)
SEEK_MAX:       equ 5            ; v3.4.1: positioning retries per request
SEEK_CAP:       equ 300          ; v3.4.1: ...none started after ~40 s
                                 ;  (WAIT_TICK slice ~0.13 s at 3.58 MHz)

READ_PHYS_RETRY:
    xor a                        ; XFER_OP = 0: READ10
    jr _XPR_SETOP
WRITE_PHYS_RETRY:
    ld a,1                       ; XFER_OP = 1: WRITE10
_XPR_SETOP:
    ld (XFER_OP),a
    ld a,3
    ld (RETRY),a
    ld a,SEEK_MAX
    ld (SEEK_LEFT),a             ; v3.4.1: positioning retries (_CF_SEEK) and
    ld hl,0                      ;  their clock: this request starts now
    ld (SEEK_TK),hl
    xor a
    ld (RECOVERED),a
_RPR_TRY:
    ld a,(RW_NBLK)
    ld c,a
    ld b,0                       ; BC = block count
    ld d,a
    sla d
    sla d
    sla d
    ld e,0                       ; DE = nblk * 2048 bytes
    ld hl,PHYS_LBA_BE
    ld ix,(RW_DEST)
    ld a,(XFER_OP)
    or a
    jr nz,_XPR_WRITE
    ; v3.3.3: a CD/DVD drive retries a damaged sector internally, often for
    ; many seconds, before it answers - NAKing the data IN token meanwhile
    ; (the CH376 keeps retrying it: NAK-forever budget). The mechanical
    ; budget gives ~10 s per token; after that the read looked like a dead
    ; transport (timeout -> REQUEST SENSE on a deaf chip -> bus reset + full
    ; re-init). An optical READ(10) now waits ~51 s per token, so the drive
    ; gets to report its own MEDIUM ERROR. The walkman keeps its budget (a
    ; MiniDisc cannot get scratched; a wedged walkman is caught as fast).
    ld a,(CH_WAIT_MULT)
    push af                      ; the budget on entry
    call IS_OPTICAL              ; (corrupts AF only)
    jr nz,_XPR_RD
    ld a,MULT_OPTREAD
    ld (CH_WAIT_MULT),a
_XPR_RD:
    call SCSI_READ10
    pop de                       ; D = the budget on entry (flags untouched)
    ld a,d
    ld (CH_WAIT_MULT),a
    jr c,_XPR_FAIL
    ; a "successful" READ must have delivered every byte: a short data
    ; stage leaves stale bytes in the buffer - never report them as data
    ld a,(RW_NBLK)
    add a,a
    add a,a
    add a,a                      ; nblk*2048 = (nblk*8) * 256
    ld hl,(_SCSI_DATA_LEN)       ; bytes received (SCSI_DO_CMD)
    cp h
    jr nz,_XPR_FAIL
    ld a,l
    or a
    jr nz,_XPR_FAIL
    ld a,(SEEK_LEFT)             ; complete. v3.4.1: after positioning retries
    cp SEEK_MAX                  ;  the log tells they paid off
    ret z                        ; none needed: Cy=0 (Z=1 -> Cy=0)
    or a                         ; Cy=0: "ok"
    call LOG_EVT                 ; CALL DREAM LOG "P seek ok" (keeps flags)
    db 'P'+80h,LEV_SEEK
    ret                          ; Cy=0: complete
_XPR_WRITE:
    call SCSI_WRITE10
    ret nc
_XPR_FAIL:
    call CLASSIFY_FAIL           ; Cy=1: final error in A / Cy=0: retry
    ret c
    ld a,(RETRY)
    dec a
    ld (RETRY),a
    jr nz,_RPR_TRY
    ; Retries exhausted: poison our device state so the NEXT access starts
    ; from a full re-init (HW_FULL_INIT) instead of trusting a walkman that
    ; just failed three straight commands (v1.2: second FILES never spun).
    xor a
    ld (CACHE_OK),a
    call MY_GWORK
    res F_READY,(ix+0)
    ld a,(XFER_OP)
    or a
    ld a,NX_EDISK                ; read: generic disk error
    jr z,_XPR_FINAL
    ld a,NX_EWRERR               ; write: write error
_XPR_FINAL:
    scf
    ret

; ==========================================================================
; CLASSIFY_FAIL - after a failed SCSI command: REQUEST SENSE (mandatory,
; clears the device error state) and decide.
; Output: Cy=1 final (A = Nextor error code) / Cy=0 worth retrying.
; ==========================================================================
CLASSIFY_FAIL:
    ld ix,SENSE_BUF
    call SCSI_REQUEST_SENSE
    call LOG_RQS                 ; CALL DREAM LOG (keeps all regs and flags)
    db 'F'
    call c,RQS_RETRY             ; v3.3.6: CD/DVD - resync, ask once more
    jp c,_CF_DEAD                ; even REQUEST SENSE died: transport is gone
    ld a,(SENSE_BUF+2)
    and 0Fh                      ; sense key
    cp 07h
    jp z,_CF_WPROT               ; DATA PROTECT: the disc tab is on
    cp 03h
    jr z,_CF_MEDIUM              ; MEDIUM ERROR: unreadable sector (scratch)
    cp 04h
    jr z,_CF_MEDIUM              ; HARDWARE ERROR (04/09/xx track following
                                 ;  on a damaged CD...): same treatment
    ld a,(SENSE_BUF+12)          ; ASC
    cp 27h
    jp z,_CF_WPROT               ; write protected (belt and braces)
    cp 28h
    jr z,_CF_CHANGED             ; medium may have changed
    cp 3Ah
    jr z,_CF_NODISC              ; medium not present
    cp 29h
    jr z,_CF_RESET               ; power on / reset occurred
    cp 04h
    jr z,_CF_SPINUP              ; not ready, becoming ready
    cp 21h
    jr z,_CF_RNF                 ; LBA out of range
    or a                         ; anything else: retry
    ret
_CF_CHANGED:
    call NOTE_CHANGE             ; cache + capacity dropped, Nextor will hear
_CF_CHGD:
    ld a,NX_EDISK
    scf
    ret
_CF_NODISC:
    ; v3.3.2: the next disc is a different one - and Nextor
    ; must hear it, or the same disc coming back without a 28h would be
    ; re-mounted silently. DEV_STATUS still answers 0 while the tray is
    ; empty (3Ah) and "changed" only once a readable disc is measured.
    call NOTE_CHANGE
    ld a,NX_ENRDY
    scf
    ret
_CF_RESET:
_CF_SPINUP:
    ; Sony rule: START UNIT after any reset AND after ASC 04h. The walkman
    ; auto-stops the disc after seconds of inactivity and then reports
    ; "not ready" until an explicit START STOP UNIT (Start=1): TUR_WAIT
    ; alone never brings it back (v1.2 hardware failure, 2026-07-07).
    ; v3.3.2: a 28h heard while it spins up (the drive was LOADING another
    ; disc) means the command must NOT be repeated on the new medium: fail
    ; it; F_CHANGED makes the next DEV_STATUS report the change.
    ; v3.3.5: without a 28h the disc must still prove it is the same one
    ; (_CF_REVERIFY): a drive failing to load a scratched disc sends none.
    ld a,1
    ld (VFY_PEND),a              ; this command just met a not-ready unit
    dec a
    ld (CHG_SEEN),a
    call START_UNIT_L
    call TUR_WAIT
    ld a,(CHG_SEEN)
    or a                         ; Cy=0
    jr nz,_CF_CHGD               ; the medium changed meanwhile: final error
    jp _CF_REVERIFY              ; same disc -> retry the command
_CF_RNF:
    ld a,NX_ERNF
    scf
    ret
_CF_MEDIUM:
    ; v3.4.1: a CD/DVD drive that could not POSITION its head (ASC 02h "no
    ; seek complete", ASC 15h "positioning error", under key 03 or 04) has
    ; not judged the sector at all: its mechanics are not settled yet.
    ; Hardware 2026-10-04 (UJ8B0 drive behind the Initio bridge, cold, the
    ; first long FAT read after booting from a DVD): STALL + 03/02/00 twice in
    ; a row (the one retry below came at once), then "Data error"; a moment
    ; later the same read worked. Such errors get up to SEEK_MAX more
    ; attempts, each after ~1 s of rest. No TEST UNIT READY in between: it
    ; does not move the head, and it could swallow a disc change's UNIT
    ; ATTENTION that the READ itself reports and handles (28h: final).
    ; Bounded in time as well: no new attempt once SEEK_CAP ticks (~40 s at
    ; 3.58 MHz, counted from the start of the request, the drive's own
    ; internal retries inside each READ included) have gone by. These retries
    ; never spend the general ones. Unreadable-surface errors (03/10, 03/11,
    ; 04/09...) and the walkman are handled exactly as before.
    call IS_OPTICAL              ; (corrupts AF only)
    jr nz,_CF_MED
    ld a,(SENSE_BUF+12)          ; ASC
    cp 02h
    jr z,_CF_SEEK
    cp 15h
    jr nz,_CF_MED
_CF_SEEK:
    ld a,(SEEK_LEFT)
    or a
    jr z,_CF_SKFAIL              ; every positioning retry spent
    dec a
    ld (SEEK_LEFT),a
    ld hl,(SEEK_TK)
    ld de,-SEEK_CAP
    add hl,de
    jr c,_CF_SKFAIL              ; the request has run SEEK_CAP ticks already
    ld b,8
    call WAIT_PAUSE              ; ~1 s for the mechanics to settle
    jr c,_CF_SKFAIL              ; (cut short only inside a bring-up session)
    ld hl,RETRY
    inc (hl)                     ; the caller's dec gives it back (Cy kept)
    or a                         ; Cy=0: retry the command
    ret
_CF_SKFAIL:
    scf
    call LOG_EVT                 ; CALL DREAM LOG "P seek fail" (keeps flags)
    db 'P'+80h,LEV_SEEK
    jr _CF_MFINAL                ; "Data error", as before
_CF_MED:
    ; v3.3.3: the transport is fine and the drive has already retried the
    ; sector internally. ONE more attempt (a marginal sector may read after
    ; a re-seek), then a final "data error" - never the retries-exhausted
    ; poison (F_READY=0 -> bus reset + full re-init on the next access):
    ; slow, pointless for a scratch, and it re-mounted the disc under
    ; Nextor's open files. DOS shows Abort/Retry/Ignore;
    ; Retry just issues the READ(10) again. The cache stays invalid (BUF2K
    ; was not validated) and a failed multi-block read counts for nothing.
    ld a,(RETRY)
    cp 2
    jr c,_CF_MFINAL              ; RETRY=1: the extra attempt failed too
    ld a,2
    ld (RETRY),a                 ; the caller's dec leaves 1: one more try
    or a                         ; Cy=0: retry
    ret
_CF_MFINAL:
    ld a,(XFER_OP)
    or a
    ld a,NX_EDATA                ; read: "Data error" (like a CRC error)
    jr z,_CF_MF2
    ld a,NX_EWRERR               ; write: "Write error"
_CF_MF2:
    scf
    ret
_CF_WPROT:
    ld a,NX_EWPROT               ; final: retrying cannot lift the tab
    scf
    ret
_CF_DEAD:
    ld a,(RECOVERED)
    or a
    jr nz,_CF_GIVEUP
    ld a,1
    ld (RECOVERED),a
    call ID_SNAPSHOT             ; who we were talking to
    ld a,(ISO_STATE)
    push af
    xor a
    ld (CHG_SEEN),a
    call HW_INIT_PATIENT         ; a full re-enumeration once per command
    jr c,_CF_GIVEUP_P            ;  (v3.3.6: a session - ESC-able, capped)
    ld a,(CHG_SEEN)              ; v3.3.2: a 28h during the re-init = maybe
    or a                         ;  another disc of the same capacity (two
    jr nz,_CF_OTHER_P            ;  MD80s look identical to ID_SAME): fail
    call ID_SAME
    jr nz,_CF_OTHER_P
    pop af
    ld (ISO_STATE),a             ; same unit, same disc: an ISO mount (and the
                                 ;  clusters DOS already knows) stays valid
    call BUDGET_MECH             ; HW_FULL_INIT left the normal budget
    ; v3.3.5: INQUIRY + capacity are no identity (two MD80s, two CDs of one
    ; size): the re-init set VFY_PEND, the disc itself decides
_CF_REVERIFY:
    ; the unit is back after a not-ready phase or a re-init in the middle of
    ; a command: before the command is repeated, the disc proves it is the
    ; one the request was meant for. Out: Cy=0 retry / Cy=1 final (A).
    ld a,(VFY_PEND)
    or a
    ret z                        ; nothing to verify: retry (Cy=0)
    ld a,(FMT_ACTIVE)
    or a
    ret nz                       ; CALL DREAM FORMAT is rewriting this very
                                 ;  disc: retry (it ends with F_CHANGED)
    ld hl,BUF2K
    ld a,(XFER_OP)
    or a
    jr z,_CFR_GO                 ; a read: BUF2K is refetched by the retry
    ld de,(RW_DEST)
    ld a,d
    cp BUF2K/256
    jr nz,_CFR_GO
    ld a,e
    or a
    jr nz,_CFR_GO
    ; the data of the write in flight sits in BUF2K: read the identity into
    ; DIRBLK instead (a write never happens on an ISO mount, so it holds at
    ; most the kept tables of an earlier ISO disc: they are given up)
    xor a
    ld (ISO_TVALID),a
    ld hl,DIRBLK
_CFR_GO:
    call VERIFY_ID               ; raw SCSI: keeps PHYS_LBA_BE, RW_*, RETRY
    ret z                        ; same disc: retry (Cy=0)
    dec a
    ld a,NX_EDISK
    scf
    ret z                        ; another disc: final (NOTE_CHANGE: guard up)
    ld a,NX_ENRDY                ; unverifiable: final, VFY_PEND stays -
    ret                          ;  never repeated on an unproven disc (Cy=1)
_CF_OTHER_P:
    pop af
_CF_OTHER:
    ; Another device or disc answered (hot swap). Its sectors must never be
    ; handed to Nextor as the old medium's - nor the old FAT written onto
    ; it. Fail; HW_FULL_INIT set F_CHANGED, so the next DEV_STATUS reports
    ; the change and Nextor starts over on the new disc. v3.3.2: and until
    ; then DEV_RW refuses the medium (Nextor may re-issue this very write).
    ld a,1
    ld (CHG_GUARD),a
    ld a,NX_EDISK
    scf
    ret
_CF_GIVEUP_P:
    pop af
_CF_GIVEUP:
    call MY_GWORK
    res F_READY,(ix+0)           ; next DEV_STATUS will re-init from scratch
    set F_HOTWAIT,(ix+0)
    ld a,NX_ENRDY
    scf
    ret

; ==========================================================================
; DEV_STATUS
;  In:  A=device (1), B=LUN (0 tolerated, treated as 1)
;  Out: A=0 not available / 1 available unchanged / 2 available CHANGED /
;       3 available, change unknown.
;  The result is relative to the PREVIOUS DEV_STATUS call (never consumed
;  by DEV_RW): F_CHANGED implements exactly that.
;  v3.3.5: "1" is only said of a disc whose identity holds - after a not-
;  ready phase (VFY_PEND) VERIFY_ID must say "same disc" first; another disc
;  -> 0 once then 2 (CHG_GUARD protocol); unreadable identity -> 0 + DS:03.
; ==========================================================================
DEV_STATUS:
    dec a
    jp nz,_DS_ZERO
    ld a,b
    cp 2
    jp nc,_DS_ZERO
    call ENTER_SEG
    jr nc,_DS_HAVESEG
    ld a,1                       ; pre-DOSINIT probe (no mapper yet): claim
    ret                          ;  "available, unchanged" so drives map
_DS_HAVESEG:
    call MY_GWORK
    bit F_READY,(ix+0)
    jr nz,_DS_TUR
    ; no device known: try to bring one up now (covers plugging the walkman
    ; in after boot, and recovering from a transport death). At boot time
    ; this is the patient path: the walkman may still be booting itself.
    call HW_INIT_PATIENT
    jp nc,_DS_CHANGED
    cp 6                         ; v3.3.6: code 6 because the CD/DVD drive
    jr nz,_DS_INITD              ;  cannot use its disc: the same line as
    ld b,a                       ;  the TEST UNIT READY path below
    ld a,(DISC_BAD)              ;  ("HIMD DS:04 S:kk/aa/qq")
    or a
    ld a,b
    jr nz,_DS_BADDISC
_DS_INITD:
    call INIT_DIAG               ; A = bring-up failure code 1..8
    xor a                        ; still nothing (or medium-less: reported
    jp _DS_EXIT                  ;  as 0 until a readable disc shows up)
_DS_TUR:
    ; v3.3.6: a CD/DVD drive fighting a bad disc answers in SECONDS (hardware
    ; 2026-09-26): with the normal ~1 s budget its TEST UNIT READY "timed
    ; out", the CH376 stayed NAK-retrying (deaf), the REQUEST SENSE was lost
    ; and v3.3.5 called the transport dead ("HIMD DS:02"). A slow answer is
    ; still an answer: the mechanical budget (~10 s per packet) for it. The
    ; walkman keeps the normal one (_DS_EXIT restores it for everybody).
    call IS_OPTICAL
    call z,BUDGET_MECH
    call SCSI_TEST_UNIT_READY
    jp nc,_DS_READY
    ld a,1
    ld (VFY_PEND),a              ; v3.3.5: the unit is not ready: until the
                                 ;  disc proves its identity, never "unchanged"
    ld ix,SENSE_BUF
    call SCSI_REQUEST_SENSE
    call LOG_RQS                 ; CALL DREAM LOG (keeps all regs and flags)
    db 'S'
    call c,RQS_RETRY             ; v3.3.6: a CD/DVD drive gets a resync and
    jp c,_DS_DEAD                ;  one more ask before "transport died"
    ld a,(SENSE_BUF+12)          ; ASC
    cp 28h
    jr z,_DS_MEDIA_CHG
    cp 3Ah
    jp z,_DS_NODISC
    call CHK_UNUSABLE            ; v3.3.6: 03/04 from a CD/DVD drive
    jr z,_DS_BADDISC
    ld a,(SENSE_BUF+12)
    cp 29h
    jr z,_DS_SPIN
    cp 04h
    jr z,_DS_SPIN
    ; v3.3.5: NOT READY, MEDIUM ERROR or HARDWARE ERROR with any other code
    ; is a unit (re)loading a disc too - hardware 2026-09-25: a scratched CD
    ; whose lead-in the drive could not read answered 03/10/00. Same wait.
    ld a,(SENSE_BUF+2)
    and 0Fh
    sub 2
    cp 3
    jr c,_DS_SPIN                ; sense key 02, 03 or 04
    ld a,3                       ; unknown condition: cannot determine (DEV_RW
    jp _DS_EXIT                  ;  re-verifies before serving: VFY_PEND)
_DS_BADDISC:
    ; v3.3.6: the drive is there and answers, but cannot use the disc it
    ; holds (hardware 2026-09-26: a scratched CD, 04/09/02 focus failure,
    ; for ever; v3.3.5 waited 20 s per call, called the transport dead and
    ; sat 15+ minutes in the hot-plug window). Waiting does not repair a
    ; disc: "not available" now, "HIMD DS:04 S:kk/aa/qq". The device stays
    ; known (F_READY) and VFY_PEND stays: whatever becomes readable in there
    ; later must prove its identity first (v3.3.5).
    ld e,4
    call DS_DIAG
    xor a
    jp _DS_EXIT
_DS_SPIN:
    ; Sony rule after any reset condition AND after ASC 04h: the auto-
    ; stopped disc needs an explicit START UNIT, waiting is not enough.
    ; v3.3.2: a 28h heard during this wait (CHG_SEEN; hardware: a CD/DVD
    ; drive LOADING a disc put in with its own button answers 02/04/01 and
    ; only then 06/28/00) = another disc. Answer "not available" THIS time,
    ; like _DS_DEAD: it aborts whatever Nextor was doing, and on Abort
    ; Nextor drops its buffers of the old disc (INV_UD). A "changed" here
    ; would not stop a write in flight: Nextor 2.1.4's VAL_SAME re-reads the
    ; boot sector, installs it (NEW_UPB) BEFORE comparing volume-ids, so it
    ; always sees "same disk" and flushes the old FAT onto the new disc
    ; (seen in the emulator). F_CHANGED and F_CAPOK=0 stay: the next call
    ; measures the new disc and answers 2.
    ; v3.3.5: no 28h does NOT mean "same disc" (the drive may never send
    ; one): VFY_PEND is set, so _DS_READY verifies the disc's identity before
    ; it may answer "unchanged". A time-out (DS:01) leaves VFY_PEND set: the
    ; DOS Retry that follows cannot get an "unchanged" for an unproven disc.
    xor a
    ld (CHG_SEEN),a
    ld (DISC_BAD),a              ; v3.3.6: did the wait end on 03/04?
    call BUDGET_MECH
    call START_UNIT_L
    call TUR_WAIT
    push af                      ; (BUDGET_NORMAL clears Cy: until v3.3.1
    call BUDGET_NORMAL           ;  the time-out branch below was dead and a
    pop af                       ;  unit still not ready passed as ready)
    jr c,_DS_SPINTO
    ld a,(CHG_SEEN)
    or a
    jr z,_DS_READY
    xor a                        ; disc changed while loading: 0 this once
    jp _DS_EXIT
_DS_SPINTO:
    ld a,(DISC_BAD)              ; v3.3.6: it ended on "cannot use the disc"
    or a                         ;  (03/04 from a CD/DVD drive): DS:04
    jr nz,_DS_BADDISC
    ld e,1                       ; spin-up wait timed out
    call DS_DIAG
    xor a
    jp _DS_EXIT
_DS_MEDIA_CHG:
    ; a new disc: drop the cache, wait for it, re-measure it
    xor a
    ld (CACHE_OK),a
    ld (ISO_STATE),a
    call BUDGET_MECH
    call START_UNIT_L
    call TUR_WAIT
    ld ix,CAP_BUF
    call SCSI_READ_CAPACITY
    push af                      ; v3.3.2: keep READ CAPACITY's Cy (it was
    call BUDGET_NORMAL           ;  lost: a failed one then "measured" the
    pop af                       ;  stale CAP_BUF of the previous disc)
    jr c,_DS_CHG_NOCAP
    call RECOMPUTE_TOTALS        ; sets/clears F_CAPOK (2048 check included)
    jr _DS_CHANGED
_DS_CHG_NOCAP:
    call MY_GWORK
    res F_CAPOK,(ix+0)
_DS_CHANGED:
    xor a
    ld (CHG_GUARD),a             ; Nextor hears it now: DEV_RW may go on
    ld (DIRTY0_ON),a             ; v3.3.7: and re-reads the disc's own boot
                                 ;  sector, dirty flag included
    ; v3.3.5: a change report settles every doubt (VFY_PEND = 0), and the
    ; disc in the unit is Nextor's disc from now on: its identity must be
    ; the reference. Already so when it is mounted by a probe that took it
    ; (MID_CUR); else (not probed yet, or probed by CALL DREAM while a
    ; verification was pending) it is re-probed and taken at the next access
    ; (an ISO disc probed meanwhile keeps its tables: "M ISO kept")
    ld (VFY_PEND),a
    ld a,(ISO_STATE)
    or a
    jr z,_DS_CHGNEW
    ld a,(MID_CUR)
    or a
    jr nz,_DS_CHGREP
_DS_CHGNEW:
    xor a
    ld (MID_OK),a
    ld (ISO_STATE),a
_DS_CHGREP:
    call MY_GWORK
    res F_CHANGED,(ix+0)         ; reported now
    ld a,2
    jr _DS_EXIT
_DS_READY:
    xor a
    ld (DISC_BAD),a              ; v3.3.6: ready = it can use its disc
    call MY_GWORK
    bit F_CAPOK,(ix+0)
    jr nz,_DS_READY2
    ; ready, capacity unknown (a disc put in after a "no disc" poll, or a
    ; change noticed outside DEV_STATUS): measure it now
    call MEASURE_CAP
    jr nc,_DS_CHANGED
    xor a                        ; still unreadable: not available
    jr _DS_EXIT
_DS_READY2:
    bit F_CHANGED,(ix+0)
    jr nz,_DS_CHANGED
    ; v3.3.5: "unchanged" is only said of a disc whose identity holds. After
    ; a not-ready phase (VFY_PEND) the disc proves it (capacity, logical
    ; sector 0, the ISO9660 identity; the walkman waking up through 02/04
    ; costs READ CAPACITY + one block read). Another disc -> NOTE_CHANGE and
    ; 0 THIS time (the v3.3.2 CHG_GUARD protocol: aborts Nextor's request so
    ; VAL_SAME never flushes the old disc's buffers onto the new one; the
    ; next call answers 2). Unreadable identity -> 0 + "HIMD DS:03", VFY_PEND
    ; stays: a later call decides (same disc: 1, another: 0 then 2).
    ld a,(VFY_PEND)
    or a
    jr z,_DS_UNCHANGED
    call BUDGET_MECH
    ld hl,BUF2K
    call VERIFY_ID
    push af                      ; (BUDGET_NORMAL corrupts A and the flags)
    call BUDGET_NORMAL
    pop af
    jr z,_DS_UNCHANGED           ; the same disc
    dec a
    jr z,_DS_EXIT                ; another disc: A = 0 (not available, once)
    ld e,3                       ; identity unreadable
    call DS_DIAG
    xor a
    jr _DS_EXIT
_DS_UNCHANGED:
    ld a,1
    jr _DS_EXIT
_DS_NODISC:
    xor a
    ld (CACHE_OK),a
    ld (ISO_STATE),a
    call MY_GWORK
    res F_CAPOK,(ix+0)
    xor a                        ; LUN not available (no medium)
    jr _DS_EXIT
_DS_DEAD:
    ; The unit stopped answering: unplugged, or another device plugged in.
    ; Report "not available" NOW even if something new is already there: it
    ; aborts whatever Nextor was doing (an open file must not carry on onto
    ; another disc). The next call re-initialises and reports the change.
    ld e,2                       ; transport died (sense bytes are stale)
    call DS_DIAG
    call MY_GWORK
    res F_READY,(ix+0)           ; re-init on the next call
    set F_HOTWAIT,(ix+0)         ;  ...patiently: something may be plugged in
    xor a
_DS_EXIT:
    push af
    call BUDGET_NORMAL           ; (v3.3.6: _DS_TUR may have raised it)
    call EXIT_SEG
    pop af
    ret
_DS_ZERO:
    xor a
    ret

; ==========================================================================
; LUN_INFO
;  In:  A=device (1), B=LUN (1), HL=12-byte buffer (never in page 1)
;  Out: A=0 OK / 1 not available.
;  Always answers for device 1 LUN 1 (even with no medium: total=0) so that
;  Nextor maps drive letters at boot and later hot-plug works through
;  DEV_STATUS polling. Sector size is ALWAYS 512 (Nextor rejects the rest).
; ==========================================================================
LUN_INFO:
    dec a
    jr nz,_LI_NA
    ld a,b
    dec a
    jr nz,_LI_NA
    push hl
    call ENTER_SEG
    jr c,_LI_NOSEG
    call MY_GWORK
    ld c,(ix+0)                  ; C = flags snapshot
    ld hl,INFO_TMP
    ld (hl),0                    ; +0 medium type: block device (CD/DVD
                                 ;  too: the setup proven to mount and boot)
    inc hl
    ld (hl),0                    ; +1..2 sector size = 0200h (512), LE
    inc hl
    ld (hl),2
    inc hl
    bit F_CAPOK,c
    jr z,_LI_ZTOT
    ld a,(TOTAL_SEC+0)           ; +3..6 total logical sectors (phys*4), LE
    ld (hl),a
    inc hl
    ld a,(TOTAL_SEC+1)
    ld (hl),a
    inc hl
    ld a,(TOTAL_SEC+2)
    ld (hl),a
    inc hl
    ld a,(TOTAL_SEC+3)
    ld (hl),a
    inc hl
    jr _LI_FLAGS
_LI_ZTOT:
    ld b,4
_LI_Z1:
    ld (hl),0
    inc hl
    djnz _LI_Z1
_LI_FLAGS:
    ld b,01h                     ; +7 removable, read/write (Fase 3)
    bit F_READY,c
    jr z,_LI_SETF
    call IS_OPTICAL
    jr z,_LI_RO
    ld a,(ISO_STATE)
    cp 2
    jr nz,_LI_SETF
_LI_RO:
    ld b,03h                     ; CD/DVD or ISO9660: removable + read-only
_LI_SETF:
    ld (hl),b
    inc hl
    ld b,4
_LI_Z2:
    ld (hl),0                    ; +8..11 cylinders/heads/sectors: n/a
    inc hl
    djnz _LI_Z2
    pop de                       ; DE = caller's buffer
    ld hl,INFO_TMP
    ld bc,12
    call COPY_OUT
    call EXIT_SEG
    xor a
    ret
_LI_NOSEG:
    ; No mapper segment available yet. This happens during COUNTDRV/drive
    ; automapping, which Nextor runs BEFORE DOSINIT (so before the mapper
    ; support exists). Answer directly into the caller's buffer - nothing
    ; was switched, so (HL) is writable as-is - with "no medium yet"
    ; geometry so the drive letters do get assigned.
    pop hl
    ld b,12
    push hl
_LI_NS_CLR:
    ld (hl),0
    inc hl
    djnz _LI_NS_CLR
    pop hl
    inc hl
    inc hl
    ld (hl),2                    ; +1..2: sector size 0200h (mandatory 512)
    ld de,5
    add hl,de
    ld (hl),01h                  ; +7: removable, read/write
    xor a
    ret
_LI_NA:
    ld a,1
    ret

; ==========================================================================
; DEV_INFO
;  In:  A=device (1), B=0 basic / 1 manufacturer / 2 device name / 3 serial,
;       HL=buffer (never in page 1)
;  Out: A=0 OK / 1 not available.
; ==========================================================================
DEV_INFO:
    dec a
    jr z,_DV_DEVOK
_DV_NA:
    ld a,1
    ret
_DV_DEVOK:
    ld a,b
    or a
    jr z,_DV_BASIC
    cp 3
    jr c,_DV_STRING
    jr _DV_NA                    ; serial: not provided by the device
_DV_BASIC:
    ; basic info needs no segment: write straight to the caller's buffer
    ; (page 2 is still the kernel's own segment here)
    ld (hl),1                    ; number of LUNs
    inc hl
    ld (hl),0                    ; feature flags: must be 0
    xor a
    ret
_DV_STRING:
    ld c,b                       ; C = 1 (manufacturer) / 2 (device name)
    push hl
    push bc
    call ENTER_SEG
    jr c,_DV_FAIL2
    call MY_GWORK
    bit F_READY,(ix+0)
    jr z,_DV_NAEXIT
    ld hl,INFO_TMP               ; 64 spaces, then the INQUIRY string
    ld b,64
_DV_SP:
    ld (hl)," "
    inc hl
    djnz _DV_SP
    pop bc
    push bc
    ld a,c
    dec a
    jr nz,_DV_PROD
    ld hl,INQ_BUF+8              ; vendor id (8 chars)
    ld de,INFO_TMP
    ld bc,8
    ldir
    jr _DV_COPY
_DV_PROD:
    ld hl,INQ_BUF+16             ; product id (16 chars)
    ld de,INFO_TMP
    ld bc,16
    ldir
_DV_COPY:
    pop bc
    pop de                       ; DE = caller's buffer
    ld hl,INFO_TMP
    ld bc,64
    call COPY_OUT
    call EXIT_SEG
    xor a
    ret
_DV_NAEXIT:
    call EXIT_SEG
_DV_FAIL2:
    pop bc
    pop hl
    ld a,1
    ret

; ==========================================================================
; FASE 6 - CALL DREAM / CALL HIMD family (info / EJECT / FORMAT / LOG)
;
; These run in BASIC "CALL" context: interrupts are on, the BIOS is in page 0
; (so CHPUT/CHGET work directly) and our segment is NOT mapped on entry. The
; parsing above already consumed the text pointer, so every routine here is free
; to ENTER_SEG (which maps our segment in page 2 with interrupts OFF). CHPUT is
; called with the segment mapped: it touches only page 0/3 and never re-enables
; interrupts, so the DI invariant holds. CHGET (FORMAT confirmation) is the one
; call that needs interrupts, so it runs BEFORE ENTER_SEG.
; ==========================================================================

; --------------------------------------------------------------------------
; String comparison / text parsing helpers (BASIC text is plain ASCII, upper-
; cased by the tokenizer). None touch our segment.
; --------------------------------------------------------------------------
; PREFIXMATCH - does the string at (HL) start with the keyword at (DE)? On a
; match, HL is left pointing at the first char AFTER the keyword and Cy=0; on a
; mismatch, Cy=1 (HL is partly advanced - the caller discards it). DE preserved
; only up to the mismatch. Corrupts AF, BC.
PREFIXMATCH:
    ld a,(de)
    or a
    jr z,_PM_YES                 ; keyword exhausted: prefix matched
    ld c,a
    ld a,(hl)
    cp c
    jr nz,_PM_NO
    inc hl
    inc de
    jr PREFIXMATCH
_PM_YES:
    or a                         ; Cy=0
    ret
_PM_NO:
    scf
    ret

; SKIPSPC - advance HL past spaces. Out: A = first non-space char, HL -> it.
SKIPSPC:
    ld a,(hl)
    cp ' '
    ret nz
    inc hl
    jr SKIPSPC

; WORDMATCH - if the keyword at (DE) matches the text at (HL) followed by a word
; boundary (null or space), advance HL past the keyword and return Cy=0;
; otherwise leave HL untouched and return Cy=1. Corrupts AF, BC.
WORDMATCH:
    push hl
_WM_LOOP:
    ld a,(de)
    or a
    jr z,_WM_END                 ; keyword exhausted -> check the boundary
    ld c,a
    ld a,(hl)
    cp c
    jr nz,_WM_NO
    inc hl
    inc de
    jr _WM_LOOP
_WM_END:
    ld a,(hl)
    or a
    jr z,_WM_YES                 ; end of PROCNM: clean match
    cp ' '
    jr nz,_WM_NO                 ; a trailing letter -> different keyword
_WM_YES:
    pop bc                       ; drop the saved HL: keep the advanced one
    or a                         ; Cy=0
    ret
_WM_NO:
    pop hl
    scf
    ret

; --------------------------------------------------------------------------
; Printing helpers (CALL context: CHPUT preserves all but AF).
; --------------------------------------------------------------------------
PRINT_N:                         ; print B chars from (HL)
    ld a,(hl)
    call CHPUT
    inc hl
    djnz PRINT_N
    ret

CRLF:
    ld a,13
    call CHPUT
    ld a,10
    jp CHPUT

PRINT_DEC16:                     ; HL = unsigned 16-bit -> decimal (no leading 0s)
    ld c,0
_PD_DIV:
    call DIV_HL_10               ; HL /= 10, A = remainder
    push af
    inc c
    ld a,h
    or l
    jr nz,_PD_DIV
_PD_OUT:
    pop af
    add a,'0'
    call CHPUT
    dec c
    jr nz,_PD_OUT
    ret

DIV_HL_10:                       ; HL /= 10, quotient in HL, remainder in A
    xor a
    ld b,16
_DH_LOOP:
    add hl,hl
    rla
    cp 10
    jr c,_DH_SKIP
    sub 10
    inc l                        ; set the quotient bit shifted in this round
_DH_SKIP:
    djnz _DH_LOOP
    ret

; ==========================================================================
; DO_INFO - the "CALL DREAM" (= "CALL HIMD") information screen.
; ==========================================================================
DO_INFO:
    call ENTER_SEG
    ret c
    call BUDGET_NORMAL
    call INFO_REFRESH            ; the unit/disc may have changed since
                                 ;  Nextor's last access
    ld de,S_BANNER6
    call PRINT
    ; ---- Unit: vendor + product from the cached INQUIRY ----
    ld de,S_UNIT
    call PRINT
    call MY_GWORK
    bit F_READY,(ix+0)
    jr z,_DI2_NODEV
    ld hl,INQ_BUF+8              ; vendor (8)
    ld b,8
    call PRINT_N
    ld a,' '
    call CHPUT
    ld hl,INQ_BUF+16            ; product (16)
    ld b,16
    call PRINT_N
    call CRLF
    ; ---- Media: capacity + disc type ----
    ld de,S_MEDIA
    call PRINT
    call MY_GWORK
    bit F_CAPOK,(ix+0)
    jr z,_DI2_NOCAP
    ld hl,(MB16)
    call PRINT_DEC16
    ld de,S_MBSP
    call PRINT
    call INFO_DISCTYPE
    call CRLF
    ; ---- Format: classify physical block 0 ----
    ld de,S_FORMAT6
    call PRINT
    call INFO_FORMAT
    call CRLF
    ; ---- Status: spinning / stopped ----
    ld de,S_STATUS
    call PRINT
    call INFO_STATUS
    call CRLF
    jr _DI2_VER
_DI2_NODEV:
    ld a,(INFO_WHY)
    cp 7
    jr z,_DI2_BADSS
    ld de,S_NODEV
    call PRINT
    jr _DI2_VER
_DI2_NOCAP:
    ld a,(INFO_WHY)
    cp 7
    jr z,_DI2_BADSS
    ld de,S_NOCAP                ; "(no disc) [kk/aa/qq]": the drive's reason
    call PRINT
    ld a,(SENSE_BUF+2)
    and 0Fh
    call PRINT_HEX
    ld a,'/'
    call CHPUT
    ld a,(SENSE_BUF+12)
    call PRINT_HEX
    ld a,'/'
    call CHPUT
    ld a,(SENSE_BUF+13)
    call PRINT_HEX
    ld de,S_CLOSEB
    call PRINT
    jr _DI2_VER
_DI2_BADSS:
    ld de,S_BADSS                ; "(unsupported sector size NNNN)"
    call PRINT
    ld a,(CAP_BUF+6)
    ld h,a
    ld a,(CAP_BUF+7)
    ld l,a
    call PRINT_DEC16
    ld de,S_CLOSEP
    call PRINT
_DI2_VER:
    ld de,S_DRIVER
    call PRINT
    call DRV_VERSION            ; A = main, B = secondary, C = revision
    push bc
    add a,'0'
    call CHPUT
    ld a,'.'
    call CHPUT
    pop bc
    push bc
    ld a,b
    add a,'0'
    call CHPUT
    pop bc
    ld a,c                      ; revision: printed only when non-zero
    or a
    jr z,_DI2_NOREV
    ld a,'.'
    call CHPUT
    ld a,c
    add a,'0'
    call CHPUT
_DI2_NOREV:
    call CRLF
    xor a
    ld (CACHE_OK),a             ; INFO_FORMAT read raw block 0 into BUF2K
    call EXIT_SEG
    ret

; INFO_REFRESH - before CALL DREAM prints anything, bring the driver's view
; of the unit up to date: another device may have been plugged in, or another
; disc put in the tray, since the last access (CALL DREAM runs without any
; DEV_STATUS in between). Changes reach Nextor through F_CHANGED. Sets
; INFO_WHY = 7 when the medium's sector size is unusable. v3.3.2: "becoming
; ready" (04h) gets the same START UNIT + TUR_WAIT as in DEV_STATUS - a CD/DVD
; drive answers 02/04/01 while it LOADS a disc put in with its own button and
; only then 06/28/00 (the old disc's data must not be shown); the known
; capacity is kept unless a 28h is heard. (The walkman's wake-up from its
; auto-stop was silent on hardware, 2026-09-24: TUR simply succeeds.)
; v3.3.5: after a not-ready phase (VFY_PEND) the disc must prove its identity
; (VERIFY_ID) before its known data is shown: another disc is measured and
; shown as new; an unreadable identity counts as a change too (the screen
; then says "(no disc) [kk/aa/qq]" rather than the old disc's data). Other
; NOT READY / MEDIUM / HARDWARE errors wait like 04h (DEV_STATUS does too).
; Corrupts everything.
INFO_REFRESH:
    xor a
    ld (INFO_WHY),a
    call MY_GWORK
    bit F_READY,(ix+0)
    jr z,_IR_INIT
    call SCSI_TEST_UNIT_READY
    jr nc,_IR_READY
    ld a,1
    ld (VFY_PEND),a              ; v3.3.5: not ready = identity to re-prove
    ld ix,SENSE_BUF
    call SCSI_REQUEST_SENSE
    call LOG_RQS                 ; CALL DREAM LOG (keeps all regs and flags)
    db 'I'
    call c,RQS_RETRY             ; v3.3.6: CD/DVD - resync, ask once more
    jr c,_IR_GONE                ; no answer at all: unplugged or swapped
    ld a,(SENSE_BUF+12)
    cp 28h
    jr z,_IR_NEWDISC
    cp 29h
    jr z,_IR_NEWDISC
    cp 3Ah
    jr z,_IR_NODISC
    call CHK_UNUSABLE            ; v3.3.6: the CD/DVD drive cannot use its
    jp z,NOTE_CHANGE             ;  disc: no wait; its old data is not shown
                                 ;  ("(no disc) [kk/aa/qq]"), a change is due
    ld a,(SENSE_BUF+12)
    cp 04h
    jr z,_IR_SPIN                ; loading / spinning up: wait for it
    ld a,(SENSE_BUF+2)
    and 0Fh
    sub 2
    cp 3
    jr c,_IR_SPIN                ; v3.3.5: key 02/03/04 - a unit (re)loading
    ret                          ; anything else: keep state (VFY_PEND: DEV_RW
                                 ;  re-verifies before serving the disc)
_IR_NODISC:
    xor a                        ; no disc
    ld (CACHE_OK),a
    ld (ISO_STATE),a
    call MY_GWORK
    res F_CAPOK,(ix+0)
    ret
_IR_GONE:
    call MY_GWORK
    set F_HOTWAIT,(ix+0)         ; the new unit may still be waking up
_IR_INIT:
    call HW_INIT_PATIENT         ; visible + ESC-able if a unit just appeared
    ld (INFO_WHY),a              ; 0 OK, 1..8 bring-up failure code
    ret
_IR_NEWDISC:
    call NOTE_CHANGE
_IR_SPIN:
    call BUDGET_MECH
    call START_UNIT_L
    call TUR_WAIT                ; a 28h here drops F_CAPOK (NOTE_CHANGE)
    call BUDGET_NORMAL
_IR_READY:
    call MY_GWORK
    bit F_CAPOK,(ix+0)
    jr z,_IR_MEASURE             ; capacity unknown: a change is due anyway
    ld a,(VFY_PEND)
    or a
    ret z                        ; nothing happened to the known disc
    call BUDGET_MECH
    ld hl,BUF2K
    call VERIFY_ID
    push af
    call BUDGET_NORMAL
    pop af
    ret z                        ; the same disc: its data is current
    cp 2
    call z,NOTE_CHANGE           ; unverifiable: treated as a change (another
                                 ;  disc: VERIFY_ID already called it). Both
                                 ;  leave F_CAPOK = 0: measure what is there
_IR_MEASURE:
    call MEASURE_CAP
    jr c,_IR_FAIL
    call MY_GWORK
    set F_CHANGED,(ix+0)         ; new geometry: Nextor must re-read the BPB
    ret
_IR_FAIL:
    ld (INFO_WHY),a
    ret

; MEASURE_CAP - READ CAPACITY + RECOMPUTE_TOTALS on a ready unit.
; Out: Cy=0 OK (F_CAPOK set); Cy=1 with A=0 command failed (REQUEST SENSE
; done: the reason is in SENSE_BUF) or A=7 unusable sector size.
; Corrupts everything.
MEASURE_CAP:
    ld ix,CAP_BUF
    call SCSI_READ_CAPACITY
    jr nc,_MC_GOT
    ld ix,SENSE_BUF
    call SCSI_REQUEST_SENSE
    call LOG_RQS                 ; CALL DREAM LOG (keeps all regs and flags)
    db 'C'
    xor a
    scf
    ret
_MC_GOT:
    call RECOMPUTE_TOTALS        ; Cy=1: sector size unusable
    ld a,7                       ; (ld keeps the carry)
    ret

; NOTE_CHANGE - the medium may have changed: drop the cache and the old
; capacity, and make sure Nextor hears it at its next DEV_STATUS. Also sets
; the sticky CHG_SEEN (v3.3.2) for callers watching a wait. v3.3.5: a known
; change leaves nothing to verify (VFY_PEND = 0; MID_* keeps describing the
; disc Nextor still holds until the change is reported).
; Corrupts AF, AF', IX.
NOTE_CHANGE:
    xor a
    ld (CACHE_OK),a
    ld (DIRTY0_ON),a             ; v3.3.7: another disc, its own dirty flag
    ld (VFY_PEND),a
    ld (ISO_STATE),a             ; an ISO mount never survives a disc change
    inc a
    ld (CHG_SEEN),a
    ld (CHG_GUARD),a             ; DEV_RW stops until DEV_STATUS reports it
    call MY_GWORK
    set F_CHANGED,(ix+0)
    res F_CAPOK,(ix+0)
    ret

; ID_SNAPSHOT / ID_SAME - identity of the unit + disc around a mid-command
; re-init: INQUIRY vendor/product/revision (28 bytes) + TOTAL_SEC (4).
; ID_SAME: Z=1 if unchanged. Both corrupt AF, BC, DE, HL.
ID_SNAPSHOT:
    ld hl,INQ_BUF+8
    ld de,IDSNAP
    ld bc,28
    ldir
    ld hl,TOTAL_SEC
    ld bc,4
    ldir
    ret
ID_SAME:
    ld hl,INQ_BUF+8
    ld de,IDSNAP
    ld b,28
    call _IS_CMP
    ret nz
    ld hl,TOTAL_SEC
    ld b,4
_IS_CMP:
    ld a,(de)
    cp (hl)
    ret nz
    inc hl
    inc de
    djnz _IS_CMP
    ret

; ==========================================================================
; VERIFY_ID (v3.3.5) - is the disc in the unit still the one whose data
; Nextor may hold (the disc last probed: MID_*)? Asked after a not-ready
; phase (VFY_PEND) - never on a plain DEV_STATUS: a walkman waking up from
; its auto-stop through 02/04 pays READ CAPACITY + one block read.
;
; Hardware 2026-09-25 (UJ8B0 DVD drive): MSXCD DVD mounted, swapped with the
; drive's button for a badly scratched CD, DIR: 02/04/01, then 03/10/00 (the
; lead-in unreadable) until the spin-up wait ran out ("HIMD DS:01"), NEVER a
; 06/28/00; on Retry the drive said "ready" and v3.3.4 answered "unchanged":
; Nextor listed the OLD disc from its buffers (the same logic guards the
; walkman's writable discs).
;
; The identity, cheapest first:
;   1. capacity (READ CAPACITY) = MID_TOT, 2048-byte blocks;
;   2. signature of logical sector 0 (the first 512 bytes of block 0: the
;      boot sector with its volume serial, or an MBR) = MID_SIG;
;   3. an ISO9660 mount (MID_ISO): block 16 - the PVD identity of v3.3.3
;      (serial, volume size, root extent, hash of the whole PVD) = ISO_ID.
; Limit: two walkman-formatted MiniDiscs of one model are identical in all
; of this (boot sector serial 0); a real MD swap in the walkman sends
; 06/28/00 (hardware 2026-09-24), so this only matters without one.
; Raw SCSI commands with a REQUEST SENSE after a failure (Sony rule), no
; retries and no CLASSIFY_FAIL: safe inside a failing command's recovery
; (PHYS_LBA_BE, RW_NBLK, RW_DEST, XFER_OP, RETRY untouched).
; In:  HL = 2048-byte buffer for the block reads: BUF2K (CACHE_OK drops), or
;      DIRBLK when BUF2K holds a write in flight (_CF_REVERIFY; the ISO step
;      needs BUF2K and fails elsewhere - an ISO mount never writes).
;      The unit should be ready; the mechanical budget active.
; Out: A=0, Z=1  the same disc, or none probed since the last change report
;                (MID_OK = 0: nothing of it served yet): VFY_PEND = 0
;      A=1, Z=0  another disc: NOTE_CHANGE done (CHG_GUARD up, VFY_PEND = 0)
;      A=2, Z=0  the identity could not be read: VFY_PEND stays 1 (SENSE_BUF
;                holds why, unless REQUEST SENSE failed too)
; Corrupts everything.
; ==========================================================================
VERIFY_ID:
    ld (VFY_BUF),hl
    ld a,(MID_OK)
    or a
    jr z,_VI_OK                  ; nothing served since the last report
    ld ix,CAP_BUF
    call SCSI_READ_CAPACITY
    jr c,_VI_CMDFAIL
    call RECOMPUTE_TOTALS        ; Cy=1: not a 2048-byte medium
    jr c,_VI_DIFF
    ld hl,TOTAL_SEC
    ld de,MID_TOT
    ld b,4
    call _C5_LOOP                ; Z=1: the same capacity
    jr nz,_VI_DIFF
    ld hl,_VI_LBA0
    call _VI_READ                ; block 0
    jr c,_VI_CMDFAIL
    ld hl,(VFY_BUF)
    call SIG0                    ; VFY_SIG = signature of logical sector 0
    ld hl,VFY_SIG
    ld de,MID_SIG
    ld b,4
    call _C5_LOOP
    jr nz,_VI_DIFF
    ld a,(MID_ISO)
    or a
    jr z,_VI_SAME
    ld a,(VFY_BUF+1)
    cp BUF2K/256                 ; the PVD identity is computed in BUF2K
    jr nz,_VI_FAIL
    ld hl,_VI_LBA16
    call _VI_READ                ; block 16: the primary volume descriptor
    jr c,_VI_CMDFAIL
    call ISO_CALC_NID            ; Z=1: a PVD, ISO_NID = its identity
    jr nz,_VI_DIFF
    ld hl,ISO_NID
    ld de,ISO_ID                 ; = the mounted disc's (ISO_PROBE kept or
    ld b,ISO_IDLEN               ;  copied it; MID_ISO says it is ours)
    call _C5_LOOP
    jr nz,_VI_DIFF
_VI_SAME:
    call LOG_EVT                 ; CALL DREAM LOG "V same"
    db 'V'+80h,LEV_VSAME
_VI_OK:
    xor a                        ; A=0, Z=1, Cy=0
    ld (VFY_PEND),a
    ret
_VI_DIFF:
    call NOTE_CHANGE             ; (VFY_PEND = 0, CHG_GUARD = 1)
    call LOG_EVT                 ; CALL DREAM LOG "V DIFF"
    db 'V'+80h,LEV_VDIFF
    ld a,1
    or a                         ; Z=0
    ret
_VI_CMDFAIL:
    ld ix,SENSE_BUF
    call SCSI_REQUEST_SENSE      ; Sony rule; and the reason for DS:03
    call LOG_RQS                 ; CALL DREAM LOG "V kk/aa/qq"
    db 'V'
    jr c,_VI_FAIL
    ld a,(SENSE_BUF+12)
    cp 28h
    jr z,_VI_DIFF                ; a (late) UNIT ATTENTION: it IS a change
_VI_FAIL:
    call LOG_EVT                 ; CALL DREAM LOG "V fail"
    db 'V'+80h,LEV_VFAIL
    ld a,2
    or a                         ; Z=0
    ret

; _VI_READ - READ(10) of one block, LBA at (HL) (big-endian), into VFY_BUF,
; with the optical READ patience of READ_PHYS_RETRY. Cy=1 failed (or the
; data stage came short). Corrupts everything.
_VI_READ:
    xor a
    ld (CACHE_OK),a              ; (the buffer may be BUF2K)
    ld ix,(VFY_BUF)
    ld bc,1
    ld de,2048
    ld a,(CH_WAIT_MULT)
    push af                      ; the budget on entry
    call IS_OPTICAL              ; (corrupts AF only)
    jr nz,_VR_GO
    ld a,MULT_OPTREAD
    ld (CH_WAIT_MULT),a
_VR_GO:
    call SCSI_READ10
    pop de                       ; D = the budget on entry (flags untouched)
    ld a,d
    ld (CH_WAIT_MULT),a
    ret c
    ld hl,(_SCSI_DATA_LEN)       ; every byte must have arrived
    ld a,h
    cp 8
    jr nz,_VR_SHORT
    ld a,l
    or a
    ret z                        ; Cy=0: 2048 bytes
_VR_SHORT:
    scf
    ret
_VI_LBA0:  db 0,0,0,0
_VI_LBA16: db 0,0,0,16

; SIG0 - VFY_SIG = signature of the 512 bytes at HL (logical sector 0): the
; rotating hash of the ISO serial (_SH_RUN). Corrupts AF, BC, HL, IX.
SIG0:
    ld ix,VFY_SIG
    call _SH_ZERO
    ld b,0
    call _SH_RUN                 ; 256 bytes (B=0), leaves B=0...
    jp _SH_RUN                   ; ...for the next 256

; PRINT_HEX - A as two uppercase hex digits (CHPUT). Corrupts AF.
PRINT_HEX:
    push af
    rrca
    rrca
    rrca
    rrca
    call _PH_NIB
    pop af
_PH_NIB:
    and 0Fh
    add a,90h
    daa
    adc a,40h
    daa
    jp CHPUT

; IS_OPTICAL - Z=1 if the unit is an MMC CD/DVD drive (INQUIRY peripheral
; device type 05h). The walkman is a direct-access device (00h). A failed
; INQUIRY leaves INQ_BUF blank (spaces), which reads as 00h. Only meaningful
; while F_READY is set. Corrupts AF.
IS_OPTICAL:
    ld a,(INQ_BUF)
    and 1Fh
    cp 05h
    ret

; IS_HIMD - Z=1 if the INQUIRY vendor/product text contains "Hi-MD" (the
; walkman answers "SONY    " / "Hi-MD WALKMAN"). Anything else that is not a
; CD/DVD drive (a USB magneto-optical drive, say) gets no MiniDisc label.
; Corrupts AF, BC, DE, HL.
IS_HIMD:
    ld hl,INQ_BUF+8
    ld c,24-4                    ; start positions: vendor+product minus len-1
_IH_POS:
    push hl
    ld de,S_HIMDTXT
    ld b,5
_IH_CMP:
    ld a,(de)
    cp (hl)
    jr nz,_IH_NEXT
    inc hl
    inc de
    djnz _IH_CMP
    pop hl                       ; Z=1 from the last cp: found
    ret
_IH_NEXT:
    pop hl
    inc hl
    dec c
    jr nz,_IH_POS
    or 1                         ; Z=0: not a walkman
    ret

; INFO_DISCTYPE - print what kind of disc this is, after the capacity.
; CD/DVD drive: the disc type from the drive's current profile. Walkman: the
; MiniDisc type deduced from the capacity (MB16, in MiB = physical blocks /
; 512). User-measured real discs (decimal MB -> MiB): MD60 ~229 -> 218, MD74
; ~283 -> 270, MD80 ~305 -> 291, 1GB -> ~920. Ranges split at the midpoints
; (real discs vary a little): >=512 MiB 1GB, >=280 MD80, >=244 MD74, >=200
; MD60, else a generic label. Any other device: capacity only.
; Corrupts everything.
INFO_DISCTYPE:
    call IS_OPTICAL
    jp z,INFO_OPTICAL
    call IS_HIMD
    ret nz
    ld a,(MB16+1)               ; high byte of the MiB count
    cp 2
    jr nc,_IDT_1GB              ; >= 512 MiB
    or a
    jr z,_IDT_LOW               ; < 256 MiB: MD74 low end / MD60 / generic
    ld a,(MB16)                 ; 256..511 MiB: MD74 tops out ~270, MD80 ~291
    cp 280-256
    jr c,_IDT_MD74              ; 256..279 MiB
    ld de,S_TYP_MD80            ; 280..511 MiB
    jp PRINT
_IDT_LOW:
    ld a,(MB16)
    cp 244
    jr nc,_IDT_MD74             ; 244..255 MiB: still an MD74
    cp 200
    jr c,_IDT_GEN               ; < 200 MiB: no known MiniDisc is this small
    ld de,S_TYP_MD60            ; 200..243 MiB (real MD60 ~218)
    jp PRINT
_IDT_MD74:
    ld de,S_TYP_MD74
    jp PRINT
_IDT_GEN:
    ld de,S_TYP_GEN
    jp PRINT
_IDT_1GB:
    ld de,S_TYP_1GB
    jp PRINT

; INFO_OPTICAL - disc type of a CD/DVD drive from the current profile that
; GET CONFIGURATION reports (MMC profile list; all current profiles fit in
; one byte). An exact match prints the precise name, otherwise the family
; by range: 08h-0Fh CD, 10h-3Fh DVD, 40h-4Fh Blu-ray; no answer "CD/DVD".
; Corrupts everything.
INFO_OPTICAL:
    ld ix,INFO_TMP
    call SCSI_GET_CONFIG
    jr nc,_IO_HAVE
    ld ix,SENSE_BUF              ; clear the CHECK CONDITION
    call SCSI_REQUEST_SENSE
    call LOG_RQS                 ; CALL DREAM LOG (keeps all regs and flags)
    db 'I'
    jr c,_IO_GEN
    ld a,(SENSE_BUF+12)
    cp 28h
    call z,NOTE_CHANGE           ; v3.3.2: never swallow a disc-change report
    jr _IO_GEN
_IO_HAVE:
    ld a,(INFO_TMP+6)            ; current profile, big-endian
    or a
    jr nz,_IO_GEN
    ld a,(INFO_TMP+7)
    ld c,a
    ld hl,PROF_TAB
_IO_LOOP:
    ld a,(hl)
    or a
    jr z,_IO_RANGE               ; end of the table
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    cp c
    jr nz,_IO_LOOP
    jp PRINT                     ; DE = exact profile name
_IO_RANGE:
    ld a,c
    ld de,S_OPT_BD
    cp 50h
    jr nc,_IO_GEN
    cp 40h
    jp nc,PRINT
    ld de,S_OPT_DVD
    cp 10h
    jp nc,PRINT
    ld de,S_OPT_CD
    cp 08h
    jp nc,PRINT
_IO_GEN:
    ld de,S_OPT_GEN
    jp PRINT

; profile byte, name - terminated by 0 (profile 00h does not exist)
PROF_TAB:
    db 08h
    dw S_OPT_CDROM
    db 09h
    dw S_OPT_CDR
    db 0Ah
    dw S_OPT_CDRW
    db 10h
    dw S_OPT_DVDROM
    db 11h
    dw S_OPT_DVDMR
    db 12h
    dw S_OPT_DVDRAM
    db 13h
    dw S_OPT_DVDMRW
    db 14h
    dw S_OPT_DVDMRW
    db 15h
    dw S_OPT_DVDMRDL
    db 16h
    dw S_OPT_DVDMRDL
    db 1Ah
    dw S_OPT_DVDPRW
    db 1Bh
    dw S_OPT_DVDPR
    db 2Ah
    dw S_OPT_DVDPRWDL
    db 2Bh
    dw S_OPT_DVDPRDL
    db 0

; INFO_FORMAT - read physical block 0 and name the filesystem on the disc.
;   2048-byte-sector FAT boot sector (walkman "superfloppy" layout, also used
;   for MSX CD/DVD masters) -> its FAT type ("FAT16"), plus "(Walkman
;   compatible)" on a MiniDisc; MBR (55AA, Nextor FDISK) -> the FAT type of
;   partition 1, "(partitioned)"; else block 16 is checked for an ISO9660
;   ("CD001") or UDF ("BEA01") volume descriptor -> "(not supported)".
; Corrupts everything.
INFO_FORMAT:
    call MY_GWORK
    bit F_CAPOK,(ix+0)
    jp z,_IF_UNK
    ; v3.3: an ISO9660 disc is mounted natively - probe it now if no access
    ; did yet, then show the label (and whether entries had to be hidden)
    ld a,(ISO_STATE)
    or a
    jr nz,_IF_PROBED
    call BUDGET_MECH
    call ISO_PROBE
    push af
    call BUDGET_NORMAL
    pop af
    ld de,S_FMT_ERR
    jp c,PRINT
_IF_PROBED:
    ld a,(ISO_STATE)
    cp 2
    jr nz,_IF_NOTISO
    ld de,S_FMT_ISO
    call PRINT
    ld a,' '
    call CHPUT
    ld hl,ISO_LABEL+10           ; the label without its trailing spaces
    ld b,11
_IF_TRIM:
    ld a,(hl)
    cp ' '
    jr nz,_IF_PRL
    dec hl
    djnz _IF_TRIM
    jr _IF_WARN
_IF_PRL:
    ld hl,ISO_LABEL
    call PRINT_N
_IF_WARN:
    ld a,(ISO_LOST)
    or a
    ret z
    ld de,S_FMT_HID
    jp PRINT
_IF_NOTISO:
    ld hl,0
    call INFO_READBLK            ; block 0 -> BUF2K
    ld de,S_FMT_ERR
    jp c,PRINT
    call CHK_SONY_BOOT
    jr nz,_IF_MBR
    ; superfloppy: the BPB file-system type field says "FAT12"/"FAT16"
    ld hl,BUF2K+36h
    call PRINT_FATNAME
    call IS_OPTICAL
    ret z
    call IS_HIMD
    ret nz
    ld de,S_FMT_WALK
    jp PRINT
_IF_MBR:
    ld a,(BUF2K+1FEh)           ; MBR boot signature within the first 512 bytes
    cp 55h
    jr nz,_IF_ISO
    ld a,(BUF2K+1FFh)
    cp 0AAh
    jr nz,_IF_ISO
    ld a,(BUF2K+1C2h)           ; partition 1 type
    ld de,S_FAT12
    cp 01h
    jr z,_IF_PART
    ld de,S_FAT16
    cp 04h
    jr z,_IF_PART
    cp 06h
    jr z,_IF_PART
    cp 0Eh
    jr z,_IF_PART
    ld de,S_FAT
_IF_PART:
    call PRINT
    ld de,S_FMT_PART
    jp PRINT
_IF_ISO:
    ld hl,16                     ; first volume descriptor of ISO9660/UDF
    call INFO_READBLK
    jr c,_IF_UNK
    ld hl,BUF2K+1
    ld de,S_ISOID
    call CMP5
    ld de,S_FMT_ISO
    jr z,_IF_NOSUP
    ld hl,BUF2K+1
    ld de,S_UDFID
    call CMP5
    jr nz,_IF_UNK
    ld de,S_FMT_UDF
_IF_NOSUP:
    call PRINT
    ld de,S_FMT_NOSUP
    jp PRINT
_IF_UNK:
    ld de,S_FMT_UNK
    jp PRINT

; INFO_READBLK - read physical block HL (< 65536) into BUF2K with the
; mechanical budget. Cy=1 on failure. Corrupts everything.
INFO_READBLK:
    xor a                        ; PHYS_LBA_BE = 00 00 H L
    ld (CACHE_OK),a              ; BUF2K stops mirroring CACHED_PHYS
    ld (PHYS_LBA_BE),a
    ld (PHYS_LBA_BE+1),a
    ld a,h
    ld (PHYS_LBA_BE+2),a
    ld a,l
    ld (PHYS_LBA_BE+3),a
    ld a,1
    ld (RW_NBLK),a
    ld hl,BUF2K
    ld (RW_DEST),hl
    call BUDGET_MECH
    call READ_PHYS_RETRY
    push af
    call BUDGET_NORMAL
    pop af
    ret

; PRINT_FATNAME - print the BPB file-system type at (HL) if it reads
; "FAT" + two digits ("FAT12"/"FAT16"), else a plain "FAT". Corrupts all.
PRINT_FATNAME:
    push hl
    ld de,S_FAT
    ld b,3
_PF_CMP:
    ld a,(de)
    cp (hl)
    jr nz,_PF_PLAIN
    inc hl
    inc de
    djnz _PF_CMP
    ld a,(hl)                    ; two digits after "FAT"?
    sub '0'
    cp 10
    jr nc,_PF_PLAIN
    inc hl
    ld a,(hl)
    sub '0'
    cp 10
    jr nc,_PF_PLAIN
    pop hl
    ld b,5
    jp PRINT_N
_PF_PLAIN:
    pop hl
    ld de,S_FAT
    jp PRINT

; CMP5 - Z=1 if the 5 bytes at (HL) equal the 5 at (DE). Corrupts AF, B, DE, HL.
CMP5:
    ld b,5
_C5_LOOP:
    ld a,(de)
    cp (hl)
    ret nz
    inc hl
    inc de
    djnz _C5_LOOP
    ret

; INFO_STATUS - a quick TEST UNIT READY: ready = spinning, else stopped. A
; failed TUR is followed by REQUEST SENSE (Sony rule: clears the error state).
; Does NOT spin the disc up (a status probe must be side-effect free).
INFO_STATUS:
    call SCSI_TEST_UNIT_READY
    jr c,_IS_STOP
    ld de,S_ST_RUN
    jp PRINT
_IS_STOP:
    ld a,1
    ld (VFY_PEND),a              ; v3.3.5: not ready = identity to re-prove
    ld ix,SENSE_BUF
    call SCSI_REQUEST_SENSE
    call LOG_RQS                 ; CALL DREAM LOG (keeps all regs and flags)
    db 'I'
    ld a,(SENSE_BUF+12)
    cp 28h
    call z,NOTE_CHANGE           ; never swallow a disc-change report
    ld a,(SENSE_BUF+12)
    cp 29h
    call z,NOTE_CHANGE
    ld de,S_ST_STOP
    jp PRINT

; ==========================================================================
; DO_EJECT - "CALL DREAM EJECT" (= HIMD): flush, spin down, and force a clean re-init.
; A CD/DVD drive is read-only (nothing to flush) and has a tray: it gets the
; eject form of START STOP UNIT. The walkman keeps the proven flush + STOP.
; ==========================================================================
DO_EJECT:
    call ENTER_SEG
    ret c
    call MY_GWORK
    ld de,S_EJ_OK
    bit F_READY,(ix+0)
    jr z,_DE_DONE
    call BUDGET_MECH
    call IS_OPTICAL
    jr z,_DE_TRAY
    call SCSI_SYNC_CACHE        ; best-effort flush (non-fatal if unsupported)
    jr nc,_DE_STOP
    ld ix,SENSE_BUF             ; a device that lacks 0x35 leaves a CHECK
    call SCSI_REQUEST_SENSE     ;  CONDITION: clear it (Sony rule) or the STOP
    call LOG_RQS                ;  below would fail and the disc keep spinning
    db 'E'                      ; (CALL DREAM LOG, keeps all regs and flags)
_DE_STOP:
    call SCSI_STOP_UNIT         ; spin the mechanism down
    ld de,S_EJ_OK
    jr _DE_BUDGET
_DE_TRAY:
    call SCSI_EJECT_UNIT        ; stop + open the tray
    ld de,S_EJ_TRAY
    jr nc,_DE_BUDGET
    ld ix,SENSE_BUF             ; refused (tray locked, no motor...): clear
    call SCSI_REQUEST_SENSE     ;  the error; the disc is stopped anyway
    call LOG_RQS                ; CALL DREAM LOG (keeps all regs and flags)
    db 'E'
    ld de,S_EJ_NOTRAY
_DE_BUDGET:
    push de
    call BUDGET_NORMAL
    pop de
_DE_DONE:
    xor a
    ld (CACHE_OK),a
    ld (ISO_STATE),a
    push de
    call MY_GWORK
    res F_READY,(ix+0)          ; next access re-initialises from scratch
    res F_CAPOK,(ix+0)
    pop de
    call PRINT
    call EXIT_SEG
    ret

; ==========================================================================
; CALL DREAM LOG (v3.3.1) - a permanent, tiny diagnostic. Every sense
; triple the driver obtains from a successful REQUEST SENSE, anywhere, goes
; into a 12-entry log in our segment (LOG_N/LOG_RING, 8CC0h-8CFCh), with a
; letter telling where it came from; so do the START UNIT sends and every
; full USB bring-up, so the sequence reads like a story. It exists to learn,
; on real hardware, which sense codes the walkman and the CD/DVD drive
; really return.
; The log is only touched while our segment is mapped (every site below
; runs inside a DEV_*/CALL entry point after ENTER_SEG), and the hooks keep
; EVERY register and flag intact: the driver behaves exactly as before, a
; few hundred T-states per logged command aside.
;
; Entry (LOG_ESZ = 5 bytes), oldest first:
;   +0 tag. Bit 7 = 0: a sense triple; the letter is the site:
;        W TUR_WAIT            S DEV_STATUS        F CLASSIFY_FAIL (a READ/
;        I CALL DREAM info     C MEASURE_CAP         WRITE command failed)
;        H HW_FULL_INIT warm-up (auto-pilot TUR loop)  E CALL DREAM EJECT
;        U after a failed START UNIT (v3.3.2)
;        V a command of VERIFY_ID failed (v3.3.5)
;        Q a REQUEST SENSE asked again after a Bulk-Only reset (v3.3.6,
;          RQS_RETRY: a CD/DVD drive whose first REQUEST SENSE failed)
;      Bit 7 = 1: an event, +1 = LEV_*:
;        'U' LEV_START    START UNIT sent; +2 = 0 ok / 1 the command failed
;        'R' LEV_INIT     HW_FULL_INIT started (bus reset + enumeration: boot,
;                         hot plug, or the transport died)
;        'B' LEV_HALT     (v3.3.3) a bulk pipe STALLed mid-command (a bridge
;                         ending a failed READ) and CLEAR_FEATURE(HALT) was
;                         sent; +2 = 0 ok / 1 failed
;        'M' LEV_ISONEW   (v3.3.3) an ISO9660 disc mounted with fresh tables
;        'M' LEV_ISOKEEP  (v3.3.3) the SAME ISO disc re-probed: tables kept
;        'V' LEV_VSAME    (v3.3.5) VERIFY_ID after a not-ready phase: the
;                         same disc (Nextor's data of it stays valid)
;        'V' LEV_VDIFF    (v3.3.5) ... another disc: treated as a change
;        'V' LEV_VFAIL    (v3.3.5) ... its identity could not be read (the
;                         failed command's sense precedes it as "V kk/aa/qq")
;        'R' LEV_ESC      (v3.3.6) ESC ended a bring-up session
;        'R' LEV_TIMEUP   (v3.3.6) its time cap did (~90 s; ~3 min at boot)
;        'D' LEV_BADDISC  (v3.3.6) the CD/DVD drive answered MEDIUM/HARDWARE
;                         ERROR while waited for: it cannot use its disc, no
;                         more waiting (logged when first seen)
;        'P' LEV_SEEK     (v3.4.1) a READ(10) of a CD/DVD drive met positioning
;                         errors (03/02/xx "no seek complete", ASC 15h) and got
;                         spaced retries; +2 = 0 it read in the end ("P seek
;                         ok") / 1 retries or time spent ("P seek fail"). The
;                         "F 03/02/00 xN" just before counts the failed tries
;        site LEV_NOSENSE REQUEST SENSE itself failed at that site (the
;                         device is gone or wedged)
;   +1 +2 +3  sense key (low nibble) / ASC / ASCQ  (events: code / aux / 0)
;   +4 repeat count 1..255: an entry identical to the last one only bumps
;      it (TUR_WAIT can loop dozens of times on 02/04/01); 255 = "or more".
; Full log: the oldest entry is dropped.
; ==========================================================================

; LOG_RQS - log the REQUEST SENSE that has JUST run. Must be called right
; after SCSI_REQUEST_SENSE / CHD_REQUEST_SENSE, followed by the site byte:
;       call LOG_RQS
;       db 'W'
; In: Cy = that REQUEST SENSE's result (Cy=0: SENSE_BUF holds fresh sense).
; Preserves ALL registers and flags (returns past the inline byte).
LOG_RQS:
    ex (sp),hl                   ; HL -> inline site byte, caller's HL parked
    push af
    push bc
    push de
    ld b,(hl)                    ; B = site letter
    inc hl                       ; HL = the real return address
    push hl
    jr c,_LQ_NONE                ; (ex/push/ld/inc hl keep the caller's Cy)
    ld a,(SENSE_BUF+2)
    and 0Fh
    ld c,a                       ; sense key
    ld a,(SENSE_BUF+12)
    ld d,a                       ; ASC
    ld a,(SENSE_BUF+13)
    ld e,a                       ; ASCQ
    jr _LQ_ADD
_LQ_NONE:
    set 7,b                      ; event "<site> no sense"
    ld c,LEV_NOSENSE
    ld de,0
_LQ_ADD:
    call LOG_ADD
    pop hl                       ; return address
    pop de
    pop bc
    pop af
    ex (sp),hl                   ; return address back, caller's HL restored
    ret

; LOG_EVT - log an event: `call LOG_EVT / db tag+80h, LEV_x`. For LEV_START
; LEV_HALT and LEV_SEEK the caller's Cy (the command's result) becomes the aux byte
; (0 ok / 1 failed); other events ignore it. Preserves ALL registers and flags.
LOG_EVT:
    ex (sp),hl
    push af
    push bc
    push de
    ld b,(hl)                    ; tag + 80h
    inc hl
    ld c,(hl)                    ; event code
    inc hl
    push hl                      ; the real return address
    ld de,0
    jr nc,_LE_AUX
    inc d                        ; the command failed
_LE_AUX:
    ld a,c
    cp LEV_START
    jr z,_LQ_ADD
    cp LEV_HALT
    jr z,_LQ_ADD
    cp LEV_SEEK                  ; v3.4.1
    jr z,_LQ_ADD
    ld d,0                       ; only START/HALT/SEEK carry a result
    jr _LQ_ADD

; START_UNIT_L - SCSI_START_UNIT + "U START ok/fail". v3.3.2: a failed START
; is followed by REQUEST SENSE (Sony rule, like every other failure; logged
; as "U kk/aa/qq"): the drive's ONE 06/28/00 after a disc change may land on
; this very command, and without the REQUEST SENSE it would be lost - a 28h
; there calls NOTE_CHANGE. Out: Cy = SCSI_START_UNIT's result (no caller
; uses it: TUR_WAIT follows). Corrupts everything (as SCSI_START_UNIT).
START_UNIT_L:
    call SCSI_START_UNIT
    call LOG_EVT
    db 'U'+80h,LEV_START
    ret nc
    ld a,1
    ld (VFY_PEND),a              ; v3.3.5: a unit refusing START is not ready
    ld ix,SENSE_BUF
    call SCSI_REQUEST_SENSE
    call LOG_RQS                 ; CALL DREAM LOG (keeps all regs and flags)
    db 'U'
    jr c,_SU_FAIL                ; no sense: stale buffer, nothing to act on
    ld a,(SENSE_BUF+12)
    cp 28h
    call z,NOTE_CHANGE
_SU_FAIL:
    scf                          ; START UNIT failed
    ret

; LOG_ADD - append the entry B,C,D,E with count 1, or bump the count of the
; newest entry if it is identical. Full log: drop the oldest first.
; Segment mapped. Corrupts AF, BC, DE, HL.
LOG_ADD:
    ld a,(LOG_N)
    cp LOG_MAX+1
    jr c,_LA_NOK
    ld a,LOG_MAX                 ; (defensive: never trust a wild count)
    ld (LOG_N),a
_LA_NOK:
    or a
    jr z,_LA_NEW                 ; empty log
    dec a
    call _LOG_PTR                ; HL -> newest entry
    ld a,(hl)
    cp b
    jr nz,_LA_NEW
    inc hl
    ld a,(hl)
    cp c
    jr nz,_LA_NEW
    inc hl
    ld a,(hl)
    cp d
    jr nz,_LA_NEW
    inc hl
    ld a,(hl)
    cp e
    jr nz,_LA_NEW
    inc hl
    inc (hl)                     ; same as the newest: count it
    ret nz
    dec (hl)                     ; saturate at 255
    ret
_LA_NEW:
    ld a,(LOG_N)
    cp LOG_MAX
    jr c,_LA_ROOM
    push bc                      ; full: drop the oldest entry
    push de
    ld hl,LOG_RING+LOG_ESZ
    ld de,LOG_RING
    ld bc,LOG_ESZ*(LOG_MAX-1)    ; (NOT "(LOG_MAX-1)*..": a leading paren
    ldir                         ;  assembles as ld bc,(nn) - an indirect load)
    pop de
    pop bc
    ld a,LOG_MAX-1
_LA_ROOM:
    push af
    call _LOG_PTR                ; HL -> free slot A
    ld (hl),b
    inc hl
    ld (hl),c
    inc hl
    ld (hl),d
    inc hl
    ld (hl),e
    inc hl
    ld (hl),1
    pop af
    inc a
    ld (LOG_N),a
    ret

; _LOG_PTR - HL = LOG_RING + A*LOG_ESZ (A < LOG_MAX). Corrupts AF.
_LOG_PTR:
    ld l,a
    add a,a
    add a,a
    add a,l                      ; A*5 (<= 55)
    ld hl,LOG_RING
    add a,l
    ld l,a
    ret nc
    inc h
    ret

; ==========================================================================
; DO_LOG - "CALL DREAM LOG" (= HIMD): print the log oldest -> newest, one
; entry per line (fits 40 columns), then CLEAR it so every experiment starts
; clean. Never talks to the device. Lines:
;   W 02/04/01 x37   sense key/ASC/ASCQ at site W, 37 times in a row
;   U START ok       START UNIT sent ("fail" = the command itself failed)
;   R INIT           full USB bring-up started (bus reset + enumeration)
;   B HALT ok        a STALLed bulk pipe was cleared (v3.3.3)
;   M ISO new/kept   ISO mounted afresh / same disc again, tables kept
;   V same/DIFF/fail identity check after a not-ready phase (v3.3.5)
;   Q 04/09/02       REQUEST SENSE asked again after a Bulk-Only reset (v3.3.6)
;   D unusable       the CD/DVD drive cannot use its disc: no waiting (v3.3.6)
;   P seek ok/fail   a READ hit "no seek complete" and was retried (v3.4.1)
;   R ESC / R time up  a bring-up session ended by ESC / its time cap (v3.3.6)
;   S no sense       REQUEST SENSE failed at site S (device gone/wedged)
;   (log empty)      nothing recorded since the last CALL DREAM LOG
; ==========================================================================
DO_LOG:
    call ENTER_SEG
    ret c
    ld a,(LOG_N)
    or a
    jr nz,_DL_HAVE
    ld de,S_LOGEMPTY
    call PRINT
    jr _DL_CLEAR
_DL_HAVE:
    cp LOG_MAX+1
    jr c,_DL_N
    ld a,LOG_MAX                 ; (defensive)
_DL_N:
    ld b,a
    ld hl,LOG_RING
_DL_LOOP:
    push bc
    push hl
    call LOG_LINE
    pop hl
    ld de,LOG_ESZ
    add hl,de
    pop bc
    djnz _DL_LOOP
_DL_CLEAR:
    xor a
    ld (LOG_N),a
    call EXIT_SEG
    ret

; LOG_LINE - print the entry at HL as one line. Corrupts AF, BC, DE, HL.
LOG_LINE:
    ld a,(hl)
    and 7Fh
    call CHPUT                   ; site / event letter
    ld a,' '
    call CHPUT
    ld a,(hl)
    inc hl                       ; HL -> +1
    rla                          ; Cy = bit 7: an event
    jr c,_LL_EVT
    ld a,(hl)                    ; "kk/aa/qq"
    call PRINT_HEX
    ld a,'/'
    call CHPUT
    inc hl
    ld a,(hl)
    call PRINT_HEX
    ld a,'/'
    call CHPUT
    inc hl
    ld a,(hl)
    call PRINT_HEX
    inc hl                       ; HL -> +4 count
    jr _LL_CNT
_LL_EVT:
    ld a,(hl)                    ; event code
    inc hl                       ; HL -> +2 aux
    ld de,S_LEV_NOSENSE
    cp LEV_NOSENSE
    jr z,_LL_PRT
    ld de,S_LEV_INIT
    cp LEV_INIT
    jr z,_LL_PRT
    ld de,S_LEV_ISONEW
    cp LEV_ISONEW
    jr z,_LL_PRT
    ld de,S_LEV_ISOKEEP
    cp LEV_ISOKEEP
    jr z,_LL_PRT
    ld de,S_LEV_VSAME            ; v3.3.5: VERIFY_ID verdicts
    cp LEV_VSAME
    jr z,_LL_PRT
    ld de,S_LEV_VDIFF
    cp LEV_VDIFF
    jr z,_LL_PRT
    ld de,S_LEV_FAIL+1           ; "fail" (S_LEV_FAIL without its space)
    cp LEV_VFAIL
    jr z,_LL_PRT
    ld de,S_LEV_ESC              ; v3.3.6: a bring-up session's end / an
    cp LEV_ESC                   ;  unusable disc
    jr z,_LL_PRT
    ld de,S_LEV_TIMEUP
    cp LEV_TIMEUP
    jr z,_LL_PRT
    ld de,S_LEV_BADDISC
    cp LEV_BADDISC
    jr z,_LL_PRT
    ld de,S_LEV_HALT
    cp LEV_HALT
    jr z,_LL_AUX
    ld de,S_LEV_SEEK             ; v3.4.1
    cp LEV_SEEK
    jr z,_LL_AUX
    ld de,S_LEV_START
_LL_AUX:
    call PRINT
    ld a,(hl)                    ; aux: 0 ok / 1 failed
    ld de,S_LEV_OK
    or a
    jr z,_LL_PRT
    ld de,S_LEV_FAIL
_LL_PRT:
    call PRINT
    inc hl
    inc hl                       ; HL -> +4 count
_LL_CNT:
    ld a,(hl)
    cp 2
    jp c,CRLF                    ; seen once: no counter
    ld l,a
    ld h,0
    ld a,' '
    call CHPUT
    ld a,'x'
    call CHPUT
    push hl
    call PRINT_DEC16
    pop hl
    ld a,l
    inc a                        ; Z=1: saturated at 255
    ld a,'+'
    call z,CHPUT
    jp CRLF

; ==========================================================================
; KEY_YN - block on a direct PPI keyboard scan until Y, N or ESC is pressed.
; Returns A='Y' for yes, A='N' for no/ESC. Works with interrupts disabled (the
; CALL context) because it reads the matrix straight from the PPI, like the
; boot-time _HIP_ESC probe. MSX matrix: Y = row 5 bit 6, N = row 4 bit 3,
; ESC = row 7 bit 2 (0 = pressed). Corrupts AF.
; ==========================================================================
KEY_YN:
    in a,(0AAh)                  ; row 5 -> Y
    and 0F0h
    or 5
    out (0AAh),a
    in a,(0A9h)
    bit 6,a
    jr z,_KY_YES
    in a,(0AAh)                  ; row 4 -> N
    and 0F0h
    or 4
    out (0AAh),a
    in a,(0A9h)
    bit 3,a
    jr z,_KY_NO
    in a,(0AAh)                  ; row 7 -> ESC (cancel)
    and 0F0h
    or 7
    out (0AAh),a
    in a,(0A9h)
    bit 2,a
    jr z,_KY_NO
    jr KEY_YN
_KY_YES:
    ld a,'Y'
    ret
_KY_NO:
    ld a,'N'
    ret

; ==========================================================================
; DO_FORMAT - "CALL DREAM FORMAT" (= HIMD): clone the Walkman's Sony factory format from
; the MSX. Boot sector + both FATs + root directory are laid down byte-for-byte
; like a disc formatted by the Walkman (verified against two real dd images);
; the rest of the medium is left untouched, exactly as the Walkman does. The
; sectors go out through the SCSI layer (WRITE10), NOT through DEV_RW.
; ==========================================================================
DO_FORMAT:
    ; ---- a CD/DVD cannot be formatted: refuse before asking anything ----
    call ENTER_SEG
    ret c
    call MY_GWORK
    bit F_READY,(ix+0)
    jr z,_DF_ASK                 ; unit not known yet: checked again after Y
    call IS_OPTICAL
    jp z,_DF_RO
_DF_ASK:
    call EXIT_SEG
    ; ---- confirmation (segment NOT mapped: page 2 is the caller's RAM) --
    ld de,S_FMTWARN
    call PRINT
    ; The EI/DI state at entry is NOT guaranteed: the kernel source does EI
    ; before CALBNK (dskbasic.mac), yet CHGET was observed dead here on the
    ; emulator (the slot-chain dispatch may leave DI). So: scan the matrix
    ; DIRECTLY through the PPI (like the boot-time _HIP_ESC probe) under an
    ; explicit DI - if an ISR were alive, its own matrix sweep could switch
    ; rows between our OUT and IN. Only Y/N/ESC answer - a stray key press
    ; (or the ENTER that ran the statement) can never silently confirm.
    di                           ; make the PPI row scan atomic
    call KEY_YN                  ; A = 'Y' (yes) or 'N' (no / ESC)
    cp 'Y'
    jr z,_DF_YES
    ld a,'N'
    call CHPUT
    ld de,S_FMTCANC
    call PRINT
    ei                           ; every CALL-handler exit returns with EI (the
                                 ;   other paths end in EXIT_SEG, which does EI)
    ret
_DF_YES:
    ld a,'Y'
    call CHPUT                   ; echo the accepted answer
_DF_GO:
    call ENTER_SEG
    ret c
    call MY_GWORK
    bit F_READY,(ix+0)
    jr nz,_DF_CAP
    call HW_INIT_PATIENT
_DF_CAP:
    call MY_GWORK
    bit F_CAPOK,(ix+0)
    jr z,_DF_NODISC
    call IS_OPTICAL
    jr z,_DF_RO
    ld a,1
    ld (FMT_ACTIVE),a            ; open the block-0 guard for this session only
    call BUDGET_MECH
    call FMT_COMPUTE             ; FATsz, layout LBAs and total32 from TOTAL_SEC
    call FMT_WRITE_ALL           ; Cy=1 on any write failure
    push af
    xor a
    ld (FMT_ACTIVE),a            ; ALWAYS close the guard again
    ld (CACHE_OK),a             ; BUF2K held format sectors, not a disc block
    ld (ISO_STATE),a            ; the disc is FAT now: probe it again
    ld (ISO_TVALID),a           ;  (and no old ISO tables may ever apply)
    call BUDGET_NORMAL
    call MY_GWORK
    set F_CHANGED,(ix+0)        ; make Nextor re-read the BPB without a reboot
    pop af
    jr c,_DF_FAIL
    ld de,S_FMTOK
    call PRINT
    call EXIT_SEG
    ret
_DF_FAIL:
    ld de,S_FMTFAIL
    call PRINT
    call EXIT_SEG
    ret
_DF_NODISC:
    xor a
    ld (FMT_ACTIVE),a
    ld de,S_NODISC
    call PRINT
    call EXIT_SEG
    ret
_DF_RO:                          ; segment mapped
    ld de,S_FMTRO
    call PRINT
    call EXIT_SEG
    ret

; FMT_COMPUTE - derive the FAT16 geometry the Walkman would pick for this disc.
;   total32   = TOTAL_SEC >> 2                  (physical 2048-byte blocks)
;   FATsz     = ceil( (total32 - 1 - 8) / 16386 )
; where 16386 = (2048/2)*16 + 2 = entries-per-FAT-sector * spc + NumFATs, the
; standard fatgen denominator specialised to our fixed spc=16 / 2 FATs / 512
; root entries (RootDirSectors = 512*32/2048 = 8, independent of FATsz, so the
; formula is a straight division, no iteration). Verified: 138363 -> 9,
; 494023 -> 31 (the two real reference discs). Corrupts everything.
FMT_COMPUTE:
    ld hl,(TOTAL_SEC)           ; DE:HL = logical sectors (phys*4), 32-bit
    ld de,(TOTAL_SEC+2)
    srl d
    rr e
    rr h
    rr l
    srl d
    rr e
    rr h
    rr l                         ; DE:HL = physical block count = total32
    ld (FMT_TOT),hl
    ld (FMT_TOT+2),de
    ld bc,9                      ; val = total32 - (ReservedSecCnt + RootDirSec)
    or a
    sbc hl,bc
    jr nc,_FC_NB
    dec de
_FC_NB:
    ld bc,0                      ; BC = FATsz accumulator (ceil of val/16386)
_FC_LOOP:
    bit 7,d
    jr nz,_FC_DONE              ; val went negative: last subtraction was it
    ld a,d
    or e
    or h
    or l
    jr z,_FC_DONE              ; val == 0: done
    inc bc
    push bc
    ld bc,16386
    or a
    sbc hl,bc
    jr nc,_FC_NB2
    dec de
_FC_NB2:
    pop bc
    jr _FC_LOOP
_FC_DONE:
    ld a,c
    ld (FMT_FATSZ),a
    inc a
    ld (FMT_F1),a               ; FAT #2 starts at 1 + FATsz
    ld a,c
    add a,a
    inc a
    ld (FMT_ROOT),a             ; root dir starts at 1 + 2*FATsz
    add a,8                      ; root dir spans 8 physical sectors
    ld (FMT_LAST),a
    ret

; FMT_WRITE_ALL - write every format sector (boot, both FATs, root). Each 2048-
; byte sector is rebuilt in BUF2K then committed with one WRITE10. Out: Cy=1 on
; the first failure (A = Nextor error). Corrupts everything.
FMT_WRITE_ALL:
    xor a
    ld (FMT_LBA),a
_FW_LOOP:
    call ZERO_BUF2K
    ld a,(FMT_LBA)
    or a
    jr nz,_FW_NOT0
    call FMT_BUILD_BOOT
    jr _FW_WRITE
_FW_NOT0:
    ld a,(FMT_LBA)
    cp 1
    jr z,_FW_FAT               ; FAT #1 first sector
    ld hl,FMT_F1
    cp (hl)
    jr z,_FW_FAT               ; FAT #2 first sector
    ld hl,FMT_ROOT
    cp (hl)
    jr z,_FW_ROOT
    jr _FW_WRITE               ; a plain zeroed sector
_FW_FAT:
    call FMT_BUILD_FAT
    jr _FW_WRITE
_FW_ROOT:
    call FMT_BUILD_ROOT
_FW_WRITE:
    ld a,(FMT_LBA)
    call FMT_WRITE_ONE
    ret c
    ld a,(FMT_LBA)
    inc a
    ld (FMT_LBA),a
    ld hl,FMT_LAST
    cp (hl)
    jr c,_FW_LOOP
    or a                        ; Cy=0: all sectors written
    ret

; FMT_WRITE_ONE - WRITE10 one physical block from BUF2K to LBA A (0..~71, so a
; single low byte covers every format sector). Cy from WRITE_PHYS_RETRY.
FMT_WRITE_ONE:
    ld hl,PHYS_LBA_BE
    ld (hl),0
    inc hl
    ld (hl),0
    inc hl
    ld (hl),0
    inc hl
    ld (hl),a
    ld a,1
    ld (RW_NBLK),a
    ld hl,BUF2K
    ld (RW_DEST),hl
    jp WRITE_PHYS_RETRY

ZERO_BUF2K:                      ; clear the 2048-byte build buffer
    ld hl,BUF2K
    ld de,BUF2K+1
    ld bc,2047
    ld (hl),0
    ldir
    ret

; FMT_BUILD_BOOT - lay the Sony boot sector template into a zeroed BUF2K and
; patch the two computed fields (FATsz at 0x16, total32 at 0x20). No 55AA: the
; Walkman writes none (verified in both dd references).
FMT_BUILD_BOOT:
    ld hl,BOOT_TEMPLATE
    ld de,BUF2K
    ld bc,BOOT_TEMPLATE_LEN
    ldir
    ld a,(FMT_FATSZ)
    ld (BUF2K+16h),a            ; sectors per FAT (high byte stays 0)
    ld hl,(FMT_TOT)
    ld (BUF2K+20h),hl           ; total32 low word
    ld hl,(FMT_TOT+2)
    ld (BUF2K+22h),hl           ; total32 high word
    ret

FMT_BUILD_FAT:                   ; first FAT sector: media + clean EOC, then 0s
    ld hl,BUF2K
    ld (hl),0F0h                ; FAT[0] = FFF0h (media descriptor)
    inc hl
    ld (hl),0FFh
    inc hl
    ld (hl),0FFh               ; FAT[1] = FFFFh (EOC, volume flags CLEAN)
    inc hl
    ld (hl),0FFh
    ret

FMT_BUILD_ROOT:                  ; root dir first sector: the lone HI-MD.IND entry
    ld hl,HIMD_IND
    ld de,BUF2K
    ld bc,32
    ldir
    ret

; Sony boot sector template (offsets 0..61 of the 2048-byte sector; the rest is
; zero). Cloned from a real Walkman-formatted MD74 disc; the two per-disc fields
; (FATsz at 0x16, total32 at 0x20) are placeholders patched at run time.
BOOT_TEMPLATE:
    db 0E9h,00h,00h              ; 00 x86 jump
    db "MSWIN4.1"                ; 03 OEM name
    db 00h,08h                   ; 0B bytes/sector = 2048
    db 16                        ; 0D sectors/cluster
    db 01h,00h                   ; 0E reserved sectors = 1
    db 02h                       ; 10 number of FATs = 2
    db 00h,02h                   ; 11 root entries = 512
    db 00h,00h                   ; 13 total sectors (16-bit) = 0
    db 0F0h                      ; 15 media descriptor
    db 00h,00h                   ; 16 sectors/FAT  (PATCHED: FATsz)
    db 20h,00h                   ; 18 sectors/track = 32
    db 40h,00h                   ; 1A heads = 64
    db 00h,00h,00h,00h           ; 1C hidden sectors = 0
    db 00h,00h,00h,00h           ; 20 total sectors (32-bit)  (PATCHED: total32)
    db 00h                       ; 24 drive number
    db 00h                       ; 25 reserved
    db 29h                       ; 26 extended boot signature
    db 00h,00h,00h,00h           ; 27 volume serial = 0
    db "NO NAME    "             ; 2B volume label (11)
    db "FAT16   "                ; 36 file-system type (8)
BOOT_TEMPLATE_END:
BOOT_TEMPLATE_LEN:  equ BOOT_TEMPLATE_END-BOOT_TEMPLATE

; HI-MD.IND directory entry (32 bytes), cloned byte-for-byte from the Walkman
; reference (offset 38944 of a Walkman-formatted MD74 disc): hidden+read-only, cluster 0,
; size 0, dated 2004-01-01 (the Walkman epoch). Its mere presence keeps the
; Walkman from complaining about a missing index; HMDHIFI is deliberately NOT
; created (validated on hardware: the Walkman recreates it on demand).
HIMD_IND:
    db 48h,49h,2Dh,4Dh,44h,20h,20h,20h  ; +00 "HI-MD   "
    db 49h,4Eh,44h                        ; +08 "IND"
    db 03h                                ; +0B attr: hidden + read-only
    db 00h,00h,00h,00h                    ; +0C NTRes, CrtTimeTenth, CrtTime
    db 21h,30h                            ; +10 CrtDate  (2004-01-01)
    db 21h,30h                            ; +12 LstAccDate
    db 00h,00h                            ; +14 FstClusHI
    db 00h,00h                            ; +16 WrtTime
    db 21h,30h                            ; +18 WrtDate
    db 00h,00h                            ; +1A FstClusLO = 0
    db 00h,00h,00h,00h                    ; +1C FileSize = 0

; --------------------------------------------------------------------------
; CALL HIMD screen strings (English - "Hi-MD Dream Drive" art direction).
; --------------------------------------------------------------------------
S_DREAMNAME: db "DREAM",0
S_HIMDNAME: db "HIMD",0
S_EJECT:    db "EJECT",0
S_FORMAT:   db "FORMAT",0
S_LOG:      db "LOG",0
S_LOGEMPTY: db "(log empty)",13,10,0
S_LEV_START: db "START",0
S_LEV_OK:   db " ok",0
S_LEV_FAIL: db " fail",0
S_LEV_INIT: db "INIT",0
S_LEV_NOSENSE: db "no sense",0
S_LEV_HALT: db "HALT",0
S_LEV_SEEK: db "seek",0
S_LEV_ISONEW: db "ISO new",0
S_LEV_ISOKEEP: db "ISO kept",0
S_LEV_VSAME: db "same",0
S_LEV_VDIFF: db "DIFF",0
S_LEV_ESC:  db "ESC",0
S_LEV_TIMEUP: db "time up",0
S_LEV_BADDISC: db "unusable",0

S_BANNER6:  db "Hi-MD Dream Drive",13,10,0
S_UNIT:     db "Unit:   ",0
S_MEDIA:    db "Media:  ",0
S_MBSP:     db " MB  ",0
S_FORMAT6:  db "Format: ",0
S_STATUS:   db "Status: ",0
S_DRIVER:   db "Driver: v",0
S_NODEV:    db "(no device)",13,10,0
S_NOCAP:    db "(no disc) [",0
S_CLOSEB:   db "]",13,10,0
S_BADSS:    db "(unsupported sector size ",0
S_CLOSEP:   db ")",13,10,0
S_TYP_1GB:  db "Hi-MD 1GB",0
S_TYP_MD60: db "MD60 (Hi-MD mode)",0
S_TYP_MD74: db "MD74 (Hi-MD mode)",0
S_TYP_MD80: db "MD80 (Hi-MD mode)",0
S_TYP_GEN:  db "Hi-MD",0
S_HIMDTXT:  db "Hi-MD"                 ; IS_HIMD needle (5 bytes, no terminator)
S_FAT:      db "FAT",0
S_FAT12:    db "FAT12",0
S_FAT16:    db "FAT16",0
S_FMT_WALK: db " (Walkman compatible)",0
S_FMT_PART: db " (partitioned)",0
S_FMT_ISO:  db "ISO9660",0
S_FMT_UDF:  db "UDF",0
S_FMT_NOSUP: db " (not supported)",0
S_FMT_HID:  db " (partial)",0            ; some entries could not be shown
S_ISOID:    db "CD001"
S_UDFID:    db "BEA01"
S_FMT_ERR:  db "unreadable",0
S_FMT_UNK:  db "unknown",0
S_OPT_CDROM: db "CD-ROM",0
S_OPT_CDR:  db "CD-R",0
S_OPT_CDRW: db "CD-RW",0
S_OPT_DVDROM: db "DVD-ROM",0
S_OPT_DVDMR: db "DVD-R",0
S_OPT_DVDRAM: db "DVD-RAM",0
S_OPT_DVDMRW: db "DVD-RW",0
S_OPT_DVDMRDL: db "DVD-R DL",0
S_OPT_DVDPRW: db "DVD+RW",0
S_OPT_DVDPR: db "DVD+R",0
S_OPT_DVDPRWDL: db "DVD+RW DL",0
S_OPT_DVDPRDL: db "DVD+R DL",0
S_OPT_CD:   db "CD",0
S_OPT_DVD:  db "DVD",0
S_OPT_BD:   db "Blu-ray",0
S_OPT_GEN:  db "CD/DVD",0
S_ST_RUN:   db "spinning",0
S_ST_STOP:  db "stopped",0

S_EJ_OK:    db "Disc stopped. Safe to remove.",13,10,0
S_EJ_TRAY:  db "Disc ejected.",13,10,0
S_EJ_NOTRAY: db "Disc stopped (the drive did not open).",13,10,0

S_FMTWARN:  db 13,10,"ALL DATA WILL BE LOST.",13,10,"FORMAT? (Y/N) ",0
S_FMTOK:    db 13,10,"Format complete.",13,10,0
S_FMTFAIL:  db 13,10,"Format FAILED.",13,10,0
S_FMTCANC:  db 13,10,"Cancelled.",13,10,0
S_NODISC:   db 13,10,"No disc to format.",13,10,0
S_FMTRO:    db 13,10,"CD/DVD discs are read-only.",13,10,0

; ==========================================================================
; Boot-time printing helpers (CHPUT is only valid during DRV_INIT)
; ==========================================================================

; PRINT: DE -> zero-terminated string. Corrupts AF, DE.
PRINT:
    ld a,(de)
    or a
    ret z
    call CHPUT
    inc de
    jr PRINT

; Screen texts (art direction: PERUHO, 2026-07-08 mockup)
S_BANNER:   db "MD/CD/DVD USB Driver v.3.4.1",13,10,0
S_CHIPOK:   db "CH376 OK",13,10,0
S_NOCHIP:   db "CH376 not found",13,10,0

; ==========================================================================
; Hardware-validated layers (Fase 0). Order matters only for readability;
; all their mutable state is backed by the WORKRAM EQUs above.
; ==========================================================================
    include "iso9660.asm"
    include "ch376.asm"
    include "usb_enum.asm"
    include "scsi.asm"
    include "ch376_disk.asm"

; --------------------------------------------------------------------------
; Padding up to the exact per-bank driver size (16080 bytes from DRV_START)
; --------------------------------------------------------------------------
DRV_END:

    ds 3ED0h-(DRV_END-DRV_START)

    end
