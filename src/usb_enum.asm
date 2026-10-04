;
; usb_enum.asm - Manual USB enumeration for the MSX Hi-MD Drive project
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
; Derived from usbhost.asm (MSX-USB), ported to Nestor80 and simplified for
; the single-device, mass-storage-only Fase 0 test:
;   * No UNAPI, no hubs, no HID/CDC.
;   * Descriptor field access uses EQU offsets (constants.asm), not structs.
;   * SETUP packets are built inline in RAM (no page-3 work area / bank switch).
;   * The wanted interface criterion is Mass Storage / SCSI / Bulk-Only.
;
; No BDOS here. Requires these work-RAM labels from the includer:
;   USB_DEV_ADDR      db   ; assigned device address (1)
;   USB_EP0_SIZE      db   ; EP0 max packet size
;   USB_BULK_IN_EP    db   ; bulk IN endpoint number
;   USB_BULK_OUT_EP   db   ; bulk OUT endpoint number
;   USB_BULK_MAXPKT   db   ; bulk endpoint max packet size (low byte)
;   USB_BULK_IN_TOG   db   ; bulk IN toggle (bit 7)
;   USB_BULK_OUT_TOG  db   ; bulk OUT toggle (bit 7)
;   USB_VID           dw   ; idVendor
;   USB_PID           dw   ; idProduct
;   USB_CONFIG_VALUE  db   ; bConfigurationValue
;   USB_IFACE_NUM     db   ; mass-storage interface number
;   USB_DESC_BUF      ds N ; descriptor scratch buffer (>= 256 bytes)
;   USB_SETUP_BUF     ds 8 ; 8-byte SETUP packet scratch
; --------------------------------------------------------------------------

; ==========================================================================
; USB_ENUMERATE
; Full manual enumeration of the single attached device (device address 1).
; Assumes a bus reset has just been performed (device at address 0).
; Output: A = 0 OK (mass storage found and configured)
;             1 device present but not a Bulk-Only mass storage interface
;             2 USB error during enumeration (B = USB error code)
; Corrupts: everything
; ==========================================================================
USB_ENUMERATE:
    ; --- EXPERIMENTAL (Windows-style): assume EP0 = 64 and ask for a 64-byte
    ;     device descriptor on the very first GET_DESCRIPTOR, instead of the
    ;     conservative 8/8. On real MSX hardware every device STALLed the
    ;     DATA-IN of the 8-byte request; if that short first request was the
    ;     cause, the 64/64 form (which Windows and most hosts use) may succeed.
    ;     The device still only returns 18 bytes (bLength), which our control
    ;     transfer accepts as a short packet.
    ld a,64
    ld (USB_EP0_SIZE),a
    ld a,1
    ld (ENUM_STEP),a
    ; GET_DESCRIPTOR(DEVICE), 64 bytes requested, from address 0, EP0 assumed 64
    ld hl,SETUP_GET_DEV_DESCR64
    ld de,USB_DESC_BUF
    xor a                       ; device address 0
    ld b,64                     ; EP0 size (assumed)
    call HW_CONTROL_TRANSFER
    cp USB_ERR_OK
    jp nz,_ENUM_ERR
    ; take real bMaxPacketSize0
    ld a,(USB_DESC_BUF+DD_bMaxPacketSize0)
    ld (USB_EP0_SIZE),a
    ld a,2
    ld (ENUM_STEP),a
    ; --- SET_ADDRESS(1) to device at address 0
    ld hl,SETUP_SET_ADDR1
    ld de,USB_DESC_BUF
    ld a,(USB_EP0_SIZE)
    ld b,a
    xor a                       ; device address 0
    call HW_CONTROL_TRANSFER
    cp USB_ERR_OK
    jp nz,_ENUM_ERR
    ld a,1
    ld (USB_DEV_ADDR),a
    ld a,3
    ld (ENUM_STEP),a
    ; --- GET_DESCRIPTOR(DEVICE) full 18 bytes, now from address 1
    ld hl,SETUP_GET_DEV_DESCR18
    ld de,USB_DESC_BUF
    ld a,(USB_EP0_SIZE)
    ld b,a
    ld a,1
    call HW_CONTROL_TRANSFER
    cp USB_ERR_OK
    jp nz,_ENUM_ERR
    ; save VID/PID
    ld hl,(USB_DESC_BUF+DD_idVendor)
    ld (USB_VID),hl
    ld hl,(USB_DESC_BUF+DD_idProduct)
    ld (USB_PID),hl
    ld a,4
    ld (ENUM_STEP),a
    ; --- GET_DESCRIPTOR(CONFIG) first 9 bytes to learn wTotalLength
    ld hl,SETUP_GET_CONFIG9
    ld de,USB_DESC_BUF
    ld a,(USB_EP0_SIZE)
    ld b,a
    ld a,1
    call HW_CONTROL_TRANSFER
    cp USB_ERR_OK
    jp nz,_ENUM_ERR
    ld a,(USB_DESC_BUF+CD_bConfigurationValue)
    ld (USB_CONFIG_VALUE),a
    ; --- GET_DESCRIPTOR(CONFIG) full length. The template is patched in a RAM
    ;     copy (USB_SETUP_BUF): the templates themselves may live in ROM
    ;     (cartridge build), where in-place patching is silently ignored.
    ld a,5
    ld (ENUM_STEP),a
    ld hl,SETUP_GET_CONFIG_FULL
    call _SETUP_TO_RAM                      ; HL -> USB_SETUP_BUF copy
    ; wLength = min(wTotalLength, 256): consumer devices (Sony walkmans!) can
    ; have config descriptors > 255 bytes; requesting only the LOW byte used
    ; to truncate the read so the interface parser failed "successfully"
    ; without ever seeing the endpoints. USB_DESC_BUF holds 256 bytes.
    ld a,(USB_DESC_BUF+CD_wTotalLength+1)   ; high byte
    or a
    jr z,_ENUM_CFGLEN_LOW
    xor a                                   ; total >= 256 -> request 256
    ld (USB_SETUP_BUF+6),a                  ; wLength low  = 00h
    inc a
    ld (USB_SETUP_BUF+7),a                  ; wLength high = 01h -> 256
    jr _ENUM_CFGLEN_SET
