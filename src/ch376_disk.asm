;
; ch376_disk.asm - CH376 "auto-pilot" (built-in Bulk-Only) layer
;                  for the MSX Hi-MD Drive project
;
; Copyright (c) 2019-2020 Nestor Soriano (Konamiman), Mario Smit (S0urceror)
; Copyright (c) 2026 MSX Hi-MD Drive project
;
; This program is free software: you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation, version 3.
;
; This program is distributed in the hope that it will be useful, but
; WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
; General Public License for more details.
;
; You should have received a copy of the GNU General Public License
; along with this program. If not, see <http://www.gnu.org/licenses/>.
;
; --------------------------------------------------------------------------
; The CH376 has a built-in USB-mass-storage "auto pilot": DISK_CONNECT and
; DISK_MOUNT enumerate + mount the attached device inside the chip firmware,
; and DISK_BOC_CMD runs an arbitrary raw Bulk-Only (SCSI) command for you.
; Leaning on the CH376's built-in Bulk-Only auto-pilot side-steps the real MSX
; hardware where our manual token-based enumeration (usb_enum.asm) hits a
; DATA-IN STALL on the very first GET_DESCRIPTOR. HIMDTEST pivots to this path;
; the manual path stays as a secondary diagnostic probe.
;
; Protocol reference (WCH CH376 datasheet + CH376INC.H BULK_ONLY_CBW struct):
;
;   CMD_DISK_CONNECT (30h): the chip waits for a mass-storage device to be
;       connected/ready and raises INT with USB_INT_SUCCESS (14h) when ready.
;
;   CMD_DISK_MOUNT (31h): mount the device (the chip runs INQUIRY internally).
;       INT = USB_INT_SUCCESS; RD_USB_DATA0 then returns a ~36-byte identifier.
;       On a mechanical Hi-MD this can take seconds and often needs retries
;       (RookieDrive's HWF_MOUNT_DISK retries too), so CHD_MOUNT loops.
;
;   CMD_DISK_BOC_CMD (50h): "execute a Bulk-Only transport command". Per the
;       datasheet the host FIRST writes the 31-byte BULK_ONLY_CBW via
;       CMD_WR_HOST_DATA (2Ch), THEN issues CMD_DISK_BOC_CMD. The chip runs
;       the full CBW -> DATA -> CSW transaction internally. The BULK_ONLY_CBW
;       is the standard 31-byte BOT CBW:
;           +0  dCBWSignature   55 53 42 43 ("USBC")
;           +4  dCBWTag         (4 bytes)
;           +8  dCBWDataLen     (4 bytes, little-endian)
;           +12 bmCBWFlags      80h = IN (read), 00h = OUT (write)
;           +13 bCBWLUN         (0)
;           +14 bCBWCBLength    (CDB length, e.g. 6 / 10)
;           +15 CBWCB[16]       (the raw SCSI CDB)
;       The chip signals the data stage with:
;           USB_INT_DISK_READ  (1Dh): a data block (<=64 bytes) is ready; read
;               it with RD_USB_DATA0, then CMD_DISK_RD_GO (55h) for the next.
;           USB_INT_DISK_WRITE (1Eh): the chip wants the next write block; send
;               it with WR_HOST_DATA, then CMD_DISK_WR_GO (57h).
;           USB_INT_SUCCESS    (14h): the command finished (CSW OK).
;           USB_INT_DISK_ERR   (1Fh): the command failed (CSW != 0).
;
; Style matches the rest of the project: no BDOS, all mutable state in the
; includer's work RAM, every INT wait bounded by CH_WAIT_INT_AND_GET_RESULT's
; 16-bit timeout, and USB transactions wrapped in di/ei by the caller.
;
; Requires these work-RAM labels from the includer (himdtest_workram.asm):
;   CHD_CBW        ds 31   ; BULK_ONLY_CBW build area
;   CHD_DATA_PTR   dw      ; data-stage buffer pointer
;   CHD_DATA_LEN   dw      ; data-stage byte length
;   CHD_DATA_DIR   db      ; 0 = OUT, 1 = IN
;   CHD_MOUNT_NAME ds 36   ; DISK_MOUNT reply
; plus LAST_CH_STATUS (set by CH_WAIT_INT_AND_GET_RESULT for diagnostics).
; --------------------------------------------------------------------------

; ==========================================================================
; CHD_CONNECT
; Issue CMD_DISK_CONNECT and wait for the chip to report the device ready.
; Mirrors the start of RookieDrive's HWF_MOUNT_DISK: DISK_CONNECT, then leave
; the chip in host mode (6) ready for DISK_MOUNT.
; Output: Cy = 0 device connected/ready
;         Cy = 1 error (A = USB error code; raw chip status in LAST_CH_STATUS)
; Corrupts: AF, BC
; ==========================================================================
CHD_CONNECT:
    ld a,CH_CMD_DISK_CONNECT
    out (CH_COMMAND_PORT),a
    call CH_WAIT_INT_AND_GET_RESULT
    ret c                        ; timeout / STALL / etc.
    cp USB_ERR_OK
    jr z,_CHD_CONNECT_OK
    scf
    ret
_CHD_CONNECT_OK:
    ; ensure normal host mode (with SOF) before mounting: the chip wants it
    ; between DISK_CONNECT and DISK_MOUNT
    ld a,CH_MODE_HOST
    call CH_SET_USB_MODE
    ret c
    or a                         ; Cy = 0
    ret

; ==========================================================================
; CHD_MOUNT
; Issue CMD_DISK_MOUNT with retries. The chip enumerates + runs INQUIRY
; internally; on success RD_USB_DATA0 returns a ~36-byte identifier which we
; keep in CHD_MOUNT_NAME for diagnostics. Retried CHD_MOUNT_RETRIES times with
; a ~200 ms pause between attempts (multi-second spin-up budget for the Hi-MD).
; Output: Cy = 0 mounted (CHD_MOUNT_NAME filled)
;         Cy = 1 error after all retries (A = last USB error / status)
; Corrupts: AF, BC, DE, HL
; ==========================================================================
CHD_MOUNT:
    ld b,CHD_MOUNT_RETRIES
_CHD_MOUNT_TRY:
    push bc
    ld a,CH_CMD_DISK_MOUNT
    out (CH_COMMAND_PORT),a
    call CH_WAIT_INT_AND_GET_RESULT
    jr c,_CHD_MOUNT_WAIT         ; timeout: retry
    cp USB_ERR_OK
    jr z,_CHD_MOUNT_OK
_CHD_MOUNT_WAIT:
    ifdef CH_WAIT_HOOKED
    ld a,(WAKE_ABORT)            ; the driver's bring-up session was
    or a                         ;  abandoned (ESC / time cap): no more
    jr z,_CHD_MOUNT_GO           ;  tries (see CH_WAIT_INT_AND_GET_RESULT)
    pop bc
    scf
    ret
_CHD_MOUNT_GO:
    endif
    ; not ready yet: pause, then retry if attempts remain
    ld bc,CHD_MOUNT_PAUSE
    call CH_DELAY
    pop bc
    djnz _CHD_MOUNT_TRY
    scf                          ; exhausted
    ret
_CHD_MOUNT_OK:
    pop bc
    ; read the mount reply (device identifier) into CHD_MOUNT_NAME
    ld hl,CHD_MOUNT_NAME
    call CH_READ_DATA            ; C = bytes read (chip caps at its buffer size)
    or a                         ; Cy = 0
    ret

; ==========================================================================
; CHD_BOC_CMD
; Run one arbitrary SCSI CDB through the CH376 auto-pilot (DISK_BOC_CMD).
; Builds a 31-byte BULK_ONLY_CBW, hands it to the chip, then services the
; data stage in 64-byte blocks. Supports data lengths of 2048+ bytes.
;
; Input:  HL = pointer to the CDB
;         B  = CDB length (6 / 10 / 12 / 16)
;         DE = data transfer length in bytes (0 if none)
;         IX = data buffer (dest for IN, source for OUT)
;         C  = direction: 0 = data OUT (write), 1 = data IN (read)
; Output: Cy = 0 success (command completed, CSW OK)
;         Cy = 1 failure (A = USB error / chip status; see LAST_CH_STATUS)
; Corrupts: everything
; --------------------------------------------------------------------------
CHD_BOC_CMD:
    ; --- stash the caller parameters that we cannot keep in registers ---
    ld a,0FFh
    ld (CHD_PROBE),a             ; FFh = probe not performed
    ld a,c
    ld (CHD_DATA_DIR),a          ; direction
    ld (CHD_DATA_LEN),de         ; data length
    push ix
    pop de
    ld (CHD_DATA_PTR),de         ; data buffer pointer
    push hl                      ; CDB pointer (needed after building header)
    push bc                      ; B = CDB length

    ; --- build BULK_ONLY_CBW header in CHD_CBW ---
    ; signature "USBC"
    ld hl,_CHD_CBW_SIG
    ld de,CHD_CBW
    ld bc,4
    ldir
    ; tag: a fixed non-zero value is fine (the chip owns the transport)
    ld hl,CHD_CBW+4
    ld (hl),01h
    inc hl
    ld (hl),0
    inc hl
    ld (hl),0
    inc hl
    ld (hl),0
    ; dCBWDataTransferLength (4 bytes LE) from CHD_DATA_LEN (16-bit) + 0,0
    ld hl,(CHD_DATA_LEN)
    ld (CHD_CBW+8),hl
    xor a
    ld (CHD_CBW+10),a
    ld (CHD_CBW+11),a
    ; bmCBWFlags: 80h for IN, 00h for OUT
    ld a,(CHD_DATA_DIR)
    or a
    ld a,0
    jr z,_CHD_FLAGS_SET
    ld a,CBW_FLAG_IN
_CHD_FLAGS_SET:
    ld (CHD_CBW+12),a
    ; bCBWLUN = 0
    xor a
    ld (CHD_CBW+13),a
    ; bCBWCBLength = CDB length
    pop bc                       ; B = CDB length
    ld a,b
    ld (CHD_CBW+14),a
    ; clear the 16-byte CDB area, then copy the CDB in
    push bc
    ld hl,CHD_CBW+15
    ld de,CHD_CBW+16
    ld bc,15
    ld (hl),0
    ldir
    pop bc
    pop hl                       ; HL = CDB source
    ld de,CHD_CBW+15
    ld c,b
    ld b,0
    ldir                         ; copy C bytes of CDB

    ; --- hand the CBW to the chip: WR_HOST_DATA(31), then DISK_BOC_CMD ---
    ld hl,CHD_CBW
    ld b,31
    call CH_WRITE_DATA
    ld a,CH_CMD_DISK_BOC_CMD
    out (CH_COMMAND_PORT),a

    ; --- service the data stage until the chip reports completion ---
    ; PROTOCOL (verified 07-2026 against WCH CH376DS1 §5.36, cpctools ch376.i,
    ; cross-checked with the CocoaMSX CH376 model):
    ;
    ;   CMD_DISK_BOC_CMD (50h) runs the WHOLE Bulk-Only transaction internally
    ;   (CBW -> DATA -> CSW). It raises a SINGLE final interrupt:
    ;       USB_INT_SUCCESS (14h) -> CSW OK; IN data (if any) waits in the chip
    ;                                buffer, fetched with RD_USB_DATA0.
    ;       USB_INT_DISK_ERR (1Fh) / STALL / timeout -> failure.
    ;   It does NOT drive the 1Dh + DISK_RD_GO(55h) streaming loop: THAT belongs
    ;   to the separate CMD_DISK_READ (54h), which is unusable here because it
    ;   hardcodes 512-byte sectors (ERR_LARGE_SECTOR 84h on a 2048-byte Hi-MD).
    ;
    ;   Our earlier code waited for 1Dh FIRST and hung ~30 s with ZERO INTs on
    ;   real hardware for a 2048-byte READ(10). Short transfers (INQUIRY 36 B,
    ;   READ CAPACITY 8 B) worked only because one 64-byte drain sufficed.
    ;
    ;   Correct long IN flow: wait 14h -> drain 64 B via RD_USB_DATA0 -> if bytes
    ;   remain AND the block was full (64 B) -> DISK_RD_GO(55h), wait for the next
    ;   14h, drain again -> repeat until the length is satisfied or a short block
    ;   (< 64 B) signals the end of the payload.
    ;
    ;   1Dh/1Eh are still accepted (defensively) as "block available" so this one
    ;   routine also drives an emulator that models the streaming variant.
    ;
    ; CH_WAIT_INT_AND_GET_RESULT returns A = USB error code and translates
    ; 14h -> USB_ERR_OK; 1Dh/1Eh/1Fh are NOT in its OK set, so it returns them as
    ; "unexpected" with Cy=1. We therefore inspect the RAW status byte it stashes
    ; in LAST_CH_STATUS instead of its translated code.
    ;
_CHD_BOC_LOOP:
    ; Wait budget: 8 rounds of ~1.28 s (~10 s total). A single 1.28 s wait is
    ; not enough for MECHANICAL operations: the MiniDisc has to spin up and
    ; seek before the first data block of a READ(10) arrives.
    ld a,8
    ld (CHD_WAIT_ROUNDS),a
_CHD_BOC_WAIT:
    ; Clear the stashed raw status BEFORE waiting: if the INT wait times out,
    ; CH_WAIT_INT never reaches GET_STATUS and LAST_CH_STATUS would otherwise
    ; keep a stale value (e.g. the 14h from DISK_MOUNT), turning a timeout
    ; into a false success. A cleared 0 falls through to the failure branch.
    xor a
    ld (LAST_CH_STATUS),a
    call CH_WAIT_INT_AND_GET_RESULT
    ; A = translated code, LAST_CH_STATUS = raw chip status (0 on timeout).
    ld a,(LAST_CH_STATUS)
    or a
    jr nz,_CHD_BOC_GOT
    ifdef CH_WAIT_HOOKED
    ld a,(WAKE_ABORT)            ; the driver's bring-up session was
    or a                         ;  abandoned: no further rounds
    jr nz,_CHD_BOC_TIMEOUT
    endif
    ld a,(CHD_WAIT_ROUNDS)
    dec a
    ld (CHD_WAIT_ROUNDS),a
    jr nz,_CHD_BOC_WAIT
    ; Exhausted with ZERO interrupts. PROBE (diagnostic): maybe the chip has
    ; the data silently waiting in its buffer without raising INT for >64-byte
    ; BOC transfers. Try one blind RD_USB_DATA0 and record how many bytes it
    ; had (CHD_PROBE); HIMDTEST prints it so the real protocol reveals itself.
    ld a,(CHD_DATA_DIR)
    or a
    jr z,_CHD_BOC_TIMEOUT        ; OUT: nothing to probe
    ld hl,(CHD_DATA_PTR)
    call CH_READ_DATA            ; C = bytes the chip was holding (0..64)
    ld a,c
    ld (CHD_PROBE),a
_CHD_BOC_TIMEOUT:
    xor a                        ; exhausted: report clean timeout (A=0, st=0)
    scf
    ret
_CHD_BOC_GOT:
    cp CH_ST_INT_SUCCESS
    jr z,_CHD_BOC_DONE
    cp CH_ST_INT_DISK_READ
    jr z,_CHD_BOC_READ_BLOCK
    cp CH_ST_INT_DISK_WRITE
    jp z,_CHD_BOC_WRITE_BLOCK
    ; anything else (DISK_ERR 1Fh, STALL 2Eh, timeout, ...) is a failure
    scf
    ret

; ---- 14h: the chip has staged the next data block (or finished). Each 14h in
;      an IN transfer means "a block is waiting in the buffer": drain it, and if
;      more is expected and this block was full (64 B), DISK_RD_GO to stage the
;      next one and wait for the next 14h. (The chip raises ONE 14h per staged
;      block for DISK_BOC_CMD; it does NOT use the 1Dh streaming of DISK_READ.)
_CHD_BOC_DONE:
    ld a,(CHD_DATA_DIR)
    or a
    jr z,_CHD_BOC_OK             ; OUT / no-data: CSW OK -> done
    ld hl,(CHD_DATA_LEN)
    ld a,h
    or l
    jr z,_CHD_BOC_OK             ; nothing pending: done
_CHD_BOC_DRAIN:
    ; read one 64-byte block out of the chip buffer
    ld hl,(CHD_DATA_PTR)
    call CH_READ_DATA            ; C = bytes read (0..64), B = 0
    ; advance pointer by C and shrink remaining by C (clamp at 0)
    push bc
    ld b,0                       ; BC = bytes read
    ld hl,(CHD_DATA_PTR)
    add hl,bc
    ld (CHD_DATA_PTR),hl
    ld hl,(CHD_DATA_LEN)
    or a
    sbc hl,bc
    jr nc,_CHD_DRAIN_LEN_OK
    ld hl,0                      ; underflow guard
_CHD_DRAIN_LEN_OK:
    ld (CHD_DATA_LEN),hl
    pop bc                       ; C = this block's length
    ; done if the payload is satisfied...
    ld a,h
    or l
    jr z,_CHD_BOC_OK2
    ; ...or if this block was SHORT (< 64 B): a short packet ends the transfer
    ld a,c
    cp 64
    jr c,_CHD_BOC_OK2            ; short block -> no more data even if len>0
    ; more data expected and the block was full: continue to the next block.
    ; DISK_RD_GO now, then wait for the chip's next completion INT.
    ld a,CH_CMD_DISK_RD_GO
    out (CH_COMMAND_PORT),a
    jp _CHD_BOC_LOOP
_CHD_BOC_OK:
    ; Success only if the whole expected IN payload arrived; otherwise report
    ; a short transfer (A = 0FEh) so PASS can never hide an empty buffer.
    ld a,(CHD_DATA_DIR)
    or a
    jr z,_CHD_BOC_OK2
    ld hl,(CHD_DATA_LEN)
    ld a,h
    or l
    jr z,_CHD_BOC_OK2
    ld a,0FEh                    ; short transfer: got fewer bytes than asked
    scf
    ret
_CHD_BOC_OK2:
    xor a                        ; Cy = 0, success
    ret

; ---- 1Dh (emulator / streaming variant): a block is ready to read. Same as
;      a drain, then DISK_RD_GO. Reuse the drain path so both firmwares work.
_CHD_BOC_READ_BLOCK:
    ld hl,(CHD_DATA_PTR)
    call CH_READ_DATA            ; C = bytes read (0..64), B = 0
    ; advance the stored pointer by C
    ld b,0
    ld hl,(CHD_DATA_PTR)
    add hl,bc
    ld (CHD_DATA_PTR),hl
    ; decrement remaining length by C (clamp at 0)
    ld hl,(CHD_DATA_LEN)
    or a
    sbc hl,bc
    jr nc,_CHD_RD_LEN_OK
    ld hl,0                      ; underflow guard
_CHD_RD_LEN_OK:
    ld (CHD_DATA_LEN),hl
    ; tell the chip to continue to the next block
    ld a,CH_CMD_DISK_RD_GO
    out (CH_COMMAND_PORT),a
    jp _CHD_BOC_LOOP

; ---- OUT: chip wants the next write block: send <=64 bytes, then WR_GO ------
_CHD_BOC_WRITE_BLOCK:
    ; length of this block = min(remaining, 64)
    ld hl,(CHD_DATA_LEN)
    ld a,h
    or a
    ld a,64
    jr nz,_CHD_WR_FULL           ; remaining >= 256 -> full 64-byte block
    ld a,l
    cp 64
    jr nc,_CHD_WR_FULL           ; remaining >= 64 -> full block
    ld a,l                       ; remaining < 64 -> send the remainder
_CHD_WR_FULL:
    ; A = this block length
    ld b,a                       ; B = length for CH_WRITE_DATA
    push bc
    ld hl,(CHD_DATA_PTR)
    call CH_WRITE_DATA           ; writes B bytes, HL advanced
    pop bc
    ; advance pointer and shrink remaining by B
    ld a,b
    ld c,a
    ld b,0
    ld hl,(CHD_DATA_PTR)
    add hl,bc
    ld (CHD_DATA_PTR),hl
    ld hl,(CHD_DATA_LEN)
    or a
    sbc hl,bc
    jr nc,_CHD_WR_LEN_OK
    ld hl,0
_CHD_WR_LEN_OK:
    ld (CHD_DATA_LEN),hl
    ; continue to the next block
    ld a,CH_CMD_DISK_WR_GO
    out (CH_COMMAND_PORT),a
    jp _CHD_BOC_LOOP

_CHD_CBW_SIG:  db 55h,53h,42h,43h   ; "USBC"

; ==========================================================================
; Thin SCSI wrappers over CHD_BOC_CMD, mirroring scsi.asm's manual-path API so
; HIMDTEST can call the same command shapes through the auto-pilot. Each builds
; a CDB then calls CHD_BOC_CMD. CDBs are constant (OK in ROM); READ10/WRITE10
; build their CDB in the shared _CDB_RW work-RAM area (defined for scsi.asm).
; ==========================================================================

; CHD_INQUIRY: IX = 36-byte buffer. Cy = 0 OK.
CHD_INQUIRY:
    ld hl,_CHD_CDB_INQUIRY
    ld b,6
    ld de,36
    ld c,1                       ; IN
    call CHD_BOC_CMD
    ret
_CHD_CDB_INQUIRY: db SCSI_OP_INQUIRY,0,0,0,36,0

; CHD_TEST_UNIT_READY: no data. Cy = 0 ready.
CHD_TEST_UNIT_READY:
    ld hl,_CHD_CDB_TUR
    ld b,6
    ld de,0
    ld c,0
    ld ix,0
    call CHD_BOC_CMD
    ret
_CHD_CDB_TUR: db SCSI_OP_TEST_UNIT_READY,0,0,0,0,0

; CHD_START_UNIT: SCSI START STOP UNIT with START=1 (spin the mechanism up).
; Operating systems send this before reading; a Sony Hi-MD refuses READ(10)
; ("CANNOT READ OR PLAY", no ACCESS light) until it arrives. No data stage.
; Immed=0: the command completes only once the unit is spun up (can take
; seconds; covered by the BOC wait budget). Cy = 0 OK.
CHD_START_UNIT:
    ld hl,_CHD_CDB_START
    ld b,6
    ld de,0
    ld c,0
    ld ix,0
    call CHD_BOC_CMD
    ret
_CHD_CDB_START: db 1Bh,0,0,0,01h,0   ; START STOP UNIT, LoEj=0 Start=1

; CHD_REQUEST_SENSE: IX = 18-byte buffer. Cy = 0 OK.
CHD_REQUEST_SENSE:
    ld hl,_CHD_CDB_REQ_SENSE
    ld b,6
    ld de,18
    ld c,1                       ; IN
    call CHD_BOC_CMD
    ret
_CHD_CDB_REQ_SENSE: db SCSI_OP_REQUEST_SENSE,0,0,0,18,0

; CHD_READ_CAPACITY: IX = 8-byte buffer. Cy = 0 OK.
CHD_READ_CAPACITY:
    ld hl,_CHD_CDB_READ_CAP
    ld b,10
    ld de,8
    ld c,1                       ; IN
    call CHD_BOC_CMD
    ret
_CHD_CDB_READ_CAP: db SCSI_OP_READ_CAPACITY,0,0,0,0,0,0,0,0,0

; CHD_READ10: IX = dest, BC = block count, DE = byte length, HL = 4-byte BE LBA.
; Cy = 0 OK. Builds the CDB in _CDB_RW (shared work RAM with scsi.asm).
CHD_READ10:
    push de
    push bc
    ld a,SCSI_OP_READ10
    ld (_CDB_RW+0),a
    xor a
    ld (_CDB_RW+1),a
    ld de,_CDB_RW+2
    ld bc,4
    ldir                         ; LBA (big-endian) from HL
    xor a
    ld (_CDB_RW+6),a
    pop bc                       ; block count
    ld a,b
    ld (_CDB_RW+7),a
    ld a,c
    ld (_CDB_RW+8),a
    xor a
    ld (_CDB_RW+9),a
    pop de                       ; byte length
    ld hl,_CDB_RW
    ld b,10
    ld c,1                       ; IN
    call CHD_BOC_CMD
    ret

; CHD_WRITE10: same interface as CHD_READ10 but IX = source. Cy = 0 OK.
CHD_WRITE10:
    push de
    push bc
    ld a,SCSI_OP_WRITE10
    ld (_CDB_RW+0),a
    xor a
    ld (_CDB_RW+1),a
    ld de,_CDB_RW+2
    ld bc,4
    ldir
    xor a
    ld (_CDB_RW+6),a
    pop bc
    ld a,b
    ld (_CDB_RW+7),a
    ld a,c
    ld (_CDB_RW+8),a
    xor a
    ld (_CDB_RW+9),a
    pop de
    ld hl,_CDB_RW
    ld b,10
    ld c,0                       ; OUT
    call CHD_BOC_CMD
    ret
