;
; scsi.asm - SCSI Bulk-Only Transport for the MSX Hi-MD Drive project
;
; Copyright (c) 2020 Mario Smit (S0urceror)
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
; Derived from scsi.asm / scsi_helpers.asm (MSX-USB), ported to Nestor80 and
; simplified for Fase 0:
;   * No structs: CBW is built by hand with EQU offsets (constants.asm).
;   * READ CAPACITY(10) added (does NOT exist in MSX-USB).
;   * The 512-byte sector-size assumption of MSX-USB's SCSI_READ/WRITE is
;     replaced: DEV_READ takes an explicit byte length so the caller decides
;     the physical block size (2048 expected for Hi-MD).
;   * No BDOS. Requires these work-RAM labels from the includer:
;       SCSI_TAG          db     ; incrementing CBW tag (init to 1)
;       SCSI_CBW          ds 31  ; CBW build area
;       SCSI_CSW          ds 13  ; CSW receive area
;     plus all USB_* labels from usb_enum.asm.
; --------------------------------------------------------------------------

; ==========================================================================
; SCSI_DO_CMD
; Execute one Bulk-Only transaction: send CBW, do the data stage, read CSW.
; Input:  HL = pointer to the CDB
;         B  = CDB length (6/10/...)
;         DE = data transfer length in bytes (0 if none)
;         IX = data buffer (source for write, dest for read)
;         C  = direction: 0 = data OUT (write), 1 = data IN (read)
; Output: A  = CSW bStatus (0 = OK) when Cy = 0
;         Cy = 1 on transport error OR CSW status != 0
;              (on transport error A = USB error code, high bit-ish; caller
;               should treat any Cy=1 as failure and issue REQUEST SENSE)
;         _SCSI_DATA_LEN = bytes actually received in a data-IN stage (a
;              READ(10) caller checks it: a short data stage is no success)
; Corrupts: everything
; --------------------------------------------------------------------------
; STALL recovery (BOT spec 6.7.2/6.7.3, as Linux usb-storage does): a device
; that cannot deliver the data of a command - typically a CD/DVD drive behind
; a USB bridge hitting an unreadable sector - may end the data stage with a
; STALL of the pipe. The command is not lost: the host clears the halt
; (CLEAR_FEATURE(ENDPOINT_HALT), toggle back to DATA0) and reads the CSW,
; which reports the failure; REQUEST SENSE then works and tells why. Before,
; the CSW was never read, so the REQUEST SENSE that followed met a halted
; pipe, failed, and a mere bad sector looked like a dead transport (bus reset
; + full re-init). A STALLed CSW read is cleared and read once more.
; ==========================================================================
SCSI_DO_CMD:
    ; save params
    ld (_SCSI_DATA_BUF),ix
    ld (_SCSI_DATA_LEN),de
    ld a,c
    ld (_SCSI_DIR),a
    ; --- build CBW ---
    push hl
    push bc
    ; signature "USBC"
    ld hl,_SCSI_CBW_SIG
    ld de,SCSI_CBW
    ld bc,4
    ldir
    ; tag (4 bytes: use SCSI_TAG then 0,0,0)
    ld a,(SCSI_TAG)
    ld (SCSI_CBW+CBW_dTag),a
    ld (_SCSI_SENT_TAG),a       ; kept to match against the CSW echo
    xor a
    ld (SCSI_CBW+CBW_dTag+1),a
    ld (SCSI_CBW+CBW_dTag+2),a
    ld (SCSI_CBW+CBW_dTag+3),a
    ld a,(SCSI_TAG)
    inc a
    ld (SCSI_TAG),a
    ; dDataTransferLength (4 bytes LE)
    ld hl,(_SCSI_DATA_LEN)
    ld (SCSI_CBW+CBW_dDataTransferLength),hl
    xor a
    ld (SCSI_CBW+CBW_dDataTransferLength+2),a
    ld (SCSI_CBW+CBW_dDataTransferLength+3),a
    ; flags
    ld a,(_SCSI_DIR)
    or a
    ld a,0
    jr z,_SCSI_FLAGS_SET
    ld a,CBW_FLAG_IN
