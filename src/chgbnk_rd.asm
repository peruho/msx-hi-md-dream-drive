;
; chgbnk_rd.asm - Nextor bank-switching module for the Rookie Drive NX
; MSX Hi-MD Drive project - Fase 2
;
; The Rookie Drive flash cartridge maps 16 KB banks in page 1 through a
; bank register at 6000h (same scheme as S0urceror's __ROOKIEDRIVE variant
; in MSX-USB, proven on real Rookie Drive hardware).
;
; The FFh + dw 6000h header tells mknexrom the bank-select address so it can
; patch the boot code (the 7FD0h helper is not yet visible at boot time).
;
; Entry: A = bank number (0..). Only AF may be modified.
; The module is placed at 7FD0h of every bank; total size 48 bytes.
;
    org 7FD0h

CHGBNK:
    db 0FFh                     ; header for mknexrom
    dw 6000h                    ; bank select address
    ld (6000h),a
    ret

    ds 48-($-CHGBNK),0FFh

    end
