;
; ch376.asm - CH376 hardware layer for the MSX Hi-MD Drive project
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
; Derived from ch376s.asm (MSX-USB) and ch376.asm (RookieDrive-FDD-ROM),
; ported to Nestor80 syntax. Changes from the references:
;   * Every INT / mode / connect wait uses a real 16-bit timeout counter
;     instead of the reference's no-timeout / 255-iteration loops.
;   * No panic-button (CAPS+ESC) handling; timeouts replace it.
;   * MISTER/SPI and Arduino code paths removed; parallel MSX I/O only.
;   * Stateless: registers/buffers only, no work area, no BDOS.
; --------------------------------------------------------------------------

; ==========================================================================
; CH_CHECK_INT_IS_ACTIVE
; Check the CH376 INT pin (bit 7 of the command/status port).
; NOTE the inverted sense: INT is ACTIVE when bit 7 = 0.
; Output: Z  = INT active (operation complete), NZ = not active
;         A  corrupted
; ==========================================================================
CH_CHECK_INT_IS_ACTIVE:
    in a,(CH_COMMAND_PORT)
    and 80h
    ret

; ==========================================================================
; CH_GET_STATUS
; Read the status code that follows an INT.
; Output: A = status byte (CH_ST_*)
; ==========================================================================
CH_GET_STATUS:
    ld a,CH_CMD_GET_STATUS
    out (CH_COMMAND_PORT),a
    in a,(CH_DATA_PORT)
    ret

; ==========================================================================
; CH_WAIT_INT_AND_GET_RESULT
; Wait (with timeout) for INT to become active, then GET_STATUS and translate
; the CH376 status into an internal USB error code.
; Output: A  = USB error code (USB_ERR_*); on timeout A = USB_ERR_TIMEOUT
;         Cy = 1 on any error (A != USB_ERR_OK), Cy = 0 on success
; Corrupts: AF, BC
; --------------------------------------------------------------------------
; Timeout budget ~1.28 s at 3.58 MHz (see constants.asm CH_INT_TIMEOUT).
; ==========================================================================
CH_WAIT_INT_AND_GET_RESULT:
    ; Total budget = CH_INT_TIMEOUT * CH_WAIT_MULT. CH_WAIT_MULT is work RAM
    ; (init to 1 by the includer): mechanical operations (a MiniDisc spinning
    ; up before its first data packet) need a multi-second budget, so callers
    ; may raise it temporarily (8 -> ~10 s) and restore it afterwards.
    push de
    ld a,(CH_WAIT_MULT)
    or a
    jr nz,_CH_WAIT_MULT_OK
    inc a                        ; guard: 0 -> 1
_CH_WAIT_MULT_OK:
    ld d,a
_CH_WAIT_ROUND:
    ifdef CH_WAIT_HOOKED
    ; The includer (the Nextor driver) wants a word every ~0.13 s of waiting:
    ; a round is split into 8 slices of 8192 polls (65536 in all, the same
    ; ~1 s), and its WAIT_TICK runs after each slice. WAIT_TICK must preserve
    ; BC, DE, HL, IX and IY; Cy=1 from it ends the wait NOW, reported as a
    ; timeout (the driver: ESC or the time cap of a bring-up session). The
    ; recovery and HIMDTEST builds do not define CH_WAIT_HOOKED: their code
    ; is byte-identical to before.
    ld e,8
_CH_WAIT_SLICE:
    ld bc,2000h
    else
    ld bc,CH_INT_TIMEOUT
    endif
_CH_WAIT_INT_LOOP:
    in a,(CH_COMMAND_PORT)
    and 80h
    jr z,_CH_WAIT_INT_GOT_D      ; bit7=0 => INT active
    dec bc
    ld a,b
    or c
    jr nz,_CH_WAIT_INT_LOOP
    ifdef CH_WAIT_HOOKED
    call WAIT_TICK
    jr c,_CH_WAIT_TIMEOUT
    dec e
    jr nz,_CH_WAIT_SLICE
    endif
    dec d
    jr nz,_CH_WAIT_ROUND
_CH_WAIT_TIMEOUT:
    ; timed out
    pop de
    ld a,USB_ERR_TIMEOUT
    scf
    ret
_CH_WAIT_INT_GOT_D:
    pop de
_CH_WAIT_INT_GOT:
    call CH_GET_STATUS
    ; fall through to status translation