_SCSI_FLAGS_SET:
    ld (SCSI_CBW+CBW_bmFlags),a
    ; LUN = 0
    xor a
    ld (SCSI_CBW+CBW_bLUN),a
    ; CB length
    pop bc                      ; B = CDB length
    ld a,b
    ld (SCSI_CBW+CBW_bCBLength),a
    ; clear CDB area then copy CDB
    push bc
    ld hl,SCSI_CBW+CBW_CDB
    ld de,SCSI_CBW+CBW_CDB+1
    ld bc,15
    ld (hl),0
    ldir
    pop bc
    pop hl                      ; HL = CDB source
    ld de,SCSI_CBW+CBW_CDB
    ld c,b
    ld b,0
    ldir                        ; copy CDB (C bytes)
    ; --- send CBW (31 bytes) over bulk OUT ---
    ld hl,SCSI_CBW
    ld bc,CBW_SIZE
    ld a,(USB_BULK_MAXPKT)
    ld d,a
    ld a,(USB_BULK_OUT_EP)
    ld e,a
    ld a,(USB_BULK_OUT_TOG)
    rla                         ; toggle bit7 -> Cy
    ld a,(USB_DEV_ADDR)
    call HW_DATA_OUT_TRANSFER
    push af                     ; error code
    ld a,0
    rra                         ; Cy -> bit7
    ld (USB_BULK_OUT_TOG),a
    pop af
    and a
    jp nz,_SCSI_XPORT_ERR
    ; --- data stage ---
    ld hl,(_SCSI_DATA_LEN)
    ld a,h
    or l
    jr z,_SCSI_CSW              ; no data
    ld a,(_SCSI_DIR)
    or a
    jr z,_SCSI_DATA_OUT
_SCSI_DATA_IN:
    ld ix,(_SCSI_DATA_BUF)
    push ix
    pop hl
    ld bc,(_SCSI_DATA_LEN)
    ld a,(USB_BULK_MAXPKT)
    ld d,a
    ld a,(USB_BULK_IN_EP)
    ld e,a
    ld a,(USB_BULK_IN_TOG)
    rla
    ld a,(USB_DEV_ADDR)
    call HW_DATA_IN_TRANSFER
    push af
    ld a,0
    rra
    ld (USB_BULK_IN_TOG),a
    pop af
    ld (_SCSI_DATA_LEN),bc      ; bytes actually received (see Output)
    and a
    jr z,_SCSI_CSW
    ld c,80h                    ; a STALL here halted the bulk IN pipe
    jr _SCSI_DSTALL
_SCSI_DATA_OUT:
    ld ix,(_SCSI_DATA_BUF)
    push ix
    pop hl
    ld bc,(_SCSI_DATA_LEN)
    ld a,(USB_BULK_MAXPKT)
    ld d,a
    ld a,(USB_BULK_OUT_EP)
    ld e,a
    ld a,(USB_BULK_OUT_TOG)
    rla
    ld a,(USB_DEV_ADDR)
    call HW_DATA_OUT_TRANSFER
    push af
    ld a,0
    rra
    ld (USB_BULK_OUT_TOG),a
    pop af
    and a
    jr z,_SCSI_CSW
    ld c,0                      ; a STALL here halted the bulk OUT pipe
_SCSI_DSTALL:
    ; data stage failed: a STALL is the device's way to end it early - clear
    ; the halt and go read the CSW; anything else is a transport error
    cp USB_ERR_STALL
    jr nz,_SCSI_XPORT_ERR
    call SCSI_CLEAR_HALT
    jr c,_SCSI_XPORT_ERR
_SCSI_CSW:
    ; --- read CSW (13 bytes) over bulk IN ---
    ld a,1                      ; one more read allowed after a STALL
