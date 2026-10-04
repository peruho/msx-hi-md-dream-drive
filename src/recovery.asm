;
; recovery.asm - In-ROM firmware recovery tool for the MSX Hi-MD Drive
;                cartridge (Rookie Drive NX, Fase 5).
;
; Copyright (c) 2026 MSX Hi-MD Drive project
; Parts derived from OUR OWN GPLv3 sources:
;   * flash primitives (erase/program/verify + the two CPLD "golden rules")
;     first proven on the hardware in a standalone MSX-DOS flasher.
;   * CH376 hardware + auto-pilot layers included verbatim from src/ch376.asm
;     and src/ch376_disk.asm (DISK_CONNECT / DISK_MOUNT reused as-is).
; The CH376 FILE-mode commands (SET_FILE_NAME / FILE_OPEN / GET_FILE_SIZE /
; BYTE_READ / BYTE_RD_GO / FILE_CLOSE) are added HERE (they are not in the
; auto-pilot layer, which only does raw Bulk-Only).
;
; This program is free software under the GNU General Public License v3.
; NOT ONE LINE is copied from the third-party firmware: only the user-visible
; behaviour (CTRL+R entry, F1/ESC, "power-cycle when done") is imitated.
;
; --------------------------------------------------------------------------
; This file is *included* from src/bootrd0.asm when it is built with the
; symbol HAVE_RECOVERY defined (see bootrd0.asm: `ifdef HAVE_RECOVERY /
; include "recovery.asm"`). It is entered at RECOVERY_MAIN with:
;   * page 0 (0000h-3FFFh) = main BIOS ROM (intact throughout: NOT erased)
;   * page 1 (4000h-7FFFh) = the cartridge, bank 0 (this code, ROM)
;   * page 3 (C000h-FFFFh) = main RAM (BIOS stack + system work area)
;
; STRATEGY: the very first thing RECOVERY_MAIN does is copy the whole runtime
; (this module + the CH376 layers) into page-3 RAM and jump there, so that NO
; code executes from the cartridge flash while it is being erased/programmed.
; The runtime is assembled with `.phase RT_BASE` so every internal jump/label
; resolves to its RAM run address even though the bytes physically live in
; the ROM image.  The BIOS in page 0 survives the flash, so we can still use
; INITXT (once, to set up SCREEN 0 + font) and SNSMAT (to read F1/ESC); all
; text output is done by writing the VDP directly (a "DI + direct VDP" mode
; that survives killing the cartridge ROM).
;
; RAM MAP (page 3, all below the BIOS system area at F380h):
;   C000h..           runtime code + strings (copied from ROM)   (< 6 KB)
;   D800h..E7FFh      16-KB-bank read/program buffer, 4 KB chunk  (BUF_SIZE)
;   E800h..           work RAM (CH376 layers + our own variables)
;   F000h             stack top (grows down towards the work RAM)
; --------------------------------------------------------------------------

; ======= Fixed RAM layout (absolute; independent of the code size) =========
RT_BASE:        equ 0C000h      ; runtime run address (copied here from ROM)
BANK_BUF:       equ 0D800h      ; read/program chunk buffer
BUF_SIZE:       equ 1000h       ; 4 KB per chunk (16 KB bank = 4 chunks)
WK:             equ 0E800h      ; work RAM base
RT_STACK:       equ 0F000h      ; our private stack top

; ======= Flash chip / mapper (Macronix MX29F040 behind the CPLD) ===========
BANKSEL:        equ 6000h       ; Rookie Drive bank register (page-1 window)
WINDOW:         equ 4000h       ; 16 KB flash window
UNLOCK1:        equ 4555h       ; flash command address 555h (from any bank)
UNLOCK2:        equ 42AAh       ; flash command address 2AAh (from any bank)

; ======= VDP (direct text output, independent of BIOS/interrupts) ==========
VDP_DATA:       equ 98h
VDP_CTRL:       equ 99h
SCR_COLS:       equ 80          ; SCREEN 0 x 80 (art direction; on an MSX1
                                ; the text would land garbled but the keys
                                ; and the flashing flow still work)
SCR_ROWS:       equ 24
SCR_CELLS:      equ SCR_COLS*SCR_ROWS

; ------ Screen layout (0-based rows; all cells = row*SCR_COLS + column) -----
; The 2026 mock-up: everything centred except the two footer blocks.
ROW_MSG:        equ 12          ; message zone (rotating status lines)
ROW_BAR:        equ 14          ; flashing progress bar
BAR_CELL:       equ ROW_BAR*SCR_COLS+29   ; '[' of "[............] BANK 00"
BANKCELL0:      equ ROW_BAR*SCR_COLS+30   ; bank-0 cell inside the brackets
BANKNUM_CELL:   equ ROW_BAR*SCR_COLS+49   ; tens digit of "BANK NN"
FOOT_F1:        equ 19*SCR_COLS+15        ; confirmation footer, left block
                                          ; ("F1" centred over "FLASH ROM")
FOOT_FLASH:     equ 21*SCR_COLS+12
FOOT_ESC:       equ 19*SCR_COLS+61        ; confirmation footer, right block
                                          ; ("ESC" centred over "Cancel")
FOOT_CANCEL:    equ 21*SCR_COLS+60