; Translate a CH376 status byte in A into a USB error code.
; Output: A = USB error code, Cy = 1 if error
; Side effect: stores the raw status in LAST_CH_STATUS (work RAM, provided by
; the includer) so diagnostics can show exactly what the chip reported.
CH_TRANSLATE_STATUS:
    ld (LAST_CH_STATUS),a
    cp CH_ST_INT_SUCCESS
    jr z,_CH_TR_OK
    cp CH_ST_RET_SUCCESS
    jr z,_CH_TR_OK
    cp CH_ST_INT_DISCONNECT
    jr z,_CH_TR_NODEV
    cp CH_ST_INT_BUF_OVER
    jr z,_CH_TR_DATAERR
    ; families of 2xh codes encode NAK / STALL / TIMEOUT in the low nibble
    ld b,a
    and 2Fh
    cp 2Ah
    jr z,_CH_TR_NAK
    ld a,b
    and 2Fh
    cp 2Eh
    jr z,_CH_TR_STALL
    ld a,b
    and 23h
    cp 20h
    jr z,_CH_TR_TIMEOUT
    ld a,USB_ERR_UNEXPECTED
    scf
    ret
_CH_TR_OK:
    xor a                       ; USB_ERR_OK, Cy=0
    ret
_CH_TR_NODEV:
    ld a,USB_ERR_NO_DEVICE
    scf
    ret
_CH_TR_DATAERR:
    ld a,USB_ERR_DATA_ERROR
    scf
    ret
_CH_TR_NAK:
    ld a,USB_ERR_NAK
    scf
    ret
_CH_TR_STALL:
    ld a,USB_ERR_STALL
    scf
    ret
_CH_TR_TIMEOUT:
    ld a,USB_ERR_TIMEOUT
    scf
    ret

; ==========================================================================
; CH_DELAY
; Hardware delay via CMD_DELAY_100US.
; Input: BC = duration in units of 0.1 ms
; Corrupts: AF, BC
; Each 0.1 ms tick has a ~0.9 s escape counter (no unbounded waits, by design):
; with a dead/absent chip the delay simply ends early instead of hanging.
; ==========================================================================
CH_DELAY:
    push de
_CH_DELAY_TICK:
    ld a,CH_CMD_DELAY_100US
    out (CH_COMMAND_PORT),a
    ld de,0FFFFh                ; escape counter, ~50 T/iter ~= 0.9 s @3.58MHz
_CH_DELAY_LOOP:
    in a,(CH_DATA_PORT)
    or a
    jr nz,_CH_DELAY_NEXT        ; chip returned != 0: tick elapsed
    dec de
    ld a,d
    or e
    jr nz,_CH_DELAY_LOOP
    jr _CH_DELAY_END            ; escape: chip not responding, stop waiting
_CH_DELAY_NEXT:
    dec bc
    ld a,b
    or c
    jr nz,_CH_DELAY_TICK
_CH_DELAY_END:
    pop de
    ret

; ==========================================================================
; CH_HW_TEST
; Presence test: the CH376 echoes NOT(arg) for CMD_CHECK_EXIST.
; Probes with 34h and 89h.
; Output: Cy = 0 if hardware operational, Cy = 1 if not
; Corrupts: AF, B
; ==========================================================================
CH_HW_TEST:
    ld a,34h
    call _CH_HW_TEST_DO
    scf
    ret nz
    ld a,89h
    call _CH_HW_TEST_DO
    scf
    ret nz
    or a                        ; Cy = 0, hardware OK
    ret
_CH_HW_TEST_DO:
    ld b,a
    ld a,CH_CMD_CHECK_EXIST
    out (CH_COMMAND_PORT),a
    ld a,b
    xor 0FFh
    out (CH_DATA_PORT),a
    in a,(CH_DATA_PORT)
    cp b                        ; Z if echo == original value
    ret

; ==========================================================================
; CH_GET_IC_VERSION
; Output: A = chip / firmware version (low 5 bits)
; ==========================================================================
CH_GET_IC_VERSION:
    ld a,CH_CMD_GET_IC_VER
    out (CH_COMMAND_PORT),a
    in a,(CH_DATA_PORT)
    and 1Fh
    ret

; ==========================================================================
; CH_RESET_ALL
; Flush the 64-byte data buffer first (64 reads) so a reset mid-transfer does
; not leave the chip hung, then issue RESET_ALL and wait ~35 ms.
; Corrupts: AF, BC
; ==========================================================================
CH_RESET_ALL:
    ld b,64