_SCSI_CSW_RD:
    push af
    ld hl,SCSI_CSW
    ld bc,CSW_SIZE
    ld a,(USB_BULK_MAXPKT)
    ld d,a
    ld a,(USB_BULK_IN_EP)
    ld e,a
    ld a,(USB_BULK_IN_TOG)
    rla
    ld a,(USB_DEV_ADDR)
    call HW_DATA_IN_TRANSFER
    push af
    ld a,0
    rra
    ld (USB_BULK_IN_TOG),a
    pop af
    pop bc                      ; B = CSW reads still allowed after a STALL
    and a
    jr z,_SCSI_CSW_GOT
    cp USB_ERR_STALL
    jr nz,_SCSI_XPORT_ERR
    inc b
    dec b
    jr z,_SCSI_XPORT_ERR        ; STALLed twice: give up (A = USB_ERR_STALL)
    ld c,80h
    call SCSI_CLEAR_HALT
    jr c,_SCSI_XPORT_ERR
    xor a                       ; no further retry
    jr _SCSI_CSW_RD
_SCSI_CSW_GOT:
    ; validate CSW signature "USBS" (a corrupt/desynced CSW with bStatus=0
    ; must not be accepted as success)
    ld hl,SCSI_CSW+CSW_dSignature
    ld de,_SCSI_CSW_SIG
    ld b,4
_SCSI_CSW_SIGCHK:
    ld a,(de)
    cp (hl)
    jr nz,_SCSI_CSW_BAD
    inc hl
    inc de
    djnz _SCSI_CSW_SIGCHK
    ; validate tag: byte 0 must echo the CBW tag, bytes 1-3 must be 0
    ld a,(_SCSI_SENT_TAG)
    ld hl,SCSI_CSW+CSW_dTag
    cp (hl)
    jr nz,_SCSI_CSW_BAD
    inc hl
    ld a,(hl)
    inc hl
    or (hl)
    inc hl
    or (hl)
    jr nz,_SCSI_CSW_BAD
    ; validate CSW status
    ld a,(SCSI_CSW+CSW_bStatus)
    or a
    jr nz,_SCSI_CSW_FAIL
    xor a                       ; A=0, Cy=0
    ret
_SCSI_CSW_BAD:
    ld a,USB_ERR_UNEXPECTED     ; malformed/mismatched CSW
    scf
    ret
_SCSI_CSW_FAIL:
    ; A = CSW status (1 or 2), report failure
    scf
    ret
_SCSI_XPORT_ERR:
    ; A = USB error code; flag failure
    scf
    ret

; ==========================================================================
; SCSI_CLEAR_HALT - CLEAR_FEATURE(ENDPOINT_HALT) on a bulk pipe (standard
; control request, the same EP0 path as the enumeration) and reset that
; pipe's data toggle to DATA0, as the device does.
; Input:  C = 80h bulk IN / 00h bulk OUT
; Output: Cy = 0 OK; Cy = 1 with A = USB error code
; Corrupts: everything
; ==========================================================================
SCSI_CLEAR_HALT:
    ifdef LEV_HALT
    call SCSI_CLEAR_HALT_Q
    call LOG_EVT                ; CALL DREAM LOG "B HALT ok/fail" (driver only;
    db 'B'+80h,LEV_HALT         ;  keeps every register and flag)
    ret
; SCSI_CLEAR_HALT_Q - the same, without the log line (driver v3.3.6: the
; Bulk-Only reset recovery of RQS_RETRY clears both pipes as a routine step)
SCSI_CLEAR_HALT_Q:
    endif
    push bc
    ld hl,_SCSI_SETUP_CLRH
    ld de,USB_SETUP_BUF
    ld bc,8
    ldir                        ; (setup packets are patched in RAM, never ROM)
    pop bc
    ld a,c
    or a
    ld a,(USB_BULK_OUT_EP)
    jr z,_SCH_EP
    ld a,(USB_BULK_IN_EP)
    or 80h                      ; IN endpoint address
_SCH_EP:
    ld (USB_SETUP_BUF+4),a      ; wIndex = endpoint address
    push bc
    ld hl,USB_SETUP_BUF
    ld de,USB_DESC_BUF          ; (no data stage: wLength = 0)
    ld a,(USB_EP0_SIZE)
    ld b,a
    ld a,(USB_DEV_ADDR)
    call HW_CONTROL_TRANSFER
    pop bc
    or a                        ; A = USB error code, Cy=0
    jr z,_SCH_OK
    scf
    ret
_SCH_OK:
    ld a,c
    or a
    ld hl,USB_BULK_OUT_TOG
    jr z,_SCH_TOG
    ld hl,USB_BULK_IN_TOG
