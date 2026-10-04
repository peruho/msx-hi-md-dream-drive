;
; chgbnk_rd4.asm - Nextor bank-switching module for the Hi-MD Dream Drive
;                  192 KB ROM layout (+4 physical-bank shift).
;
; In our ROM the bootloader lives in physical bank 0, physical banks 1-3 are
; left free, and the Nextor kernel occupies physical banks 4-11. So every
; logical Nextor bank number must be shifted by +4 before it is written to
; the CPLD bank register at 6000h.
;
; NO mknexrom FFh header here: the boot entry goes through the bootloader
; in physical bank 0, and the kernel's early switch uses the copy of this
; code that mknexrom places inside bank 0 (offset 07DCh).
;
; Entry: A = logical Nextor bank (0..7). Only AF may be modified.
;
    org 7FD0h

CHGBNK:
    add a,4
    ld (6000h),a
    ret

    ds 48-($-CHGBNK),0FFh

    end