_CH_RESET_FLUSH:
    in a,(CH_DATA_PORT)
    djnz _CH_RESET_FLUSH
    ld a,CH_CMD_RESET_ALL
    out (CH_COMMAND_PORT),a
    ld bc,350                   ; 350 * 0.1 ms = ~35 ms mandatory wait
    call CH_DELAY
    ret

; ==========================================================================
; CH_SET_USB_MODE
; Input:  A = USB mode (5 / 6 / 7)
; Output: Cy = 1 on error (timeout waiting for RET_SUCCESS)
; Corrupts: AF, BC
; --------------------------------------------------------------------------
; On success reconfigures NAK retries (SET_USB_MODE resets them).
; ==========================================================================
CH_SET_USB_MODE:
    ld b,a
    ld a,CH_CMD_SET_USB_MODE
    out (CH_COMMAND_PORT),a
    ld a,b
    out (CH_DATA_PORT),a
    ld bc,CH_MODE_TIMEOUT
_CH_WAIT_USB_MODE:
    in a,(CH_DATA_PORT)
    cp CH_ST_RET_SUCCESS
    jr z,_CH_USB_MODE_OK
    dec bc
    ld a,b
    or c
    jr nz,_CH_WAIT_USB_MODE
    scf                         ; timeout
    ret
_CH_USB_MODE_OK:
    or a                        ; Cy = 0 (A=51h, non-zero)
    call CH_CONFIGURE_NAK_RETRY_DEFAULT
    or a
    ret

; Configure NAK retry with the default (limited) policy. Cy preserved via or a
; done by caller; here we just leave Cy cleared.
CH_CONFIGURE_NAK_RETRY_DEFAULT:
    or a                        ; Cy = 0 -> limited retry (0FFh, ~3 s NAK cap)
; ==========================================================================
; CH_CONFIGURE_NAK_RETRY
; Input: Cy = 0 limited NAK retry (default), Cy = 1 retry (nearly) forever
; Corrupts: AF
; ==========================================================================
CH_CONFIGURE_NAK_RETRY:
    ld a,CH_SET_RETRY_LIMITED
    jr nc,_CH_NAK_2
    ld a,CH_SET_RETRY_FOREVER
_CH_NAK_2:
    push af
    ld a,CH_CMD_SET_RETRY
    out (CH_COMMAND_PORT),a
    ld a,CH_SET_RETRY_MAGIC     ; fixed 25h required by CH376
    out (CH_DATA_PORT),a
    pop af
    out (CH_DATA_PORT),a
    ret

; ==========================================================================
; CH_DO_SET_NOSOF_MODE
; Host mode without SOF (used after a disconnect).
; Output: A = -1, Cy = 1 on error
; ==========================================================================
CH_DO_SET_NOSOF_MODE:
    ld a,CH_MODE_NOSOF
    call CH_SET_USB_MODE
    ld a,0FFh
    ret

; ==========================================================================
; CH_TEST_CONNECT
; Wait (with timeout) for a non-zero connection status byte.
; Output: A = status (CH_ST_INT_CONNECT / DISCONNECT / READY), or 0 on timeout
;         Cy = 1 on timeout
; Corrupts: AF, BC
; ==========================================================================
CH_TEST_CONNECT:
    ld a,CH_CMD_TEST_CONNECT
    out (CH_COMMAND_PORT),a
    ld bc,CH_CONNECT_TIMEOUT
_CH_WAIT_TEST_CONNECT:
    in a,(CH_DATA_PORT)
    or a
    jr nz,_CH_TEST_CONNECT_OK
    dec bc
    ld a,b
    or c
    jr nz,_CH_WAIT_TEST_CONNECT
    xor a
    scf
    ret
_CH_TEST_CONNECT_OK:
    or a                        ; Cy = 0 (A non-zero)
    ret