_SCH_TOG:
    ld (hl),0                   ; toggle back to DATA0
    xor a                       ; Cy=0
    ret

_SCSI_SETUP_CLRH: db 02h,01h,00h,00h,00h,00h,00h,00h  ; CLEAR_FEATURE(ENDPOINT_HALT)

_SCSI_CBW_SIG:  db 55h,53h,42h,43h   ; "USBC" (constant: OK in ROM)
_SCSI_CSW_SIG:  db 55h,53h,42h,53h   ; "USBS" (constant: OK in ROM)
; _SCSI_SENT_TAG (1), _SCSI_DATA_BUF (2), _SCSI_DATA_LEN (2), _SCSI_DIR (1)
; and _CDB_RW (10) are work RAM provided by the includer: they MUST NOT live
; here, this code may be in ROM.

; ==========================================================================
; SCSI_INQUIRY
; Input:  IX = 36-byte destination buffer
; Output: Cy = 0 OK
; ==========================================================================
SCSI_INQUIRY:
    ld hl,_CDB_INQUIRY
    ld b,6
    ld de,36                    ; allocation length 24h
    ld c,1                      ; IN
    call SCSI_DO_CMD
    ret

_CDB_INQUIRY: db SCSI_OP_INQUIRY,0,0,0,36,0

; ==========================================================================
; SCSI_TEST_UNIT_READY
; Output: Cy = 0 ready, Cy = 1 not ready / error (issue REQUEST SENSE)
; ==========================================================================
SCSI_TEST_UNIT_READY:
    ld hl,_CDB_TUR
    ld b,6
    ld de,0                     ; no data
    ld c,0
    ld ix,0
    call SCSI_DO_CMD
    ret

_CDB_TUR: db SCSI_OP_TEST_UNIT_READY,0,0,0,0,0

; ==========================================================================
; SCSI_START_UNIT
; START STOP UNIT with Start=1: spin the mechanism up. A Sony Hi-MD will
; accept but never service READ(10) until this arrives; note that a USB bus
; reset returns the device to the stopped state, so it must be re-sent after
; every re-enumeration. Immed=0: completes when the unit is spun up.
; Output: Cy = 0 OK
; ==========================================================================
SCSI_START_UNIT:
    ld hl,_CDB_START
    ld b,6
    ld de,0                     ; no data
    ld c,0
    ld ix,0
    call SCSI_DO_CMD
    ret

_CDB_START: db 1Bh,0,0,0,01h,0  ; START STOP UNIT, LoEj=0 Start=1

; ==========================================================================
; SCSI_STOP_UNIT
; START STOP UNIT with Start=0: spin the mechanism down (safe eject). Immed=0.
; Output: Cy = 0 OK
; ==========================================================================
SCSI_STOP_UNIT:
    ld hl,_CDB_STOP
    ld b,6
    ld de,0                     ; no data
    ld c,0
    ld ix,0
    call SCSI_DO_CMD
    ret

_CDB_STOP: db 1Bh,0,0,0,00h,0   ; START STOP UNIT, LoEj=0 Start=0

; ==========================================================================
; SCSI_EJECT_UNIT
; START STOP UNIT with LoEj=1 Start=0: stop and open the tray of a CD/DVD
; drive. Not for the walkman: its lid is mechanical (it only gets STOP).
; Output: Cy = 0 OK
; ==========================================================================
SCSI_EJECT_UNIT:
    ld hl,_CDB_EJECT
    ld b,6
    ld de,0                     ; no data
    ld c,0
    ld ix,0
    call SCSI_DO_CMD
    ret

_CDB_EJECT: db 1Bh,0,0,0,02h,0  ; START STOP UNIT, LoEj=1 Start=0

; ==========================================================================
; SCSI_GET_CONFIG
; GET CONFIGURATION (46h), MMC drives only: fetch just the 8-byte feature
; header, whose bytes 6-7 are the "current profile" = the kind of disc in
; the tray (0008h CD-ROM, 0009h CD-R, 0010h DVD-ROM, 001Bh DVD+R, ...).
; Input:  IX = 8-byte destination buffer
; Output: Cy = 0 OK
; ==========================================================================
SCSI_GET_CONFIG:
    ld hl,_CDB_GETCONF
    ld b,10
    ld de,8
    ld c,1                      ; IN
    call SCSI_DO_CMD
    ret