_ENUM_CFGLEN_LOW:
    ld a,(USB_DESC_BUF+CD_wTotalLength)     ; low byte of wTotalLength
    ld (USB_SETUP_BUF+6),a                  ; wLength low byte
    xor a
    ld (USB_SETUP_BUF+7),a                  ; wLength high byte = 0
_ENUM_CFGLEN_SET:
    ld de,USB_DESC_BUF
    ld a,(USB_EP0_SIZE)
    ld b,a
    ld a,1
    call HW_CONTROL_TRANSFER
    cp USB_ERR_OK
    jp nz,_ENUM_ERR
    ; --- walk the descriptor tree looking for the mass-storage interface
    ;     and its two bulk endpoints
    call USB_FIND_MASS_STORAGE
    jr nc,_ENUM_MS_OK
    ld a,1                      ; not a Bulk-Only mass storage device
    ret
_ENUM_MS_OK:
    ; --- SET_CONFIGURATION(bConfigurationValue) - same RAM-copy patching
    ld a,7
    ld (ENUM_STEP),a
    ld hl,SETUP_SET_CONFIG
    call _SETUP_TO_RAM
    ld a,(USB_CONFIG_VALUE)
    ld (USB_SETUP_BUF+2),a
    ld de,USB_DESC_BUF
    ld a,(USB_EP0_SIZE)
    ld b,a
    ld a,1
    call HW_CONTROL_TRANSFER
    cp USB_ERR_OK
    jp nz,_ENUM_ERR
    ; init toggles
    xor a
    ld (USB_BULK_IN_TOG),a
    ld (USB_BULK_OUT_TOG),a
    xor a                       ; success
    ret
_ENUM_ERR:
    ld b,a                      ; USB error code in B
    ld a,2
    ret