; ------ V9938 TEXT2 blink attribute (the red "DO NOT POWER OFF" line) -------
; TEXT2 has a 1-bit-per-character colour/blink table.  We fix its base at
; VRAM 0800h (R#3=20h,R#10=0 -> (R#10<<14)|(R#3<<6)=0800h), clear of the name
; table (0000h..077Fh, 80x24) and the pattern table (1000h).  One row = 80
; bits = 10 bytes; MSB of each byte is the left-most of its 8 columns.
BLINK_BASE:     equ 0800h
BLINK_ROWLEN:   equ 10          ; 80 columns / 8 bits
BLINK_BYTES:    equ BLINK_ROWLEN*SCR_ROWS ; 240 bytes: whole attribute table
RED_ROW:        equ 21          ; the warning line lives on row 21

; ======= Extra CH376 command codes (FILE mode - not in constants.asm) =======
; The chip's built-in FAT file access.  It only supports 512-byte-sector
; media (a normal FAT pendrive); a 2048-byte Hi-MD Walkman will NOT mount,
; which is exactly how we tell a data pendrive from the Walkman.
CH_CMD_GET_FILE_SIZE: equ 0Ch   ; +arg 68h, then 4 bytes LE = current file size
CH_CMD_SET_FILE_NAME: equ 2Fh   ; +filename bytes, 00-terminated
CH_CMD_FILE_OPEN:     equ 32h   ; open the named file; INT = result
CH_CMD_FILE_CLOSE:    equ 36h   ; +arg (0 = don't update size); INT = result
CH_CMD_BYTE_READ:     equ 3Ah   ; +req length (2 bytes LE); INT = 1Dh/14h
CH_CMD_BYTE_RD_GO:    equ 3Bh   ; continue a byte-read; INT = 1Dh/14h

; Smaller DISK_MOUNT retry budget than the 60-try default of constants.asm
; (constants.asm guards this with IFNDEF): a data pendrive mounts at once and
; the Walkman must fail quickly so we can prompt for the right device.
CHD_MOUNT_RETRIES:    equ 6

; CH376 ports, commands, status/error codes, SCSI ops (EQU-only, no bytes:
; safe to include outside the phased region).
    include "constants.asm"

; ==========================================================================
; RECOVERY_MAIN - entry from bootrd0.asm (runs from the ROM in page 1).
; Copy the phased runtime block from its ROM image into page-3 RAM and jump
; into it.  From this point on nothing runs from the cartridge.
; ==========================================================================
RECOVERY_MAIN:
    di
    ld hl,RT_LOAD               ; physical ROM address of the runtime block
    ld de,RT_BASE               ; RAM run address
    ld bc,RT_SIZE               ; number of bytes to copy
    ldir
    jp RT_BASE                  ; = jp 0C000h (into the copied runtime)

; ==========================================================================
; The runtime block.  Physically emitted here in the ROM image (RT_LOAD),
; but assembled for execution at RT_BASE in RAM.
; ==========================================================================
RT_LOAD:
    .phase RT_BASE

; --------------------------------------------------------------------------
RT_START:
    di
    ld sp,RT_STACK              ; our own stack (page-3 RAM)

    ; Readable 40-column SCREEN 0 (loads the font + name table at VRAM 0).
    ld a,SCR_COLS
    ld (LINL40),a
    call INITXT                 ; BIOS, page 0 (intact)
    di                          ; INITXT may have re-enabled interrupts

    ; Art direction: white text on a black screen and black border
    ; (INITXT leaves the BIOS blue; we own the VDP from here on).
    ld e,7
    ld a,0F1h                   ; R#7: text colour 15 (white), backdrop 1
    call VDP_SETREG             ;      (black) - border and background

    ifdef RECOVERY_UITEST
    jp UITEST_MAIN             ; screen-only demo (the CH376 model can't flash)
    endif

    ; --- CH376 present? ---
    call CH_INIT
    call CH_HW_TEST
    jr nc,DETECT_LOOP
    call SHOW_TITLE
    ld hl,S_NOCHIP
    call MSG
    jp HALT_LOOP

; --------------------------------------------------------------------------
; Detect + mount a data pendrive, open DDFIRMWA.ROM and validate its size.
; On any failure: show the reason, wait ~2 s (ESC aborts) and retry.
; --------------------------------------------------------------------------
DETECT_LOOP:
    call SHOW_TITLE
    ld hl,S_SEARCH
    call MSG

    call CH_INIT                ; fresh chip state for each attempt
    call CHD_CONNECT            ; wait for a mass-storage device
    jr c,_DET_NODEV

    ld a,4                      ; patient INT budget for the mechanical mount
    ld (CH_WAIT_MULT),a
    call CHD_MOUNT              ; mount the FAT volume (fails on the Walkman)
    ld a,1
    ld (CH_WAIT_MULT),a
    jr c,_DET_NOMOUNT

    call OPEN_FILE              ; SET_FILE_NAME + FILE_OPEN
    jr c,_DET_NOFILE

    call CH_GET_FILE_SIZE       ; DE:HL = 32-bit size
    ld a,h
    or l
    jr nz,_DET_BADSIZE          ; low word must be 0000h
    ld a,d
    or a
    jr nz,_DET_BADSIZE          ; byte 3 must be 00h
    ld a,e
    cp 3                        ; byte 2 must be 03h  => 0x00030000 = 196608
    jr nz,_DET_BADSIZE
    jr READY                    ; everything checks out

_DET_NODEV:
    ld hl,S_NODEV
    jr _DET_RETRY
_DET_NOMOUNT:
    ld hl,S_NOMOUNT
    jr _DET_RETRY
_DET_NOFILE:
    ld hl,S_NOFILE
    jr _DET_RETRY
_DET_BADSIZE:
    call CLOSE_FILE
    ld hl,S_BADSIZE
_DET_RETRY:
    call MSG                    ; reason in the message zone (row 12)
    call WAIT_2S_OR_ESC
    jr DETECT_LOOP

; --------------------------------------------------------------------------
; Ready: image found and valid.  Wait for F1 (flash) or ESC (abort).
; --------------------------------------------------------------------------
READY:
    call SHOW_TITLE
    ld hl,S_FOUND
    call MSG                    ; "...found and valid!" in the message zone
    call SHOW_FOOTER            ; F1 / FLASH ROM  and  ESC / Cancel
_RDY_KEY:
    ld a,7
    call SNSMAT                 ; row 7, bit 2 = ESC (0 = pressed)
    bit 2,a
    jr z,DO_ABORT
    ld a,6
    call SNSMAT                 ; row 6, bit 5 = F1 (0 = pressed)
    bit 5,a
    jr z,DO_FLASH
    jr _RDY_KEY

DO_ABORT:
    xor a
    ld (BANKSEL),a             ; leave a sane bank
    jp 0                       ; cold boot (user boots normally, no CTRL+R)

; ==========================================================================
; FLASH: 12 banks of 16 KB.  The MX29F040 erases per 64-KB sector (= 4
; banks).  ORDER MATTERS: sector 0 (banks 0-3) holds the bootloader AND this
; recovery, so it is written LAST - banks 4..11 (Nextor) first, then the
; file is re-opened and banks 0..3 follow.  A USB failure while Nextor is
; being written leaves the bootloader and CTRL+R intact.  And no sector is
; ever erased before the first 4 KB meant for it have been read from the
; pendrive (FLASH_BANK), so a stick that is dead from the start erases
; nothing at all; for sector 0 the bootloader+recovery (< 4 KB, chunk 0) are
; programmed from RAM right after its erase, with no USB access in between.
; ==========================================================================
DO_FLASH:
    ld a,3
    ld (RESTARTS),a            ; whole-file restarts allowed after a read error
FLASH_START:
    call SHOW_FLASH_SCREEN     ; "FLASHING ROM", empty bar, red warning line
    call SKIP_SECTOR0          ; file pointer -> bank 4 (banks 0-3 come last)
    ld a,1
    jr c,_DF_ERR               ; USB read error: restartable
    ld a,12
    ld (BANKS_LEFT),a
    ld a,4
    ld (CUR_BANK),a
_DF_LOOP:
    ld a,(CUR_BANK)
    call SHOW_BANKNUM          ; "BANK NN" -> current bank
    ld a,(CUR_BANK)
    ld c,'o'                   ; this bank is now in progress
    call SET_BANK_CELL
    call FLASH_BANK            ; Cy=0 OK; Cy=1 with A=1 read err, A=2 flash err
    jr c,_DF_ERR
    ld a,(CUR_BANK)
    ld c,'O'                   ; this bank is done
    call SET_BANK_CELL
    ld hl,BANKS_LEFT
    dec (hl)
    jr z,_DF_DONE
    ld a,(CUR_BANK)
    inc a
    cp 12
    jr nz,_DF_SET
    ; banks 4-11 written: re-open the file at its start for sector 0
    call CLOSE_FILE
    call OPEN_FILE
    ld a,1
    jr c,_DF_ERR               ; restartable (sector 0 still untouched)
    xor a
_DF_SET:
    ld (CUR_BANK),a
    jr _DF_LOOP
_DF_DONE:
    ; ---- all 12 banks done ----
    call CLOSE_FILE
    call CLR_RED               ; the danger has passed: drop the red line
    ld hl,S_COMPLETE
    call MSG
    jp HALT_LOOP
_DF_ERR:
    cp 1
    jr z,_DF_RESTART           ; USB read error: retry the whole file
    ; ---- fatal flash error (erase/program/verify) ----
    ld a,(CUR_BANK)
    ld c,'X'                   ; mark the guilty bank
    call SET_BANK_CELL
    call CLR_RED
    ld hl,S_FATAL
    call MSG
    jp HALT_LOOP

; A USB read failed mid-file.  The flash-so-far does not matter (recovery
; lives in RAM): re-mount + re-open and restart from the top (banks 4-11
; first, as always).  At most RESTARTS times, then give up with the USB
; message - distinct from S_FATAL, which means the flash chip itself failed.
_DF_RESTART:
    call CLOSE_FILE
    ld hl,RESTARTS
    dec (hl)
    jr z,_DFR_GIVEUP           ; the stick mounts but keeps failing: stop
    ld hl,S_REREAD
    call MSG
    ld b,5                     ; a few mount/open attempts
_DFR_TRY:
    push bc
    call CH_INIT
    call CHD_CONNECT
    jr c,_DFR_WAIT
    ld a,4
    ld (CH_WAIT_MULT),a
    call CHD_MOUNT
    ld a,1
    ld (CH_WAIT_MULT),a
    jr c,_DFR_WAIT
    call OPEN_FILE
    jr nc,_DFR_OK
_DFR_WAIT:
    ld bc,5000                 ; ~500 ms
    call CH_DELAY
    pop bc
    djnz _DFR_TRY
_DFR_GIVEUP:
    call CLR_RED
    ld hl,S_USBFAIL
    call MSG
    jp HALT_LOOP
_DFR_OK:
    pop bc
    jp FLASH_START             ; restart the burn from bank 0

; --------------------------------------------------------------------------
; FLASH_BANK: flash the bank in (CUR_BANK).  Reads its 16 KB from the file in
; BUF_SIZE chunks and programs+verifies each chunk.
; Output: Cy=0 OK; Cy=1 with A=1 (USB read error, restartable) or A=2
;         (flash erase/program/verify error, fatal).
; --------------------------------------------------------------------------
FLASH_BANK:
    ld de,WINDOW               ; chunk destinations 4000h,5000h,6000h,7000h
    ld a,(CUR_BANK)
    and 3
    jr nz,_FB_CHUNK            ; only bank%4==0 starts a new 64-KB sector
    ; sector start: read its first chunk BEFORE erasing anything
    call FB_READ               ; preserves DE
    jr c,_FB_READERR
    ld a,(CUR_BANK)
    rrca
    rrca
    and 3Fh                    ; sector = bank / 4
    call FL_ERASE_SECTOR
    jr c,_FB_FLASHERR
    ld de,WINDOW
    jr _FB_PROG                ; the chunk is already in BANK_BUF
_FB_CHUNK:
    call FB_READ
    jr c,_FB_READERR
_FB_PROG:
    push de
    call FL_PROG_CHUNK         ; program BANK_BUF -> window (DE)
    pop de
    jr c,_FB_FLASHERR
    push de
    call FL_VERIFY_CHUNK       ; read back and compare
    pop de
    jr c,_FB_FLASHERR
    ld a,d
    add a,BUF_SIZE/256         ; next chunk (BUF_SIZE = 1000h -> +10h high byte)
    ld d,a
    cp WINDOW/256+40h          ; past the 16-KB window end (8000h) ?
    jr nz,_FB_CHUNK
    or a                       ; all four chunks done, Cy=0
    ret
_FB_READERR:
    ld a,1
    scf
    ret
_FB_FLASHERR:
    ld a,2
    scf
    ret

; FB_READ: heartbeat for the chunk at DE (window high byte 4/5/6/7 -> phase
; 0..3 of '.'->'o'->'O'->'o' in the in-progress bank cell), then fill
; BANK_BUF with BUF_SIZE bytes from the file.  Cy=1 on a USB read error.
; Preserves DE.
FB_READ:
    ld a,d
    rrca
    rrca
    rrca
    rrca
    and 3
    ld hl,PULSE_TAB
    add a,l
    ld l,a
    ld c,(hl)                  ; C = phase character
    ld a,(CUR_BANK)
    call SET_BANK_CELL         ; preserves DE
    push de
    ld hl,BANK_BUF
    ld (RD_DEST),hl
    ld hl,BUF_SIZE
    ld (RD_REMAIN),hl
    call CH_READ_CHUNK         ; fill BANK_BUF with BUF_SIZE bytes from the file
    pop de
    ret

; SKIP_SECTOR0: read (and drop) the first 64 KB of the file - the image of
; sector 0, flashed last - so the pointer stands at bank 4.  Only proven
; commands are used (BYTE_READ, no seek).  Cy=1 on a USB read error.
SKIP_SECTOR0:
    ld b,64/4                  ; 16 chunks of 4 KB
_SS_LOOP:
    push bc
    ld hl,BANK_BUF
    ld (RD_DEST),hl
    ld hl,BUF_SIZE
    ld (RD_REMAIN),hl
    call CH_READ_CHUNK
    pop bc
    ret c
    djnz _SS_LOOP
    ret                        ; Cy=0 (djnz leaves the flags of CH_READ_CHUNK)

; ==========================================================================
; Flash primitives (first proven on the hardware in a standalone flasher;
; the two CPLD "golden rules" are preserved exactly):
;   RULE 1: select the target bank ONCE before a flash command sequence and
;           NEVER touch the bank register inside it (a bank write is forwarded
;           to the flash as a spurious cycle).  Command addresses only decode
;           A10-A0, so 4555h/42AAh work from within any bank.
;   RULE 2: writing a data byte in the 6000h+ range ALSO latches the bank in
;           the CPLD, so re-select the bank immediately after EACH program
;           byte (the busy flash ignores the extra write).
; Interrupts must be off (they are: the whole runtime runs with DI).
; ==========================================================================

; FL_ERASE_SECTOR: A = 64-KB sector number (0..2).  Cy=1 on timeout.
FL_ERASE_SECTOR:
    add a,a
    add a,a                    ; first bank of the sector
    ld (BANKSEL),a             ; RULE 1: select once, before the sequence
    ld a,0AAh
    ld (UNLOCK1),a
    ld a,55h
    ld (UNLOCK2),a
    ld a,80h
    ld (UNLOCK1),a
    ld a,0AAh
    ld (UNLOCK1),a
    ld a,55h
    ld (UNLOCK2),a
    ld a,30h
    ld (WINDOW),a              ; sector address = window base of that bank
    ld d,60                    ; ~60 s worst-case budget
_FE_OUTER:
    ld bc,0
_FE_INNER:
    ld a,(WINDOW)
    inc a                      ; FFh -> 0 when fully erased
    jr z,_FE_OK
    dec bc
    ld a,b
    or c
    jr nz,_FE_INNER
    dec d
    jr nz,_FE_OUTER
    scf
    ret
_FE_OK:
    or a
    ret

; FL_PROG_CHUNK: program BUF_SIZE bytes from BANK_BUF into the flash window at
; DE (4000h/5000h/6000h/7000h).  (CUR_BANK) = target bank.  Cy=1 on failure.
FL_PROG_CHUNK:
    ld a,(CUR_BANK)
    ld (BANKSEL),a             ; RULE 1: bank selected once up front
    ld hl,BANK_BUF
    ld a,d
    add a,BUF_SIZE/256         ; B = window high byte at end of this chunk
    ld b,a
_FPC_LOOP:
    ld a,(hl)
    ld c,a                     ; C = data byte
    inc a
    jr z,_FPC_NEXT             ; FFh = erased state, skip
    ld a,0AAh
    ld (UNLOCK1),a
    ld a,55h
    ld (UNLOCK2),a
    ld a,0A0h
    ld (UNLOCK1),a
    ld a,c
    ld (de),a                  ; program the byte (may latch the bank, RULE 2)
    ld a,(CUR_BANK)
    ld (BANKSEL),a             ; RULE 2: re-select the bank after the data write
    push bc
    ld b,0                     ; up to 256 polls (~20 us typical program time)
_FPC_POLL:
    ld a,(de)
    cp c
    jr z,_FPC_POLLOK
    djnz _FPC_POLL
    pop bc
    scf                        ; program timeout
    ret
_FPC_POLLOK:
    pop bc
_FPC_NEXT:
    inc hl
    inc de
    ld a,d
    cp b                       ; reached the end of this chunk ?
    jr nz,_FPC_LOOP
    or a
    ret

; FL_VERIFY_CHUNK: compare BUF_SIZE window bytes at DE against BANK_BUF.
; (CUR_BANK) = bank.  Cy=1 on mismatch.
FL_VERIFY_CHUNK:
    ld a,(CUR_BANK)
    ld (BANKSEL),a
    ld hl,BANK_BUF
    ld a,d
    add a,BUF_SIZE/256
    ld b,a
_FVC_LOOP:
    ld a,(de)
    cp (hl)
    jr nz,_FVC_BAD
    inc hl
    inc de
    ld a,d
    cp b
    jr nz,_FVC_LOOP
    or a
    ret
_FVC_BAD:
    scf
    ret

; ==========================================================================
; CH376 FILE-mode helpers (added here; the auto-pilot layer only does raw
; Bulk-Only).  All run with DI; the chip is driven purely by polling.
; ==========================================================================

; CH_INIT: reset the chip and enter USB host mode.  Cy=1 on mode failure.
CH_INIT:
    ld a,1
    ld (CH_WAIT_MULT),a
    call CH_RESET_ALL
    ld a,CH_MODE_HOST
    call CH_SET_USB_MODE
    ret

; OPEN_FILE: set the name and open it.  Cy=0 opened, Cy=1 not found / error.
OPEN_FILE:
    ld hl,S_FNAME
    call CH_SET_FILE_NAME
    ; fall through to FILE_OPEN
CH_FILE_OPEN:
    ld a,CH_CMD_FILE_OPEN
    out (CH_COMMAND_PORT),a
    call CH_WAIT_RAW           ; A = raw status; Cy=1 on timeout
    ret c
    cp CH_ST_INT_SUCCESS       ; 14h = opened OK
    ret z                      ; Cy=0
    scf
    ret

; CH_SET_FILE_NAME: HL -> 00-terminated name (leading '/' = root).
CH_SET_FILE_NAME:
    ld a,CH_CMD_SET_FILE_NAME
    out (CH_COMMAND_PORT),a
_SFN_LOOP:
    ld a,(hl)
    out (CH_DATA_PORT),a
    or a
    ret z                      ; wrote the terminating 00
    inc hl
    jr _SFN_LOOP

; CH_GET_FILE_SIZE: DE:HL = 32-bit file length (DE = high word, HL = low).
CH_GET_FILE_SIZE:
    ld a,CH_CMD_GET_FILE_SIZE
    out (CH_COMMAND_PORT),a
    ld a,68h                   ; select "current file size"
    out (CH_DATA_PORT),a
    in a,(CH_DATA_PORT)
    ld l,a                     ; byte 0 (LSB)
    in a,(CH_DATA_PORT)
    ld h,a                     ; byte 1
    in a,(CH_DATA_PORT)
    ld e,a                     ; byte 2
    in a,(CH_DATA_PORT)
    ld d,a                     ; byte 3 (MSB)
    ret

; CLOSE_FILE: close without updating the length; INT ignored.
CLOSE_FILE:
    ld a,CH_CMD_FILE_CLOSE
    out (CH_COMMAND_PORT),a
    xor a
    out (CH_DATA_PORT),a
    call CH_WAIT_RAW
    ret

; CH_READ_CHUNK: read exactly (RD_REMAIN) bytes from the open file into
; (RD_DEST), advancing the file pointer.  Cy=1 on timeout / error.
; Uses CMD_BYTE_READ + RD_USB_DATA0 drain + CMD_BYTE_RD_GO, re-issuing
; BYTE_READ until the whole count is satisfied.
CH_READ_CHUNK:
_RC_REQ:
    ld hl,(RD_REMAIN)
    ld a,h
    or l
    jr z,_RC_DONE              ; nothing left to read
    ld a,CH_CMD_BYTE_READ
    out (CH_COMMAND_PORT),a
    ld a,l
    out (CH_DATA_PORT),a       ; requested length, low
    ld a,h
    out (CH_DATA_PORT),a       ; requested length, high
_RC_WAIT:
    call CH_WAIT_RAW
    ret c                      ; timeout -> Cy=1 (caller restarts the file)
    cp CH_ST_INT_SUCCESS       ; 14h = this BYTE_READ request completed
    jr z,_RC_REQ               ; more to read? re-issue BYTE_READ
    cp CH_ST_INT_DISK_READ     ; 1Dh = a block (<=64 B) is ready
    jr nz,_RC_ERR
    ld hl,(RD_DEST)
    call CH_READ_DATA          ; C = bytes read, HL advanced, B = 0
    ld (RD_DEST),hl
    ; RD_REMAIN -= C
    ld a,(RD_REMAIN)
    sub c
    ld (RD_REMAIN),a
    ld a,(RD_REMAIN+1)
    sbc a,0
    ld (RD_REMAIN+1),a
    ld a,CH_CMD_BYTE_RD_GO
    out (CH_COMMAND_PORT),a
    jr _RC_WAIT
_RC_DONE:
    or a                       ; Cy=0
    ret
_RC_ERR:
    scf
    ret

; CH_WAIT_RAW: wait (with timeout) for the CH376 INT, return the RAW status.
; Output: A = raw status byte, Cy=0; on timeout Cy=1.  Preserves HL.
; ~4 rounds of ~1.28 s (fast for FILE ops; DISK_MOUNT gets its own budget).
CH_WAIT_RAW:
    push de
    ld d,4
_CWR_ROUND:
    ld bc,0
_CWR_LOOP:
    in a,(CH_COMMAND_PORT)
    and 80h
    jr z,_CWR_GOT              ; bit7=0 => INT active
    dec bc
    ld a,b
    or c
    jr nz,_CWR_LOOP
    dec d
    jr nz,_CWR_ROUND
    pop de
    scf
    ret
_CWR_GOT:
    pop de
    call CH_GET_STATUS         ; A = raw status byte
    or a                       ; Cy=0
    ret

; ==========================================================================
; VDP direct text output (SCREEN 0, name table at VRAM 0000h).  DI-safe.
; ==========================================================================

; VDP_SETWR: set the VRAM write pointer to HL (name-table cell index).
VDP_SETWR:
    ld a,l
    out (VDP_CTRL),a
    ld a,h
    and 3Fh
    or 40h                     ; write-enable flag
    out (VDP_CTRL),a
    ret

; VDP_CLS: fill the whole name table with spaces.
VDP_CLS:
    ld hl,0
    call VDP_SETWR
    ld bc,SCR_CELLS
_VCLS:
    ld a,' '
    out (VDP_DATA),a
    nop
    nop
    dec bc
    ld a,b
    or c
    jr nz,_VCLS
    ret

; VPRINT: write the 00-terminated string at HL to the current VRAM pointer.
VPRINT:
    ld a,(hl)
    or a
    ret z
    out (VDP_DATA),a
    nop
    nop
    inc hl
    jr VPRINT

; --------------------------------------------------------------------------
; Screen composition helpers (all centred except the footer blocks).
; --------------------------------------------------------------------------

; VPRINT_CENTER: print the 00-terminated string HL centred on row E (0..23).
; Measures the string, computes the left column and prints it there.
VPRINT_CENTER:
    push hl                     ; keep the string pointer
    ld b,0                      ; B = length
_VPC_LEN:
    ld a,(hl)
    or a
    jr z,_VPC_GOT
    inc hl
    inc b
    jr _VPC_LEN
_VPC_GOT:
    ld a,SCR_COLS
    sub b
    srl a                       ; A = (80 - len)/2 = left column
    ld l,e
    ld h,0
    add hl,hl                   ; row*2
    push de
    ld d,h
    ld e,l
    add hl,hl
    add hl,hl                   ; row*8
    add hl,de                   ; row*8 + row*2 = row*10
    add hl,hl                   ; row*20
    add hl,hl                   ; row*40
    add hl,hl                   ; row*80
    pop de
    ld d,0
    ld e,a
    add hl,de                   ; HL = row*80 + column
    call VDP_SETWR
    pop hl                      ; restore string
    jp VPRINT

; MSG: refresh the message zone (row 12): blank it, then print HL centred.
MSG:
    push hl
    ld hl,ROW_MSG*SCR_COLS
    call CLR_ROW
    pop hl
    ld e,ROW_MSG
    jr VPRINT_CENTER

; CLR_ROW: fill the 80 cells of the row that starts at HL with spaces.
CLR_ROW:
    call VDP_SETWR
    ld b,SCR_COLS
_CLR_ROW:
    ld a,' '
    out (VDP_DATA),a
    nop
    nop
    djnz _CLR_ROW
    ret

; SHOW_TITLE: clear the screen and paint the two fixed banner lines.
SHOW_TITLE:
    call VDP_CLS
    ld hl,S_RECOV
    ld e,3
    call VPRINT_CENTER
    ld hl,S_PRODUCT
    ld e,5
    jp VPRINT_CENTER

; SHOW_FOOTER: the confirmation-screen footer (two column-anchored blocks).
SHOW_FOOTER:
    ld hl,FOOT_F1
    call VDP_SETWR
    ld hl,S_F1
    call VPRINT
    ld hl,FOOT_FLASH
    call VDP_SETWR
    ld hl,S_FLASHROM
    call VPRINT
    ld hl,FOOT_ESC
    call VDP_SETWR
    ld hl,S_ESC
    call VPRINT
    ld hl,FOOT_CANCEL
    call VDP_SETWR
    ld hl,S_CANCEL
    jp VPRINT

; SHOW_FLASH_SCREEN: base banner + "FLASHING ROM" + empty bar + red warning.
SHOW_FLASH_SCREEN:
    call SHOW_TITLE
    ld hl,S_FLASHING
    call MSG                    ; row 12
    ld hl,BAR_CELL
    call VDP_SETWR
    ld hl,S_BAR                 ; "[............] BANK 00"
    call VPRINT
    ; fall through to draw the red warning line

; SHOW_RED: the "DO NOT POWER OFF UNTIL DONE" warning line (row 21).
; Design decision 2026-07-09: plain white like the rest of the screen -
; the V9938 blink-colour trick was dropped (didn't show on real hardware
; with the first register recipe, and the designer prefers simplicity
; over debugging interrupts/attributes any further).
SHOW_RED:
    ld hl,S_REDLINE
    ld e,RED_ROW
    jp VPRINT_CENTER

; CLR_RED: drop the warning line.
CLR_RED:
    ld hl,RED_ROW*SCR_COLS
    jp CLR_ROW

; SET_BANK_CELL: put character C in the progress-bar cell of bank A (0..11).
; Preserves DE (the flash chunk loop relies on it).
SET_BANK_CELL:
    push bc
    ld hl,BANKCELL0
    add a,l
    ld l,a
    ld a,h
    adc a,0
    ld h,a                      ; HL = BANKCELL0 + bank
    call VDP_SETWR
    pop bc
    ld a,c
    out (VDP_DATA),a
    ret

; SHOW_BANKNUM: write the current bank number A (0..11) into "BANK NN".
SHOW_BANKNUM:
    push af
    ld hl,BANKNUM_CELL
    call VDP_SETWR
    pop af
    jp PUT2DEC

; VDP_SETREG: write value A into VDP control register E.
VDP_SETREG:
    out (VDP_CTRL),a
    ld a,e
    or 80h
    out (VDP_CTRL),a
    ret

; PUT2DEC: print A (0..99) as two decimal digits at the current VRAM pointer.
PUT2DEC:
    ld b,'0'
_P2_TENS:
    sub 10
    jr c,_P2_UNITS
    inc b
    jr _P2_TENS
_P2_UNITS:
    add a,10                   ; A = units, B = tens character
    push af
    ld a,b
    out (VDP_DATA),a
    nop
    nop
    pop af
    add a,'0'
    out (VDP_DATA),a
    nop
    nop
    ret

; WAIT_2S_OR_ESC: idle ~2 s; ESC aborts.
WAIT_2S_OR_ESC:
    ld b,40                    ; 40 * ~50 ms
_W2_LOOP:
    push bc
    ld bc,500                  ; 500 * 0.1 ms = ~50 ms
    call CH_DELAY
    ld a,7
    call SNSMAT
    bit 2,a
    jp z,DO_ABORT
    pop bc
    djnz _W2_LOOP
    ret

    ifdef RECOVERY_UITEST
; UITEST_MAIN: screen-only demo for the emulator.  The CH376 model does not
; implement the FILE / flash commands, so the real flashing screen is
; unreachable.  This paints the confirmation screen, holds it a few seconds,
; then paints the flashing screen frozen at a representative state and halts.
; Built into a throw-away ROM with -ds RECOVERY_UITEST; never shipped.
UITEST_MAIN:
    call SHOW_TITLE
    ld hl,S_FOUND
    call MSG
    call SHOW_FOOTER
    ld b,6                     ; ~3 s so the confirmation screen can be grabbed
_UT_HOLD:
    ld hl,0
_UT_HOLD2:
    dec hl
    ld a,h
    or l
    jr nz,_UT_HOLD2
    djnz _UT_HOLD
    ; flashing screen frozen at "[OOOOo.......] BANK 04"
    call SHOW_FLASH_SCREEN
    ld a,4
    call SHOW_BANKNUM
    xor a
    ld c,'O'
    call SET_BANK_CELL         ; bank 0 done
    ld a,1
    ld c,'O'
    call SET_BANK_CELL
    ld a,2
    ld c,'O'
    call SET_BANK_CELL
    ld a,3
    ld c,'O'
    call SET_BANK_CELL
    ld a,4
    ld c,'o'
    call SET_BANK_CELL         ; bank 4 in progress
    jp HALT_LOOP
    endif

; HALT_LOOP: nothing left to do (success or fatal error) -> wait for power off.
HALT_LOOP:
    di
    halt
    jr HALT_LOOP

; ==========================================================================
; Strings (part of the runtime; referenced at their RAM addresses).
; ==========================================================================
; Screen texts (2026 mock-up; the wording is final).
; --- fixed banner (rows 3 and 5) ---
S_RECOV:    db "RECOVERY SYSTEM",0
S_PRODUCT:  db "Hi-MD DREAM DRIVE",0
; --- message zone (row 12) ---
S_SEARCH:   db "Searching USB drive for DDFIRMWA.ROM...",0
S_NOCHIP:   db "ERROR: USB controller not responding.",0
S_NODEV:    db "Insert a USB drive (FAT). Retrying...",0
S_NOMOUNT:  db "Can't mount USB drive (not FAT / MiniDisc?).",0
S_NOFILE:   db "DDFIRMWA.ROM not found in root. Retrying...",0
S_BADSIZE:  db "DDFIRMWA.ROM is not 192K. Invalid file.",0
S_FOUND:    db "DDFIRMWA.ROM (192K) found and valid!",0
S_FLASHING: db "FLASHING ROM",0
S_REDLINE:  db "DO NOT POWER OFF UNTIL DONE",0
S_COMPLETE: db "DONE. Power off and on again.",0
S_FATAL:    db "Flash error. Power off and try again.",0
S_REREAD:   db "USB read failed: retrying whole file...",0
S_USBFAIL:  db "USB read error. Retry, or try another pendrive.",0
; --- confirmation footer (two column-anchored blocks) ---
S_F1:       db "F1",0
S_FLASHROM: db "FLASH ROM",0
S_ESC:      db "ESC",0
S_CANCEL:   db "Cancel",0
; --- flashing progress bar (row 14) ---
S_BAR:      db "[............] BANK 00",0
PULSE_TAB:  db ".oOo"                  ; heartbeat phases for the live bank
; --- row-21 blink bits: run of 27 cells from column 26 (see BLINK_BASE) ---
; cols 26-31=3Fh, 32-47=FFh FFh, 48-52=F8h; MSB is the left-most column.
; --- CH376 file name ---
S_FNAME:    db "/DDFIRMWA.ROM",0

; ==========================================================================
; Included CH376 layers (CODE: must live inside the phased region so their
; internal jumps resolve to the RAM run address).  We use CH_RESET_ALL,
; CH_SET_USB_MODE, CH_HW_TEST, CH_DELAY, CH_GET_STATUS, CH_READ_DATA
; (ch376.asm) and CHD_CONNECT, CHD_MOUNT (ch376_disk.asm).  The BOC / SCSI
; helpers in ch376_disk.asm assemble but are unused here.
; ==========================================================================
    include "ch376.asm"
    include "ch376_disk.asm"

RT_END:
    .dephase

RT_SIZE:    equ RT_END-RT_START        ; bytes to copy ROM -> RAM

; ==========================================================================
; Work RAM (page 3, absolute addresses; NOT part of the copied image - just
; scratch the runtime reads/writes).  Values are undefined at start-up.
; ==========================================================================
; --- required by the included CH376 layers ---
LAST_CH_STATUS:  equ WK+0       ; ch376.asm: last raw chip status
CH_WAIT_MULT:    equ WK+1       ; ch376.asm: INT-wait budget multiplier
CHD_CBW:         equ WK+2       ; ch376_disk.asm: 31-byte BULK_ONLY_CBW
CHD_DATA_PTR:    equ WK+33      ; 2
CHD_DATA_LEN:    equ WK+35      ; 2
CHD_DATA_DIR:    equ WK+37      ; 1
CHD_MOUNT_NAME:  equ WK+38      ; 36-byte DISK_MOUNT reply
CHD_WAIT_ROUNDS: equ WK+74      ; 1
CHD_PROBE:       equ WK+75      ; 1
_CDB_RW:         equ WK+76      ; 10 (READ10/WRITE10 template; unused here)
CTL_STAGE:       equ WK+86      ; 1: ch376.asm HW_CONTROL_TRANSFER stage (unused)

; --- our own recovery variables ---
CUR_BANK:        equ WK+87      ; 1: current flash bank (0..11)
BANKS_LEFT:      equ WK+88      ; 1: banks still to flash in this pass
RESTARTS:        equ WK+89      ; 1: whole-file restarts left
RD_DEST:         equ WK+90      ; 2: running destination for CH_READ_CHUNK
RD_REMAIN:       equ WK+92      ; 2: bytes still to read this chunk
; end of work RAM at WK+94; the stack (top RT_STACK=F000h) grows down towards
; it with ~5.9 KB of headroom, all well below the BIOS system area (F380h).