; ==========================================================================
; CH_BUS_RESET
; USB bus reset: mode 7 (host+SOF+reset) -> ~15 ms -> mode 6 (host+SOF).
; Output: A = 1, Cy = 1 on error
; Corrupts: AF, BC
; ==========================================================================
CH_BUS_RESET:
    ld a,CH_MODE_HOST_RESET
    call CH_SET_USB_MODE
    ld a,1
    ret c
    ld bc,150                   ; ~15 ms
    call CH_DELAY
    ld a,CH_MODE_HOST
    call CH_SET_USB_MODE
    ld a,1
    ret c
    ; settle time: give the device's USB stack time to come up after the
    ; reset before the first control transfer (USB spec minimum is 10 ms;
    ; consumer devices with embedded firmware can need much more)
    ld bc,1000                  ; ~100 ms
    call CH_DELAY
    or a                        ; Cy = 0
    ld a,1
    ret

; ==========================================================================
; CH_SET_TARGET_DEVICE_ADDRESS
; Input: A = device address
; Corrupts: AF
; ==========================================================================
CH_SET_TARGET_DEVICE_ADDRESS:
    push af
    ld a,CH_CMD_SET_USB_ADDR
    out (CH_COMMAND_PORT),a
    pop af
    out (CH_DATA_PORT),a
    ret

; ==========================================================================
; CH_ISSUE_TOKEN
; Input: E = endpoint number
;        B = PID (CH_PID_*)
;        A = toggle in bit7 (IN) or bit6 (OUT)
; Corrupts: AF, D
; ==========================================================================
CH_ISSUE_TOKEN:
    ld d,a
    ld a,CH_CMD_ISSUE_TKN_X
    out (CH_COMMAND_PORT),a
    ld a,d
    out (CH_DATA_PORT),a         ; toggles byte
    ld a,e
    rla
    rla
    rla
    rla
    and 0F0h
    or b
    out (CH_DATA_PORT),a         ; high nibble = endpoint, low nibble = PID
    ret

; ==========================================================================
; CH_WRITE_DATA
; Write a block into the CH376 send buffer.
; Input:  HL = source, B = length (0..64)
; Output: HL = HL + B
; Corrupts: AF, BC
; ==========================================================================
CH_WRITE_DATA:
    ld a,CH_CMD_WR_HOST_DATA
    out (CH_COMMAND_PORT),a
    ld a,b
    out (CH_DATA_PORT),a
    or a
    ret z
    ld c,CH_DATA_PORT
    otir
    ret

; ==========================================================================
; CH_READ_DATA
; Read a block from the CH376 receive buffer.
; Input:  HL = destination (if HL = 0, discard)
; Output: C  = amount read (0..64), B = 0, HL = HL + C
; Corrupts: AF, DE
; ==========================================================================
CH_READ_DATA:
    ld a,CH_CMD_RD_USB_DATA0
    out (CH_COMMAND_PORT),a
    in a,(CH_DATA_PORT)         ; first byte = available length
    ld c,a
    or a
    jr nz,_CH_READ_MORE
    ld c,0
    ret                         ; nothing to read
_CH_READ_MORE:
    ld d,a                      ; save length
    ld a,h
    or l
    jr z,_CH_READ_DISCARD       ; HL = 0 -> discard
    ld b,d
    ld c,CH_DATA_PORT
    inir
    ld c,d                      ; return count in C
    ld b,0
    ret
_CH_READ_DISCARD:
    ld b,d
    ld c,CH_DATA_PORT
_CH_READ_DISCARD_LOOP:
    in a,(c)
    djnz _CH_READ_DISCARD_LOOP
    ld c,d
    ld b,0
    ret

; ==========================================================================
; CH_CLEAR_STALL_EP
; Clear a STALL on a bulk endpoint (CLEAR_FEATURE(ENDPOINT_HALT)) using the
; CH376 CLR_STALL shortcut. Caller resets the endpoint toggle afterwards.
; Input: A = device address, E = endpoint address (with direction bit)
; Output: A = USB error code, Cy = 1 on error
; Corrupts: AF, BC, DE
; ==========================================================================
CH_CLEAR_STALL_EP:
    call CH_SET_TARGET_DEVICE_ADDRESS
    ld a,CH_CMD_CLR_STALL
    out (CH_COMMAND_PORT),a
    ld a,e
    out (CH_DATA_PORT),a
    call CH_WAIT_INT_AND_GET_RESULT
    ret