_CDB_GETCONF: db 46h,0,0,0,0,0,0,0,8,0  ; RT=0, from feature 0, alloc 8

; ==========================================================================
; SCSI_SYNC_CACHE
; SYNCHRONIZE CACHE(10): flush the device's write cache before an eject.
; Transfer length 0. A device without a cache answers trivially; one that
; does not implement the opcode fails with CHECK CONDITION - the caller
; treats a failure here as non-fatal (best-effort flush).
; Output: Cy = 0 OK
; ==========================================================================
SCSI_SYNC_CACHE:
    ld hl,_CDB_SYNC
    ld b,10
    ld de,0                     ; no data
    ld c,0
    ld ix,0
    call SCSI_DO_CMD
    ret

_CDB_SYNC: db 35h,0,0,0,0,0,0,0,0,0  ; SYNCHRONIZE CACHE(10), whole medium

; ==========================================================================
; SCSI_REQUEST_SENSE
; Input:  IX = 18-byte destination buffer
; Output: Cy = 0 OK; sense data in buffer (byte 2 = sense key,
;         byte 12 = ASC, byte 13 = ASCQ)
; ==========================================================================
SCSI_REQUEST_SENSE:
    ld hl,_CDB_REQ_SENSE
    ld b,6
    ld de,18
    ld c,1                      ; IN
    call SCSI_DO_CMD
    ret

_CDB_REQ_SENSE: db SCSI_OP_REQUEST_SENSE,0,0,0,18,0

; ==========================================================================
; SCSI_READ_CAPACITY
; READ CAPACITY(10) (0x25). Returns 8 bytes: last LBA (4, big-endian) +
; block size (4, big-endian).
; Input:  IX = 8-byte destination buffer
; Output: Cy = 0 OK
; ==========================================================================
SCSI_READ_CAPACITY:
    ld hl,_CDB_READ_CAP
    ld b,10
    ld de,8
    ld c,1                      ; IN
    call SCSI_DO_CMD
    ret

; READ CAPACITY(10): op, 0, LBA(4)=0, 0, 0, PMI=0, control
_CDB_READ_CAP: db SCSI_OP_READ_CAPACITY,0,0,0,0,0,0,0,0,0

; ==========================================================================
; SCSI_READ10
; READ(10). Reads N blocks starting at a 32-bit LBA.
; Input:  IX = destination buffer
;         BC = number of blocks (usually 1)
;         DE = total byte length (blocks * block_size)
;         HL = pointer to 4-byte LBA, big-endian (MSB first)
; Output: Cy = 0 OK
; ==========================================================================
SCSI_READ10:
    ; build CDB: op,flags,LBA(4 BE),group,len(2 BE),control
    push de
    push bc
    ld a,SCSI_OP_READ10
    ld (_CDB_RW+0),a
    xor a
    ld (_CDB_RW+1),a
    ; LBA (big-endian) copied from HL
    ld de,_CDB_RW+2
    ld bc,4
    ldir
    xor a
    ld (_CDB_RW+6),a            ; group number
    pop bc                     ; BC = block count
    ld a,b
    ld (_CDB_RW+7),a           ; transfer length high
    ld a,c
    ld (_CDB_RW+8),a           ; transfer length low
    xor a
    ld (_CDB_RW+9),a           ; control
    pop de                     ; DE = byte length
    ld hl,_CDB_RW
    ld b,10
    ld c,1                     ; IN
    call SCSI_DO_CMD
    ret

; ==========================================================================
; SCSI_WRITE10
; WRITE(10). Same interface as SCSI_READ10 but IX = source buffer.
; Input:  IX = source buffer, BC = blocks, DE = byte length,
;         HL = 4-byte big-endian LBA
; Output: Cy = 0 OK
; ==========================================================================
SCSI_WRITE10:
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
    ld c,0                     ; OUT
    call SCSI_DO_CMD
    ret

; _CDB_RW lives in work RAM (see note above): READ10/WRITE10 build the CDB
; in place, which would silently fail if it lived in ROM.