; ==========================================================================
; USB_FIND_MASS_STORAGE
; Parse the config descriptor tree in USB_DESC_BUF. Locate the interface with
; class 08h / subclass 06h / protocol 50h, then capture its bulk IN/OUT
; endpoint numbers and max packet size.
; Output: Cy = 0 found & endpoints captured, Cy = 1 not found
; Corrupts: AF, BC, DE, HL, IX
; --------------------------------------------------------------------------
; State kept in RAM flags:
;   USB_IFACE_NUM = 0FFh until found; endpoints filled while inside the IFACE.
; ==========================================================================
USB_FIND_MASS_STORAGE:
    ld a,0FFh
    ld (USB_IFACE_NUM),a
    ld (USB_BULK_IN_EP),a
    ld (USB_BULK_OUT_EP),a
    xor a
    ld (_MS_IN_WANTED_IFACE),a          ; 0 = not currently inside wanted iface
    ; total length in DE = min(wTotalLength, 256) - what we actually fetched
    ld a,(USB_DESC_BUF+CD_wTotalLength+1)
    or a
    jr z,_MS_LEN_LOW
    ld de,256
    jr _MS_LEN_SET
_MS_LEN_LOW:
    ld a,(USB_DESC_BUF+CD_wTotalLength)
    ld e,a
    ld d,0
_MS_LEN_SET:
    ld hl,USB_DESC_BUF
_MS_LOOP:
    ld a,e
    or d
    jp z,_MS_END                        ; consumed the whole config block
    ld a,(hl)                           ; bLength
    or a
    jp z,_MS_END                        ; malformed (0-length) -> stop
    ld c,a                              ; C = this descriptor length
    inc hl
    ld a,(hl)                           ; bDescriptorType
    dec hl
    cp DESC_TYPE_INTERFACE
    jr z,_MS_IFACE
    cp DESC_TYPE_ENDPOINT
    jr z,_MS_ENDPT
    jr _MS_ADVANCE
_MS_IFACE:
    ; check class/subclass/protocol
    push hl
    ld a,(_MS_IN_WANTED_IFACE)
    or a
    jr z,_MS_IFACE_CHECK
    ; we already found our interface and captured endpoints; a new interface
    ; descriptor means we can stop (endpoints already captured)
    ld a,(USB_BULK_IN_EP)
    cp 0FFh
    jr z,_MS_IFACE_CHECK                ; still missing endpoints, keep scanning
    ld a,(USB_BULK_OUT_EP)
    cp 0FFh
    jr z,_MS_IFACE_CHECK
    pop hl
    jr _MS_FOUND
_MS_IFACE_CHECK:
    ld a,(hl)                           ; reload not needed, HL at iface base
    ld de,ID_bInterfaceClass
    add hl,de
    ld a,(hl)                           ; bInterfaceClass
    cp USB_CLASS_MASS_STORAGE
    jr nz,_MS_IFACE_NO
    ; bInterfaceSubClass deliberately NOT checked: it only names the command
    ; flavour (01 RBC, 02 ATAPI/MMC, 04 UFI, 05 SFF-8070i, 06 SCSI) and
    ; CD/MD-style devices (Sony Hi-MD!) often report 02/05 rather than 06.
    ; Class 08 + protocol 50h (Bulk-Only) is what actually matters.
    inc hl
    inc hl
    ld a,(hl)                           ; bInterfaceProtocol
    cp USB_PROTO_BULK_ONLY
    jr nz,_MS_IFACE_NO
    pop hl
    ; matched: record interface number and mark that we are inside it
    push hl
    ld de,ID_bInterfaceNumber
    add hl,de
    ld a,(hl)
    ld (USB_IFACE_NUM),a
    ld a,1
    ld (_MS_IN_WANTED_IFACE),a
    pop hl
    jr _MS_ADVANCE
_MS_IFACE_NO:
    pop hl
    ; if this is a different interface after ours, clear the inside flag
    xor a
    ld (_MS_IN_WANTED_IFACE),a
    jr _MS_ADVANCE