; ==========================================================================
; CH_DATA_IN_TRANSFER
; Bulk/interrupt IN transfer. Target device address must already be set by the
; caller (via CH_SET_TARGET_DEVICE_ADDRESS or HW_DATA_IN_TRANSFER).
; Input:  HL = destination buffer
;         BC = data length to receive
;         D  = endpoint max packet size
;         E  = endpoint number
;         Cy = current toggle state
; Output: A  = USB error code (USB_ERR_OK on success)
;         BC = bytes actually received (on success)
;         Cy = new toggle state (even on error)
; Corrupts: AF, DE, HL, IX, IY
; --------------------------------------------------------------------------
; Ends on: no data, requested length reached, or a short packet (< EP size).
; ==========================================================================
HW_DATA_IN_TRANSFER:
    call CH_SET_TARGET_DEVICE_ADDRESS
CH_DATA_IN_TRANSFER:
    ld a,0
    rra                         ; toggle into bit 7 of A
    ld ix,0                     ; received-so-far counter
    push de
    pop iy                      ; IYH = EP size, IYL = EP number
_CH_IN_LOOP:
    push af                     ; toggle in bit 7
    push bc                     ; remaining length
    ld e,iyl
    ld b,CH_PID_IN
    call CH_ISSUE_TOKEN
    call CH_WAIT_INT_AND_GET_RESULT
    cp USB_ERR_OK
    jr nz,_CH_IN_ERR
    call CH_READ_DATA
    ld b,0
    add ix,bc                   ; update received count
    pop de                      ; DE = remaining length
    pop af
    xor 80h                     ; flip toggle
    push af
    push de
    ld a,c
    or a
    jr z,_CH_IN_DONE            ; no data received -> done
    ex (sp),hl                  ; HL = remaining length
    or a
    sbc hl,bc
    ld a,h
    or l
    ex (sp),hl                  ; remaining length back on stack
    jr z,_CH_IN_DONE            ; nothing remaining -> done
    ld a,c
    cp iyh
    jr c,_CH_IN_DONE            ; short packet -> done
    pop bc
    pop af
    jr _CH_IN_LOOP
_CH_IN_DONE:
    ld a,USB_ERR_OK
    ; fall through with A = success; stack top = remaining, below = toggle
_CH_IN_ERR:
    ; Shared exit. A = result (0 or error code). Stack: [toggle][remaining],
    ; top = remaining. This layout matches BOTH the success path (push af then
    ; push de) and the error path (push af then push bc at _CH_IN_LOOP).
    ld d,a                      ; save result
    pop bc                      ; remaining length (discard)
    pop af                      ; toggle
    rla                         ; toggle back to Cy
    ld a,d
    push ix
    pop bc                      ; BC = bytes received
    ret

; ==========================================================================
; CH_DATA_OUT_TRANSFER
; Bulk/interrupt OUT transfer. Target device address already set by caller.
; Input:  HL = source buffer
;         BC = data length
;         D  = endpoint max packet size
;         E  = endpoint number
;         Cy = current toggle state
; Output: A  = USB error code (USB_ERR_OK on success)
;         Cy = new toggle state (even on error)
; Corrupts: AF, BC, DE, HL, IX, IY
; ==========================================================================
HW_DATA_OUT_TRANSFER:
    call CH_SET_TARGET_DEVICE_ADDRESS
CH_DATA_OUT_TRANSFER:
    push af
    ld a,b
    or c
    jr nz,_CH_OUT_START
    pop af                      ; zero-length OUT: Cy = incoming toggle (saved
    ld a,USB_ERR_OK             ; at entry); ld does not touch flags -> success
    ret                         ; with toggle unchanged, as documented
_CH_OUT_START:
    pop af
    ld a,0
    rra
    rra                         ; toggle into bit 6 of A
    push de
    pop iy                      ; IYH = EP size, IYL = EP number
_CH_OUT_LOOP:
    push af                     ; toggle in bit 6
    push bc                     ; remaining length
    ld a,b
    or a
    ld a,iyh
    jr nz,_CH_OUT_DO            ; remaining >= 256 -> full packet
    ld a,c
    cp iyh
    jr c,_CH_OUT_DO             ; remaining < EP size -> send remaining
    ld a,iyh
_CH_OUT_DO:
    ; A = length of this packet = min(remaining, EP size)
    ex (sp),hl                  ; HL = remaining length
    ld e,a
    ld d,0
    or a
    sbc hl,de
    ex (sp),hl                  ; updated remaining back on stack
    ld b,a
    call CH_WRITE_DATA
    pop bc
    pop af
    push af
    push bc
    ld e,iyl
    ld b,CH_PID_OUT
    call CH_ISSUE_TOKEN
    call CH_WAIT_INT_AND_GET_RESULT
    cp USB_ERR_OK
    jr nz,_CH_OUT_ERR
    pop bc
    pop af
    xor 40h                     ; flip toggle
    push af
    ld a,b
    or c
    jr z,_CH_OUT_DONE
    pop af
    jr _CH_OUT_LOOP
