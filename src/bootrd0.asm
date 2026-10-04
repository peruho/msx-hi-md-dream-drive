;
; bootrd0.asm - Bank-0 bootloader for the MSX Hi-MD Drive cartridge (Fase 5)
; MSX Hi-MD Drive project
;
; Copyright (c) 2026 MSX Hi-MD Drive project
; This program is free software under the GNU General Public License v3.
;
; 100%-original replacement for the third-party bootloader: written from
; scratch against the OBSERVED behaviour of the cartridge (keys, mapper,
; launch protocol), not from its code.
;
; Boot flow (runs as a page-1 extension ROM, bank 0 mapped at 4000h):
;   * CTRL+R held  -> recovery (src/recovery.asm when present; safe
;                     placeholder meanwhile)
;   * ESC held     -> bypass the whole cartridge (back to the BIOS scan)
;   * otherwise    -> switch to SCREEN 0 x 80 on MSX2+ (ONE coherent boot
;                     screen: the Nextor kernel and driver banners print
;                     below ours), print the banner and launch Nextor.
;
; The launch stub runs from RAM (the bank switch pulls this code from
; under our feet) and sets BOTH mapper registers: 6000h (page 1) and
; 7000h (page 2) as well - on the real cartridge CPLD the second write just
; re-latches the same bank (harmless), while on a true ASCII16 mapper
; (openMSX) it maps page 2 correctly; with 6000h alone the ROM could not
; boot in the emulator.
; ==========================================================================

; BIOS entry points / system variables (BIOS is in page 0 at init time)
CHPUT:      equ 00A2h   ; print char in A
INITXT:     equ 006Ch   ; SCREEN 0 with LINL40 columns (clears screen)
SNSMAT:     equ 0141h   ; A=row -> A=key bits (0 = pressed)
MSXVER:     equ 002Dh   ; machine generation (0=MSX1, 1=MSX2, ...)
LINL40:     equ 0F3AEh  ; SCREEN 0 width

NEXTOR_BANK: equ 4      ; our Nextor kernel lives in banks 4-11
BANKREG_P1: equ 6000h   ; mapper register, page 1 window (4000h-7FFFh)
BANKREG_P2: equ 7000h   ; mapper register, page 2 window (8000h-BFFFh)
STUB_RAM:   equ 0E000h  ; plain RAM on every MSX at boot time
CH_CHK_EXIST: equ 06h   ; CH376 CHECK_EXIST (answers the byte's complement)
    ifndef CH_DATA_PORT
CH_DATA_PORT:    equ 20h
CH_COMMAND_PORT: equ 21h
    endif

    org 4000h

; --------------------------------------------------------------------------
; Extension ROM header
; --------------------------------------------------------------------------
    db "AB"
    dw INIT                      ; 4002h: also read by the launch stub to
    dw 0                         ;  find Nextor's INIT after the switch
    dw 0
    dw 0
    ds 6

; --------------------------------------------------------------------------
INIT:
    ; CTRL+R held -> recovery
    ld a,6
    call SNSMAT                  ; row 6: bit 1 = CTRL (0 = pressed)
    bit 1,a
    jr nz,_NO_CTRLR
    ld a,4
    call SNSMAT                  ; row 4: bit 7 = R
    bit 7,a
    jp z,RECOVERY_ENTRY
_NO_CTRLR:
    ; ESC held -> bypass the cartridge entirely
    ld a,7
    call SNSMAT                  ; row 7: bit 2 = ESC
    bit 2,a
    jr nz,_BOOT
    ld hl,S_BYPASS
    call PUTS
    ret                          ; back to the BIOS: no Nextor this boot

_BOOT:
    ; one coherent 80-column boot screen on MSX2 or better
    ld a,(MSXVER)
    or a
    jr z,_BANNER                 ; MSX1: keep the BIOS 32-column mode
    ld a,80
    ld (LINL40),a
    call INITXT
_BANNER:
    ld hl,S_BANNER
    call PUTS
    ; quick CH376 presence probe (CHECK_EXIST: the chip answers the
    ; complement of any byte). Informative only: boot continues either
    ; way (the driver re-checks and copes on its own).
    ld a,CH_CHK_EXIST
    out (CH_COMMAND_PORT),a
    ld a,0BEh
    out (CH_DATA_PORT),a
    ex (sp),hl                   ; brief settle (the chip is fast)
    ex (sp),hl
    in a,(CH_DATA_PORT)
    cp 41h                       ; complement of BEh
    ld hl,S_USBOK
    jr z,_USBMSG
    ld hl,S_USBNO
_USBMSG:
    call PUTS
    ; hold the bootloader screen ~1.5 s so it can actually be read (the
    ; Nextor kernel clears the screen the moment we hand over).
    ; Inner loop: 65536 iterations x ~26 T-states ~= 0.48 s at 3.58 MHz
    ; (v1 bug: b=15 assumed 0.1 s/lap and the pause lasted ~7 s on HW)
    ld b,3
_PAUSE:
    ld hl,0
_PAUSE1:
    dec hl
    ld a,h
    or l
    jr nz,_PAUSE1
    djnz _PAUSE
    ; launch Nextor via the RAM stub
    ld hl,STUB
    ld de,STUB_RAM
    ld bc,STUB_LEN
    ldir
    jp STUB_RAM

; The stub itself (copied to RAM before running: the first write below
; swaps this ROM bank away)
STUB:
    ld a,NEXTOR_BANK
    ld (BANKREG_P1),a
    ld (BANKREG_P2),a
    ld hl,(4002h)                ; Nextor bank 0 is mapped now: its INIT
    jp (hl)
STUB_LEN: equ $-STUB

; --------------------------------------------------------------------------
; Recovery entry. When src/recovery.asm is linked in (RECOVERY_MAIN),
; jump there; until then, a safe placeholder that tells the user what to
; do and bypasses the ROM (so any other bootable device still works).
; --------------------------------------------------------------------------
RECOVERY_ENTRY:
    ifdef HAVE_RECOVERY
    jp RECOVERY_MAIN
    else
    ld hl,S_NORECO
    call PUTS
_RE_KEY:
    ret                          ; bypass: boot from other media to reflash
    endif

; --------------------------------------------------------------------------
PUTS:                            ; zero-terminated string at HL via CHPUT
    ld a,(hl)
    or a
    ret z
    inc hl
    push hl
    call CHPUT
    pop hl
    jr PUTS

; Screen texts (art direction: PERUHO, 2026-07-08 mockup)
S_BANNER:
    db "Hi-MD Dream Drive v."
    include "version.inc"        ; db "YYYYMMDD" - generated by make
    db 13,10
    db "PERUHO 2026",13,10
    db 13,10,0
S_USBOK:
    db "USB controller found!",13,10,0
S_USBNO:
    db "USB controller not found!",13,10,0
S_BYPASS:
    db "Hi-MD Dream Drive skipped (ESC)",13,10,0
    ifndef HAVE_RECOVERY
S_NORECO:
    db "Recovery not installed yet.",13,10
    db "Rebuild with HAVE_RECOVERY.",13,10,0
    endif

    ifdef HAVE_RECOVERY
    include "recovery.asm"
    endif

; --------------------------------------------------------------------------
; Pad to a full 16 KB bank with FFh (kind to flash chips)
; --------------------------------------------------------------------------
BOOT_END:
    ds 8000h-BOOT_END,0FFh

    end