_MS_ENDPT:
    ld a,(_MS_IN_WANTED_IFACE)
    or a
    jr z,_MS_ADVANCE                    ; endpoint of some other interface
    push hl
    ld de,ED_bmAttributes
    add hl,de
    ld a,(hl)
    and 03h
    cp 02h                              ; bulk?
    jr nz,_MS_ENDPT_DONE
    ; capture max packet size (low byte) once
    push hl
    inc hl                             ; wMaxPacketSize low
    ld a,(hl)
    ld (USB_BULK_MAXPKT),a
    pop hl
    pop hl                             ; HL = endpoint descriptor base
    push hl
    ld de,ED_bEndpointAddress
    add hl,de
    ld a,(hl)
    bit 7,a
    jr z,_MS_ENDPT_OUT
    and 7Fh
    ld (USB_BULK_IN_EP),a
    jr _MS_ENDPT_DONE2
_MS_ENDPT_OUT:
    and 7Fh
    ld (USB_BULK_OUT_EP),a
    jr _MS_ENDPT_DONE2
_MS_ENDPT_DONE:
    pop hl
    jr _MS_ADVANCE
_MS_ENDPT_DONE2:
    pop hl
    jr _MS_ADVANCE
_MS_ADVANCE:
    ; HL += C (this descriptor length), DE -= C
    ld b,0
    add hl,bc
    ex de,hl
    or a
    sbc hl,bc
    ex de,hl
    jp _MS_LOOP
_MS_END:
_MS_FOUND:
    ; success only if interface found and both endpoints captured
    ld a,(USB_IFACE_NUM)
    cp 0FFh
    jr z,_MS_FAIL
    ld a,(USB_BULK_IN_EP)
    cp 0FFh
    jr z,_MS_FAIL
    ld a,(USB_BULK_OUT_EP)
    cp 0FFh
    jr z,_MS_FAIL
    or a                                ; Cy = 0
    ret
_MS_FAIL:
    scf
    ret

; _MS_IN_WANTED_IFACE (scratch flag: inside the wanted interface?) is work RAM
; provided by the includer: it MUST NOT live here, this code may be in ROM.

; ==========================================================================
; --------------------------------------------------------------------------
; _SETUP_TO_RAM: copy the 8-byte SETUP template at HL to USB_SETUP_BUF so it
; can be patched (templates may live in ROM in the cartridge build).
; Output: HL = USB_SETUP_BUF. Corrupts: BC, DE, flags.
; --------------------------------------------------------------------------
_SETUP_TO_RAM:
    ld de,USB_SETUP_BUF
    ld bc,8
    ldir
    ld hl,USB_SETUP_BUF
    ret

; SETUP packet templates (8 bytes each). Templates that need run-time patching
; are first copied to USB_SETUP_BUF (see _SETUP_TO_RAM); never patch in place.
; Format: bmRequestType, bRequest, wValueL, wValueH, wIndexL, wIndexH,
;         wLengthL, wLengthH
; ==========================================================================
; GET_DESCRIPTOR(DEVICE), first 8 bytes
SETUP_GET_DEV_DESCR8:   db 80h,06h,00h,01h,00h,00h,08h,00h
; GET_DESCRIPTOR(DEVICE), first 64 bytes (Windows-style; EXPERIMENTAL first req)
SETUP_GET_DEV_DESCR64:  db 80h,06h,00h,01h,00h,00h,40h,00h
; GET_DESCRIPTOR(DEVICE), full 18 bytes
SETUP_GET_DEV_DESCR18:  db 80h,06h,00h,01h,00h,00h,12h,00h
; SET_ADDRESS(1)
SETUP_SET_ADDR1:        db 00h,05h,01h,00h,00h,00h,00h,00h
; GET_DESCRIPTOR(CONFIG index 0), first 9 bytes
SETUP_GET_CONFIG9:      db 80h,06h,00h,02h,00h,00h,09h,00h
; GET_DESCRIPTOR(CONFIG index 0), full (wLength low byte patched at +6)
SETUP_GET_CONFIG_FULL:  db 80h,06h,00h,02h,00h,00h,09h,00h
; SET_CONFIGURATION (value patched at +2)
SETUP_SET_CONFIG:       db 00h,09h,01h,00h,00h,00h,00h,00h