_CH_OUT_ERR:
    pop bc                      ; remaining (discard)
_CH_OUT_DONE:
    ld d,a
    pop af
    rla
    rla                         ; toggle back to Cy
    ld a,d
    ret

; ==========================================================================
; HW_CONTROL_TRANSFER
; Control transfer on endpoint 0 (SETUP -> optional DATA -> STATUS).
; Input:  HL = 8-byte setup packet
;         DE = data buffer (IN or OUT)
;         A  = device address
;         B  = EP0 max packet size
; Output: A  = USB error code (USB_ERR_OK on success)
;         BC = bytes transferred (IN, on success)
; Corrupts: AF, BC, DE, HL, IX, IY
; --------------------------------------------------------------------------
; Simplified vs MSX-USB: on STALL during the data stage we abort with the
; error rather than the reference's potentially-infinite retry loop.
; ==========================================================================
HW_CONTROL_TRANSFER:
    call CH_SET_TARGET_DEVICE_ADDRESS
    push af                     ; device address
    push hl                     ; setup pkt ptr
    push bc                     ; EP0 size in B
    push de                     ; data buffer
    ; SETUP stage
    ld a,1
    ld (CTL_STAGE),a
    ld b,8
    call CH_WRITE_DATA
    xor a
    ld e,0
    ld b,CH_PID_SETUP
    call CH_ISSUE_TOKEN
    call CH_WAIT_INT_AND_GET_RESULT
    cp USB_ERR_OK
    jp nz,_HW_CT_ABORT4
    pop hl                      ; HL = data buffer
    pop de                      ; D = EP0 size
    pop ix                      ; IX = setup packet
    pop af                      ; A = device address (already set in the chip)
    ld c,(ix+6)
    ld b,(ix+7)                 ; BC = wLength
    ld a,b
    or c
    jr z,_HW_CT_STATUS_IN       ; no data stage -> status is always IN (BC=0)
    ld e,0                      ; EP0
    scf                         ; data toggle starts at 1
    bit 7,(ix+0)                ; direction: 1 = IN
    jr z,_HW_CT_DATA_OUT
_HW_CT_DATA_IN:
    ld a,2
    ld (CTL_STAGE),a
    ; Data stage IN, then status stage = zero-length OUT packet (ZLP).
    ; CRITICAL (mirrors RookieDrive reference): the ZLP must be loaded into
    ; the CH376 send buffer with CH_WRITE_DATA(len 0) BEFORE issuing the OUT
    ; token; otherwise the chip sends stale buffer contents (the 8 SETUP
    ; bytes) as the status packet, which strict devices reject with a STALL.
    call CH_DATA_IN_TRANSFER
    or a
    ret nz                      ; error: A = code (stack is clean here)
    push bc                     ; preserve bytes transferred
    ld a,4
    ld (CTL_STAGE),a
    ld b,0
    call CH_WRITE_DATA          ; load the ZLP
    ld e,0
    ld b,CH_PID_OUT
    ld a,40h                    ; OUT toggle = 1
    call CH_ISSUE_TOKEN
    call CH_WAIT_INT_AND_GET_RESULT
    pop bc
    ret                         ; A = status-stage result (propagated)
_HW_CT_DATA_OUT:
    ld a,3
    ld (CTL_STAGE),a
    call CH_DATA_OUT_TRANSFER
    or a
    ret nz
_HW_CT_STATUS_IN:
    ; Status stage IN (after OUT data, or for no-data transfers)
    ld a,4
    ld (CTL_STAGE),a
    push bc
    ld e,0
    ld b,CH_PID_IN
    ld a,80h                    ; IN toggle = 1
    call CH_ISSUE_TOKEN
    ld hl,0
    call CH_READ_DATA           ; drain the (zero-length) status packet
    call CH_WAIT_INT_AND_GET_RESULT
    pop bc
    ret                         ; A = status-stage result (propagated)
_HW_CT_ABORT4:
    ld d,a
    pop ix
    pop ix
    pop ix
    pop ix
    ld a,d
    scf
    ret
