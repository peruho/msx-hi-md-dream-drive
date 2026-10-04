; ==========================================================================
; iso9660.asm - ISO9660 native mount (driver v3.3): the disc is shown to
; Nextor as a READ-ONLY FAT16 volume synthesized on the fly from the ISO
; structures. The volume is fully determined by the ISO structures: for a
; given disc, DEV_RW returns, sector by sector and in any order of calls,
; the same bytes (checked against an executable model of the volume).
;
; Everything here runs with our segment mapped in page 2 and interrupts
; disabled (inside DEV_RW or a CALL DREAM handler). State: ISO_* variables
; from 8D00h, the DIRBLK table at 9000h-BFFFh (see driver.asm).
;
; Included from driver.asm (it uses BUF2K, TRANS_BUF, the DEV_RW loop
; variables, FETCH_CACHED, READ_PHYS_RETRY, COPY_OUT, CLAMP_NBLK...).
; ==========================================================================

; Record kinds produced by the walk (K_* of the model)
K_DOT:      equ 0
K_DOTDOT:   equ 1
K_HIDE:     equ 2               ; hidden by flags / corrupt: E5h
K_FILE:     equ 3
K_DIR:      equ 4
K_LOST:     equ 5               ; no room for it (E5h, consumes nothing)

; Resolution cache entry (16 bytes, 8 entries at ISO_RCACHE)
RC_VSTART:  equ 0               ; 2: first virtual cluster of the child
RC_VEND:    equ 2               ; 2: one past its last cluster
RC_START:   equ 4               ; 4: first data block (extent + XAR)
RC_NBLK:    equ 8               ; 3: data blocks (dir: served blocks, <=1024)
RC_FLAGS:   equ 11              ; bit0 = directory, bit7 = entry valid
RC_PARENT:  equ 12              ; 2: cluster of the child's parent directory

; ==========================================================================
; ISO_PROBE - classify the medium: ISO_STATE = 1 (not ISO: FAT/raw path as
; before) or 2 (ISO9660 mounted: geometry, label, serial, bootable flag).
; Block 0 is checked FIRST: a Sony/FAT boot sector wins over a PVD (a FAT
; master that also carries a PVD keeps working as a FAT disc).
; v3.3.3: the allocation tables survive a re-probe of the
; SAME disc. The identity (serial, volume size, root extent and a hash of
; the whole PVD block) is compared with the one the tables were built for
; (ISO_ID, valid while ISO_TVALID=1): equal -> "M ISO kept": DIRBLK, VNEXT,
; NROWS, LOST and the bootable flag stay, only the caches are dropped, so
; every cluster Nextor learned before (open files, buffered directory
; sectors) still means the same file. Different -> "M ISO new": DIRBLK
; emptied, VNEXT = 2. A non-ISO medium leaves the tables alone (they only
; ever apply to their own disc). Limit: disc A -> ISO disc B -> disc A
; rebuilds A's tables (MSX-DOS rule: no disc swap with files open).
; v3.3.5: a successful probe also takes the disc's identity for VERIFY_ID
; (MID_*: capacity, signature of logical sector 0, ISO or not) - unless a
; verification is pending (VFY_PEND): then the reference stays the disc
; Nextor holds. The PVD identity lives in ISO_CALC_NID (shared).
; Out: Cy=1 + A = Nextor error when a block could not be read (ISO_STATE
; stays 0: probed again on the next access). Corrupts everything.
; ==========================================================================
ISO_PROBE:
    xor a
    ld (ISO_STATE),a
    ld (W_RESUME),a              ; no walk to resume across a (re)mount
    ld hl,0
    ld (S_LBA),hl
    ld (S_LBA+2),hl
    call ISO_FETCH               ; block 0 -> BUF2K
    ret c
    ld hl,BUF2K                  ; v3.3.5: signature of logical sector 0, the
    call SIG0                    ;  disc's identity for VERIFY_ID (_IP_MID)
    call CHK_SONY_BOOT
    jp z,_IP_NOTISO
    ld hl,16
    ld (S_LBA),hl
    call ISO_FETCH               ; block 16: primary volume descriptor?
    ret c
    ; ---- everything from the PVD first: BUF2K is reused below ----
    call ISO_CALC_NID            ; Z=1: a PVD; ISO_NID = its identity
    jp nz,_IP_NOTISO
    call ISO_MAKE_LABEL
    ld hl,(ISO_NID+8)            ; root extent + XAR (from the identity)
    ld (ISO_ROOT),hl
    ld hl,(ISO_NID+10)
    ld (ISO_ROOT+2),hl
    ; RB = min(63, max(1, ceil(root size / 2048)))
    ld hl,BUF2K+166
    call LD_T_A
    ld a,11
    call SHR_T_A
    ld hl,(T_A)
    jr nc,_IP_RB1
    inc hl
    ld a,h
    or l
    jr z,_IP_RB63                ; 0FFFFh + 1 blocks: far above 63
_IP_RB1:
    ld a,(T_A+2)
    or h
    jr nz,_IP_RB63
    ld a,l
    or a
    jr nz,_IP_RB2
    inc a
_IP_RB2:
    cp 64
    jr c,_IP_RBOK
_IP_RB63:
    ld a,63
_IP_RBOK:
    ld (ISO_RB),a
    ld hl,BUF2K+80               ; volume space size (LE copy) -> T_B
    ld de,T_B
    ld bc,4
    ldir
    call ISO_GEOMETRY
    ; ---- caches: always dropped (they are rebuilt from the tables) ----
    ld hl,0
    ld (ISO_LCROW),hl
    xor a
    ld (ISO_RCNEXT),a
    call ISO_RCACHE_CLEAR
    ; ---- the same disc the tables were built for? keep them ----
    ld a,(ISO_TVALID)
    or a
    jr z,_IP_FRESH
    ld hl,ISO_NID
    ld de,ISO_ID
    ld b,ISO_IDLEN
    call _C5_LOOP                ; Z=1: identical
    jr nz,_IP_FRESH
    call LOG_EVT                 ; CALL DREAM LOG "M ISO kept"
    db 'M'+80h,LEV_ISOKEEP
    jp _IP_MOUNTED               ; (ISO_BOOT kept with the tables)
_IP_FRESH:
    ; ---- another disc (or none yet): fresh mount state ----
    xor a
    ld (ISO_TVALID),a            ; until the tables belong to this disc
    ld (ISO_LOST),a
    ld (ISO_BOOT),a
    ld hl,2
    ld (ISO_VNEXT),hl
    ld hl,0
    ld (ISO_NROWS),hl
    ; ---- bootable: NEXTOR.SYS / MSXDOS2.SYS in the first min(8,RB) root
    ; blocks (a file, not associated nor multi-extent; hidden bit ignored)
    ld a,(ISO_RB)
    cp 8
    jr c,_IP_BB
    ld a,8
_IP_BB:
    ld b,a
    ld hl,0
_IP_BLOOP:
    push bc
    push hl
    ld (S_K),hl                  ; k (the mangled names depend on it)
    ld de,(ISO_ROOT)
    add hl,de
    ld (S_LBA),hl
    ld hl,(ISO_ROOT+2)
    ld de,0
    adc hl,de
    ld (S_LBA+2),hl
    call ISO_FETCH
    jr c,_IP_BERR
    ld hl,0
    ld a,2                       ; classify only, no clusters
    call ISO_WALK_INIT
_IP_RLOOP:
    call ISO_WALK_NEXT
    jr c,_IP_BNEXT
    ld a,(W_KIND)
    cp K_FILE
    jr nz,_IP_RLOOP
    call ISO_NAME83
    ld hl,N_NAME
    ld de,S_NEXTORSYS
    call CMP11
    jr z,_IP_BOOTABLE
    ld hl,N_NAME
    ld de,S_MSXDOS2SYS
    call CMP11
    jr nz,_IP_RLOOP
_IP_BOOTABLE:
    ld a,1
    ld (ISO_BOOT),a
    pop hl
    pop bc
    jr _IP_OWN
_IP_BNEXT:
    pop hl
    pop bc
    inc hl
    djnz _IP_BLOOP
_IP_OWN:
    ; ---- the (empty) tables now belong to this disc ----
    ld hl,ISO_NID
    ld de,ISO_ID
    ld bc,ISO_IDLEN
    ldir
    ld a,1
    ld (ISO_TVALID),a
    call LOG_EVT                 ; CALL DREAM LOG "M ISO new"
    db 'M'+80h,LEV_ISONEW
_IP_MOUNTED:
    ld a,2
    jr _IP_STATE
_IP_BERR:
    pop hl
    pop bc
    scf
    ret
_IP_NOTISO:
    ld a,1
_IP_STATE:
    ld (ISO_STATE),a
    ; v3.3.5: the disc just probed is the one Nextor gets served from now on:
    ; its identity (capacity, the logical-sector-0 signature taken above, the
    ; ISO identity - ISO_ID now - for an ISO mount) is the reference of
    ; VERIFY_ID. Not while a verification is pending (CALL DREAM probing a
    ; disc Nextor has not been told about): the old reference must stay.
    ld c,a                       ; C = ISO_STATE
    ld a,(VFY_PEND)
    or a
    ld a,0
    jr nz,_IP_NOMID              ; (MID_CUR = 0: taken at the change report)
    ld a,c
    dec a
    ld (MID_ISO),a               ; 1 = ISO mount (ISO_STATE 2), 0 = not ISO
    ld hl,TOTAL_SEC
    ld de,MID_TOT
    ld bc,4
    ldir
    ld hl,VFY_SIG
    ld c,4                       ; (B=0 after the LDIR) DE = MID_SIG
    ldir
    ld a,1
    ld (MID_OK),a
_IP_NOMID:
    ld (MID_CUR),a               ; 1 = MID_* is this mount's identity
    or a                         ; Cy=0: probed (the ISO path may arrive with
    ret                          ;  Cy=1 from the walk - "or a" as before)

; ==========================================================================
; ISO_CALC_NID - BUF2K holds block 16. If it is an ISO9660 primary volume
; descriptor with 2048-byte blocks: Z=1, ISO_NID = its identity - serial(4)
; (ISO_SERIAL is set too), volume size(4), root extent + XAR(4), rotating
; hash of the whole PVD block(4) - v3.3.3's disc identity. Else Z=0 and
; nothing is written. Shared by ISO_PROBE and VERIFY_ID (v3.3.5).
; Corrupts everything.
; ==========================================================================
ISO_CALC_NID:
    ld hl,BUF2K
    ld de,S_PVDID
    ld b,6
    call _C5_LOOP                ; Z=1: 01h "CD001"
    ret nz
    ld hl,(BUF2K+128)            ; logical block size (LE copy) must be 2048
    ld de,2048
    or a
    sbc hl,de
    ret nz
    ld ix,ISO_NID+12             ; identity: hash of the whole PVD block
    call _SH_ZERO
    ld hl,BUF2K
    ld c,8
_IC_PH:
    ld b,0                       ; 8 x 256 bytes
    call _SH_RUN
    dec c
    jr nz,_IC_PH
    ld hl,BUF2K+80               ; identity: volume size (LE copy)
    ld de,ISO_NID+4
    ld bc,4
    ldir
    call ISO_SERIAL_HASH
    ld hl,ISO_SERIAL             ; identity: the volume serial
    ld de,ISO_NID
    ld bc,4
    ldir
    ld hl,(BUF2K+158)            ; root record (PVD+156): extent LE at +2
    ld de,(BUF2K+160)
    ld a,(BUF2K+157)             ; XAR length
    ld c,a
    ld b,0
    add hl,bc
    jr nc,_IC_NOC
    inc de
_IC_NOC:
    ld (ISO_NID+8),hl            ; identity: root extent + XAR
    ld (ISO_NID+10),de
    xor a                        ; Z=1
    ret

; ==========================================================================
; ISO_GEOMETRY - from T_B (B = volume blocks) and ISO_RB:
;   SPC   = smallest power of 2 >= 4 with SPC*8192 >= B, capped at 128
;   N     = min(65524, max(4096, 2*(B >> (log2 SPC - 2)) + 1024))
;   F     = ceil((N+3)*2/512) rounded up to a multiple of 4
;   ROOTS = 4 + F ; DS = ROOTS + 4*RB ; TOTAL = DS + N*SPC
; Corrupts everything.
; ==========================================================================
ISO_GEOMETRY:
    ld c,2                       ; log2(SPC)
    ld hl,8000h
    ld de,0                      ; DE:HL = SPC*8192 for SPC = 4
_GE_SPC:
    ld a,c
    cp 7
    jr z,_GE_SPCOK               ; 128: the cap
    call CMP_DEHL_TB             ; SPC*8192 >= B ?
    jr nc,_GE_SPCOK
    add hl,hl
    rl e
    rl d
    inc c
    jr _GE_SPC
_GE_SPCOK:
    ld a,c
    ld (ISO_SPCSH),a
    ld b,c
    ld a,1
_GE_S2:
    add a,a
    djnz _GE_S2
    ld (ISO_SPC),a
    ld hl,T_B
    call LD_T_A                  ; T_A = B (its LDIR leaves C=0: reload
    ld a,(ISO_SPCSH)             ;  log2(SPC) from memory, not from C)
    sub 2
    call SHR_T_A                 ; T_A = B >> (log2 SPC - 2)  (= B*4/SPC)
    ld hl,T_A
    call _SS0_X2_32              ; *2
    ld hl,(T_A)
    ld de,1024
    add hl,de
    ld (T_A),hl
    jr nc,_GE_N1
    ld hl,T_A+2
    inc (hl)
    jr nz,_GE_N1
    inc hl
    inc (hl)
_GE_N1:
    ld hl,(T_A)
    ld a,(T_A+2)
    or a
    jr nz,_GE_NMAX
    ld a,(T_A+3)
    or a
    jr nz,_GE_NMAX
    ld de,4096
    or a
    sbc hl,de
    add hl,de
    jr nc,_GE_N2
    ld hl,4096
_GE_N2:
    ld de,ISO_NMAX+1
    or a
    sbc hl,de
    add hl,de
    jr c,_GE_NOK
_GE_NMAX:
    ld hl,ISO_NMAX
_GE_NOK:
    ld (ISO_N),hl
    inc hl
    ld (ISO_MAXV),hl
    ; F = (N+3+255) >> 8 ; the sum can pass 16 bits (F = 256 then)
    ld de,257                    ; MAXV + 257 = N + 258
    add hl,de
    ld l,h
    ld h,0
    jr nc,_GE_F1
    inc h
_GE_F1:
    ld de,3
    add hl,de
    ld a,l
    and 0FCh
    ld l,a
    ld (ISO_F),hl
    ld de,4
    add hl,de
    ld (ISO_ROOTS),hl
    ld a,(ISO_RB)
    add a,a
    add a,a
    ld e,a
    ld d,0
    add hl,de
    ld (ISO_DS),hl
    ld hl,(ISO_N)
    ld (T_A),hl
    ld hl,0
    ld (T_A+2),hl
    ld a,(ISO_SPCSH)
    ld b,a
    ld hl,T_A
_GE_TL:
    push bc
    call _SS0_X2_32              ; T_A = N << log2(SPC) (it uses B itself)
    pop bc
    djnz _GE_TL
    ld hl,(T_A)
    ld de,(ISO_DS)
    add hl,de
    ld (ISO_TOTAL),hl
    ld hl,(T_A+2)
    ld de,0
    adc hl,de
    ld (ISO_TOTAL+2),hl
    ret

; CMP_DEHL_TB - compare DE:HL with (T_B): Cy=1 if DE:HL < T_B, Z=1 if equal.
; Preserves BC, DE, HL.
CMP_DEHL_TB:
    push hl
    push de
    push bc
    ld bc,(T_B+2)
    ex de,hl
    or a
    sbc hl,bc
    jr nz,_CT_DONE
    ld bc,(T_B)
    ex de,hl
    or a
    sbc hl,bc
_CT_DONE:
    pop bc
    pop de
    pop hl
    ret

; LD_T_A - T_A = the 32-bit value at (HL). Corrupts BC, DE, HL.
LD_T_A:
    ld de,T_A
    ld bc,4
    ldir
    ret

; SHR_T_A - T_A (32-bit LE) >>= A. Out: Cy=1 if any 1 bit was shifted out
; (a non-zero remainder: the callers add 1 for a ceil). Corrupts AF, BC, HL.
; Whole bytes first (the walk shifts sizes by 11..16 bits per record: bit by
; bit that was ~15% of a directory listing), then the remaining 0..7 bits.
SHR_T_A:
    or a
    ret z
    ld c,0                       ; C = 1 once a 1 bit was shifted out
_ST_BYTE:
    cp 8
    jr c,_ST_BITS
    ld b,a
    ld a,(T_A)                   ; the byte about to be dropped
    or a
    jr z,_ST_B0
    ld c,1
_ST_B0:
    ld hl,(T_A+1)
    ld (T_A),hl
    ld a,(T_A+3)
    ld (T_A+2),a
    xor a
    ld (T_A+3),a
    ld a,b
    sub 8
    jr _ST_BYTE
_ST_BITS:
    or a
    jr z,_ST_DONE
    ld b,a
_ST_LOOP:
    ld hl,T_A+3
    srl (hl)
    dec hl
    rr (hl)
    dec hl
    rr (hl)
    dec hl
    rr (hl)
    jr nc,_ST_NEXT
    ld c,1
_ST_NEXT:
    djnz _ST_LOOP
_ST_DONE:
    ld a,c
    rrca
    ret

; INC24_T_A - T_A (24 bits) += 1. Corrupts AF, HL.
INC24_T_A:
    ld hl,T_A
    inc (hl)
    ret nz
    inc hl
    inc (hl)
    ret nz
    inc hl
    inc (hl)
    ret

; ==========================================================================
; ISO_SERIAL_HASH - ISO_SERIAL = 32-bit hash of 53 bytes of the PVD in
; BUF2K: creation date (+813, 17), volume size LE (+80, 4), volume id
; (+40, 32). Per byte: h = rotl32(h, 1); h = h + b. Corrupts everything.
; ==========================================================================
ISO_SERIAL_HASH:
    ld ix,ISO_SERIAL
    call _SH_ZERO
    ld hl,BUF2K+813
    ld b,17
    call _SH_RUN
    ld hl,BUF2K+80
    ld b,4
    call _SH_RUN
    ld hl,BUF2K+40
    ld b,32
; _SH_RUN - the hash step over B bytes at HL (B=0: 256) into (IX..IX+3).
; HL advances. Preserves C, DE. _SH_ZERO - (IX..IX+3) = 0. Corrupts AF.
_SH_RUN:
    ld a,(ix+3)
    rla                          ; Cy = bit 31
    rl (ix+0)
    rl (ix+1)
    rl (ix+2)
    rl (ix+3)                    ; rotl32 done
    ld a,(hl)
    add a,(ix+0)
    ld (ix+0),a
    ld a,(ix+1)
    adc a,0
    ld (ix+1),a
    ld a,(ix+2)
    adc a,0
    ld (ix+2),a
    ld a,(ix+3)
    adc a,0
    ld (ix+3),a
    inc hl
    djnz _SH_RUN
    ret
_SH_ZERO:
    xor a
    ld (ix+0),a
    ld (ix+1),a
    ld (ix+2),a
    ld (ix+3),a
    ret

; ==========================================================================
; ISO_MAKE_LABEL - ISO_LABEL = the first 11 bytes of the Volume Identifier
; (PVD+40): 00h and space -> space; a-z -> A-Z; other invalid characters
; -> '_'. Eleven spaces -> "ISO9660    ". Corrupts everything.
; ==========================================================================
ISO_MAKE_LABEL:
    ld hl,BUF2K+40
    ld de,ISO_LABEL
    ld b,11
    ld c,0                       ; 1 once a non-space byte was seen
_ML_LOOP:
    ld a,(hl)
    or a
    jr z,_ML_SPACE
    cp ' '
    jr z,_ML_SPACE
    call ISO_FATCHAR
    ld c,1
    jr _ML_PUT
_ML_SPACE:
    ld a,' '
_ML_PUT:
    ld (de),a
    inc hl
    inc de
    djnz _ML_LOOP
    ld a,c
    or a
    ret nz
    ld hl,S_LABEL_DEF
    ld de,ISO_LABEL
    ld bc,11
    ldir
    ret

; ISO_FATCHAR - A = one name byte -> A = its FAT 8.3 form: a-z -> A-Z (not a
; substitution); < 20h, >= 7Fh and the INVALID83 set -> '_' with N_SUB = 1.
; Preserves BC, DE, HL.
ISO_FATCHAR:
    cp 'a'
    jr c,_FC_UP
    cp 'z'+1
    jr nc,_FC_CHK
    sub 20h
    ret
_FC_UP:                          ; A-Z and 0-9 (most ISO names) are valid:
    cp 'A'                       ;  answer them without the table scan
    jr c,_FC_DIG
    cp 'Z'+1
    ret c
    jr _FC_CHK
_FC_DIG:
    cp '0'
    jr c,_FC_CHK
    cp '9'+1
    ret c
_FC_CHK:
    cp 20h
    jr c,_FC_BAD
    cp 7Fh
    jr nc,_FC_BAD
    push hl
    push bc
    ld hl,S_INVALID83
    ld bc,S_INVALID83_LEN
    cpir
    pop bc
    pop hl
    ret nz                       ; not in the table: kept
_FC_BAD:
    ld a,1
    ld (N_SUB),a
    ld a,'_'
    ret

; ISO_RCACHE_CLEAR - forget every resolved child. Corrupts BC, DE, HL.
ISO_RCACHE_CLEAR:
    ld hl,ISO_RCACHE
    ld de,ISO_RCACHE+1
    ld bc,127
    ld (hl),0
    ldir
    ret

; ==========================================================================
; ISO_SETLBA - PHYS_LBA_BE (big-endian, for the CDB) = S_LBA (LE).
; ISO_FETCH  - BUF2K <- block S_LBA through the cache. Cy=1 + A = error.
; ==========================================================================
ISO_SETLBA:
    ld a,(S_LBA+3)
    ld (PHYS_LBA_BE+0),a
    ld a,(S_LBA+2)
    ld (PHYS_LBA_BE+1),a
    ld a,(S_LBA+1)
    ld (PHYS_LBA_BE+2),a
    ld a,(S_LBA+0)
    ld (PHYS_LBA_BE+3),a
    ret
ISO_FETCH:
    call ISO_SETLBA
    jp FETCH_CACHED

; ==========================================================================
; THE WALK - one routine for allocation, synthesis and resolution: it
; classifies the records of the directory block in BUF2K in order and hands
; out virtual clusters from the block's vbase (docs "Asignacion").
;
; ISO_WALK_INIT: HL = vbase, A = flags: bit0 = no DIRBLK row (table full:
;   every child is lost), bit1 = classify only (bootable check).
; ISO_WALK_NEXT: Cy=1 at the end of the block; else W_REC -> record, W_RI =
;   its index (0..59), W_KIND, W_VSTART (0 = none), W_VLEN (clusters).
;   Corrupts everything.
; ==========================================================================
ISO_WALK_INIT:
    ld (W_FLAGS),a
    ld (W_CURSOR),hl
    ld hl,BUF2K
    ld (W_POS),hl
    xor a
    ld (W_RESUME),a              ; a new walk: nothing left to resume
    ld (W_I),a
    ld h,a
    ld l,a
    ld (W_PREV),hl
    ret

ISO_WALK_NEXT:
    ld hl,(W_POS)
    ld a,(hl)                    ; record length
    or a
    jp z,_WN_END                 ; 00h: padding up to the end of the block
    cp 34
    jp c,_WN_END                 ; below the minimum (33 + 1): corrupt
    ld e,a
    ld d,0
    push hl
    add hl,de                    ; HL = next record
    ld a,h
    cp 88h                       ; may not cross the end of BUF2K (8800h)
    jr c,_WN_FITS
    jp nz,_WN_ENDP
    ld a,l
    or a
    jp nz,_WN_ENDP
_WN_FITS:
    ld (W_POS),hl
    pop ix                       ; IX = this record
    ld (W_REC),ix
    ld a,(W_I)
    ld (W_RI),a
    inc a
    ld (W_I),a
    ld hl,0
    ld (W_VLEN),hl
    ld (W_VSTART),hl
    ; ---- classification (static: only the record and its predecessor) ----
    ld a,(ix+32)                 ; identifier length
    or a
    jp z,_WN_BAD
    add a,33
    jp c,_WN_BAD
    cp (ix+0)
    jr z,_WN_NL
    jp nc,_WN_BAD                ; 33 + nl > record length: corrupt
_WN_NL:
    ld a,(ix+32)
    cp 1
    jr nz,_WN_NAMED
    ld a,(ix+33)
    or a
    jp z,_WN_DOT                 ; identifier 00h = "."
    cp 1
    jp z,_WN_DOTDOT              ; identifier 01h = ".."
_WN_NAMED:
    ld a,(ix+25)                 ; ISO flags
    bit 2,a
    jp nz,_WN_HIDE               ; associated file
    bit 7,a
    jp nz,_WN_HIDE               ; multi-extent, not the final extent
    ; the final extent follows (same block) a bit-7 record with the same name
    ld hl,(W_PREV)
    ld a,h
    or l
    jr z,_WN_VISIBLE
    push hl
    pop iy
    bit 7,(iy+25)
    jr z,_WN_VISIBLE
    ld a,(iy+32)
    cp (ix+32)
    jr nz,_WN_VISIBLE
    ld de,33
    add hl,de
    ex de,hl                     ; DE = previous identifier
    push ix
    pop hl
    ld bc,33
    add hl,bc                    ; HL = this identifier
    ld b,(ix+32)
_WN_CMPN:
    ld a,(de)
    cp (hl)
    jr nz,_WN_VISIBLE
    inc hl
    inc de
    djnz _WN_CMPN
    jp _WN_HIDE
_WN_VISIBLE:
    ld (W_PREV),ix
    ld a,K_FILE
    bit 1,(ix+25)
    jr z,_WN_SETK
    ld a,K_DIR
_WN_SETK:
    ld (W_KIND),a
    ; ---- clusters ----
    ld a,(W_FLAGS)
    bit 1,a
    jp nz,_WN_OK                 ; classify only
    push ix
    pop iy
    call ISO_VLEN                ; T_A = clusters needed (24 bits)
    ld a,(W_KIND)
    cp K_FILE
    jr nz,_WN_NOTBIG
    ld a,(T_A+2)                 ; a file over 32768 clusters: Nextor could
    or a                         ;  not read it whole -> lost, costs nothing
    jr nz,_WN_BIG
    ld hl,(T_A)
    ld a,h
    cp 80h
    jr c,_WN_NOTBIG
    jr nz,_WN_BIG
    ld a,l
    or a
    jr z,_WN_NOTBIG
_WN_BIG:
    ld a,4
    jr _WN_LOST
_WN_NOTBIG:
    ld a,(W_FLAGS)
    bit 0,a
    ld a,1
    jr nz,_WN_LOST               ; table full: no row for this block
    ld hl,(W_CURSOR)
    ld de,(T_A)
    add hl,de                    ; HL = cursor + vlen
    ld a,2
    jr c,_WN_LOST                ; beyond 16 bits: cannot fit
    ld bc,(ISO_MAXV)
    inc bc
    push hl
    or a
    sbc hl,bc
    pop hl
    jr c,_WN_FIT
    jr nz,_WN_LOST               ; cursor + vlen > MAXV + 1: space exhausted
_WN_FIT:
    ld (W_CURSOR),hl
    ld (W_VLEN),de
    ld a,d
    or e
    jr z,_WN_OK                  ; an empty file: cluster 0
    or a
    sbc hl,de
    ld (W_VSTART),hl
_WN_OK:
    or a
    ret
_WN_LOST:
    ld hl,ISO_LOST
    or (hl)
    ld (hl),a                    ; remembered for CALL DREAM ("partial")
    ld a,K_LOST
    ld (W_KIND),a
    jr _WN_OK
_WN_BAD:
    ld hl,0
    ld (W_PREV),hl               ; a corrupt record never matches as previous
    ld a,K_HIDE
    jr _WN_KIND
_WN_HIDE:
    ld a,K_HIDE
    jr _WN_PREVK
_WN_DOT:
    ld a,K_DOT
    jr _WN_PREVK
_WN_DOTDOT:
    ld a,K_DOTDOT
_WN_PREVK:
    ld (W_PREV),ix
_WN_KIND:
    ld (W_KIND),a
    jr _WN_OK
_WN_ENDP:
    pop hl
_WN_END:
    scf
    ret

; ISO_NBLK - T_A = data blocks of the record at IY: ceil(size/2048), capped
; at 1024 for a directory (W_KIND = K_DIR). Corrupts AF, BC, DE, HL.
ISO_NBLK:
    push iy
    pop hl
    ld de,10
    add hl,de
    call LD_T_A
    ld a,11
    call SHR_T_A
    call c,INC24_T_A
    ld a,(W_KIND)
    cp K_DIR
    ret nz
    ld a,(T_A+2)
    or a
    jr nz,_NB_CAP
    ld hl,(T_A)
    ld de,1024
    or a
    sbc hl,de
    ret c
_NB_CAP:
    ld hl,1024
    ld (T_A),hl
    xor a
    ld (T_A+2),a
    ret

; ISO_VLEN - T_A = virtual clusters of the child at IY (W_KIND = file/dir):
;   file: ceil(size / (SPC*512))       (0 for an empty file)
;   dir : ceil((min(nb,1024) + 1) * 2048 / (SPC*512))   (+1 = the zero
;         block that terminates the directory)
; Corrupts AF, BC, DE, HL.
ISO_VLEN:
    ld a,(W_KIND)
    cp K_DIR
    jr z,_VL_DIR
    push iy
    pop hl
    ld de,10
    add hl,de
    call LD_T_A
    ld a,(ISO_SPCSH)
    add a,9
    call SHR_T_A
    ret nc
    jp INC24_T_A
_VL_DIR:
    call ISO_NBLK
    ld a,(ISO_SPC)
    srl a
    srl a                        ; SPC/4 blocks per cluster
    ld e,a
    ld d,0
    ld hl,(T_A)
    add hl,de
    ld (T_A),hl                  ; nb + SPC/4 (<= 1056)
    ld a,(ISO_SPCSH)
    sub 2
    jp SHR_T_A                   ; floor -> ceil((nb + 1) / (SPC/4))

; ==========================================================================
; ISO_ROWADDR - HL = row index -> HL = address of that DIRBLK row (7 bytes:
; lba 3, vbase 2, owner 2). Preserves DE. Corrupts AF.
; ==========================================================================
ISO_ROWADDR:
    push de
    ld d,h
    ld e,l
    add hl,hl
    add hl,hl
    add hl,hl
    or a
    sbc hl,de                    ; *7
    ld de,DIRBLK
    add hl,de
    pop de
    ret

; ISO_FIND_ROW - the DIRBLK row of block S_LBA: HL -> row (Cy=0) or Cy=1.
; Linear search by lba with a one-entry cache (the four sectors of a block
; arrive one after the other). Corrupts everything.
ISO_FIND_ROW:
    ld hl,(ISO_LCROW)
    ld a,h
    or l
    jr z,_FR_SCAN
    ld a,(ISO_LCLBA)
    ld b,a
    ld a,(S_LBA)
    cp b
    jr nz,_FR_SCAN
    ld a,(ISO_LCLBA+1)
    ld b,a
    ld a,(S_LBA+1)
    cp b
    jr nz,_FR_SCAN
    ld a,(ISO_LCLBA+2)
    ld b,a
    ld a,(S_LBA+2)
    cp b
    ret z
_FR_SCAN:
    ld hl,DIRBLK
    ld bc,(ISO_NROWS)
_FR_LOOP:
    ld a,b
    or c
    scf
    ret z
    ld a,(S_LBA)
    cp (hl)
    jr nz,_FR_NEXT
    inc hl
    ld a,(S_LBA+1)
    cp (hl)
    jr nz,_FR_NEXT1
    inc hl
    ld a,(S_LBA+2)
    cp (hl)
    jr nz,_FR_NEXT2
    dec hl
    dec hl
ISO_ROW_REMEMBER:                ; HL = row -> the one-entry cache
    ld (ISO_LCROW),hl
    push hl
    ld hl,S_LBA
    ld de,ISO_LCLBA
    ld bc,3
    ldir
    pop hl
    or a
    ret
_FR_NEXT2:
    dec hl
_FR_NEXT1:
    dec hl
_FR_NEXT:
    ld de,7
    add hl,de
    dec bc
    jr _FR_LOOP

; ==========================================================================
; ISO_SYNTH - TRANS_BUF = quarter S_Q (16 entries) of the synthesized FAT
; directory block for ISO block S_LBA = block S_K of the directory whose
; cluster is S_O (parent S_P; S_ROOT = 1 for the root). The block gets its
; DIRBLK row the first time it is synthesized (vbase = VNEXT). Cy=1 + A =
; error on a read failure. Corrupts everything.
; ==========================================================================
ISO_SYNTH:
    call ISO_FETCH
    ret c
    ; ---- resume: the previous synthesis stopped right before THIS quarter
    ; of THIS block (DOS reads a directory sector after sector), and no
    ; other walk ran since (ISO_WALK_INIT clears W_RESUME): the walk state
    ; W_* is exactly what a walk from record 0 would reach here, so carry
    ; on instead of re-walking (and re-sizing) every earlier record. BUF2K
    ; holds the same block again (ISO_FETCH above), so W_POS/W_PREV/W_REC
    ; still point at the right records.
    ld a,(W_RESUME)
    or a
    jr z,_SY_FIND
    ld a,(S_Q)
    ld b,a
    ld a,(W_RQ)
    cp b
    jr nz,_SY_FIND
    ld hl,S_LBA
    ld de,W_RLBA
    ld b,4
_SY_RCMP:
    ld a,(de)
    cp (hl)
    jr nz,_SY_FIND
    inc hl
    inc de
    djnz _SY_RCMP
    xor a
    ld (W_RESUME),a              ; re-armed below only by a clean stop
    jr _SY_QUARTER
_SY_FIND:
    call ISO_FIND_ROW
    jr nc,_SY_HAVE
    ld hl,(ISO_NROWS)
    ld de,DIRBLK_CAP
    or a
    sbc hl,de
    jr nc,_SY_FULL
    ; ---- allocate: walk the whole block from VNEXT, append the row ----
    ld hl,(ISO_VNEXT)
    ld (S_VBASE),hl
    xor a
    call ISO_WALK_INIT
_SY_AL:
    call ISO_WALK_NEXT
    jr nc,_SY_AL
    ld hl,(ISO_NROWS)
    call ISO_ROWADDR
    push hl
    ex de,hl
    ld hl,S_LBA
    ld bc,3
    ldir                         ; lba
    ld hl,(S_VBASE)
    ex de,hl
    ld (hl),e
    inc hl
    ld (hl),d                    ; vbase
    inc hl
    ld de,(S_O)
    ld (hl),e
    inc hl
    ld (hl),d                    ; owner
    pop hl
    call ISO_ROW_REMEMBER
    ld hl,(ISO_NROWS)
    inc hl
    ld (ISO_NROWS),hl
    ld hl,(W_CURSOR)
    ld (ISO_VNEXT),hl
    xor a
    jr _SY_WALK
_SY_FULL:
    ld a,1                       ; no row: every child of this block is lost
    jr _SY_WALK
_SY_HAVE:
    inc hl
    inc hl
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (S_VBASE),de
    xor a
_SY_WALK:
    ; ---- synthesis pass: entries 16q .. 16q+15 ----
    ld hl,(S_VBASE)
    call ISO_WALK_INIT
_SY_QUARTER:
    ld a,(S_Q)
    add a,a
    add a,a
    add a,a
    add a,a
    ld (S_FIRST),a
    ld hl,TRANS_BUF
    ld (S_OUT),hl
    ld a,16
    ld (S_CNT),a
_SY_EL:
    call ISO_WALK_NEXT
    jr c,_SY_ENDB
    ld a,(S_FIRST)
    ld b,a
    ld a,(W_RI)
    cp b
    jr c,_SY_EL                  ; before this quarter
    sub b
    cp 16
    jr nc,_SY_FILL               ; past it: done
    ld de,(S_OUT)
    call ISO_EMIT
    ld hl,(S_OUT)
    ld de,32
    add hl,de
    ld (S_OUT),hl
    ld hl,S_CNT
    dec (hl)
    jr nz,_SY_EL
    call _SY_ARM                 ; the walk stopped right before quarter q+1
    or a
    ret
_SY_ENDB:                        ; the block ran out: every later quarter
    call _SY_ARM                 ;  resumes at its end (all E5h)
_SY_FILL:                        ; unused slots: E5h + 31 zeros
    ld a,(S_CNT)
    or a
    ret z
    ld b,a
    ld de,(S_OUT)
_SY_FL:
    push bc
    call ISO_PUT_E5
    pop bc
    djnz _SY_FL
    or a
    ret

; _SY_ARM - remember that the walk state now sits right before quarter
; S_Q+1 of block S_LBA (see the resume at the top of ISO_SYNTH). The walk
; is deterministic: when it ended (Cy), W_POS stays on the record that ended
; it, so a resumed ISO_WALK_NEXT ends again. Corrupts AF, BC, DE, HL.
_SY_ARM:
    ld hl,S_LBA
    ld de,W_RLBA
    ld bc,4
    ldir
    ld a,(S_Q)
    inc a
    ld (W_RQ),a
    ld a,1
    ld (W_RESUME),a
    ret

; ISO_PUT_E5 - a free/hidden slot at DE: E5h + 31 zeros. DE += 32. Corrupts AF, B.
ISO_PUT_E5:
    ld a,0E5h
    ld (de),a
    inc de
    xor a
    ld b,31
_PE_L:
    ld (de),a
    inc de
    djnz _PE_L
    ret

; ==========================================================================
; ISO_EMIT - the 32-byte FAT entry at DE for the record the walk just
; returned. Corrupts everything.
; ==========================================================================
ISO_EMIT:
    ld iy,(W_REC)
    ld a,(W_KIND)
    cp K_HIDE
    jp z,ISO_PUT_E5
    cp K_LOST
    jp z,ISO_PUT_E5
    cp K_DOT
    jr z,_EM_DOT
    cp K_DOTDOT
    jr z,_EM_DOTDOT
    push de
    push af
    call ISO_NAME83              ; -> N_NAME
    pop af
    pop de
    ld hl,N_NAME
    ld b,0
    bit 0,(iy+25)                ; ISO "existence" bit -> FAT hidden
    jr z,_EM_A1
    ld b,02h
_EM_A1:
    cp K_DIR
    jr nz,_EM_FILE
    ld a,b
    or 10h
    ld bc,(W_VSTART)
    jp ISO_PUT_ENTRY0
_EM_FILE:
    ld a,b
    ld bc,(W_VSTART)             ; (0 for an empty file)
    jp ISO_PUT_ENTRY
_EM_DOT:
    ld a,(S_ROOT)
    or a
    jr z,_EM_DOT2
    ld hl,ISO_LABEL              ; root: the volume label entry
    ld a,08h
    ld bc,0
    jp ISO_PUT_ENTRY0
_EM_DOT2:
    ld hl,S_DOTNAME
    ld a,10h
    ld bc,(S_O)
    jp ISO_PUT_ENTRY0
_EM_DOTDOT:
    ld a,(S_ROOT)
    or a
    jp nz,ISO_PUT_E5             ; the root has no ".."
    ld hl,S_DOTDOTNAME
    ld a,10h
    ld bc,(S_P)                  ; (0 when the parent is the root)
    jp ISO_PUT_ENTRY0

; ISO_PUT_ENTRY - entry at DE: name (HL, 11), attr A, +0C..+15 zeros, time
; and date from record IY (+18), cluster BC, size = the record's (32 bits).
; ISO_PUT_ENTRY0: size 0. Corrupts everything.
ISO_PUT_ENTRY0:
    push af
    xor a
    ld (S_SZ),a
    pop af
    jr _PE_GO
ISO_PUT_ENTRY:
    push af
    ld a,1
    ld (S_SZ),a
    pop af
_PE_GO:
    push bc
    push af
    ld bc,11
    ldir
    pop af
    ld (de),a                    ; +0B attributes
    inc de
    xor a
    ld b,10
_PE_Z:
    ld (de),a                    ; +0C..+15
    inc de
    djnz _PE_Z
    call ISO_DATE                ; HL = time, BC = date
    ex de,hl
    ld (hl),e
    inc hl
    ld (hl),d                    ; +16 time
    inc hl
    ld (hl),c
    inc hl
    ld (hl),b                    ; +18 date
    inc hl
    pop bc
    ld (hl),c
    inc hl
    ld (hl),b                    ; +1A first cluster
    inc hl
    ld a,(S_SZ)
    or a
    jr z,_PE_SZ0
    ld a,(iy+10)
    ld (hl),a
    inc hl
    ld a,(iy+11)
    ld (hl),a
    inc hl
    ld a,(iy+12)
    ld (hl),a
    inc hl
    ld a,(iy+13)
    ld (hl),a                    ; +1C size
    ret
_PE_SZ0:
    xor a
    ld (hl),a
    inc hl
    ld (hl),a
    inc hl
    ld (hl),a
    inc hl
    ld (hl),a
    ret

; ISO_DATE - record IY's 7-byte date (+18: y-1900, mo, d, h, mi, s, gmt) ->
; HL = FAT time (h<<11 | mi<<5 | s/2), BC = FAT date ((y-80)<<9 | mo<<5 | d;
; before 1980 -> 0021h; year field capped at 127). Preserves DE, IY.
ISO_DATE:
    ld a,(iy+21)
    and 31
    add a,a
    add a,a
    add a,a                      ; hour << 3
    ld b,a
    ld a,(iy+22)
    and 63
    ld c,a
    rrca
    rrca
    rrca
    and 7                        ; minutes >> 3
    or b
    ld h,a
    ld a,c
    and 7
    rrca
    rrca
    rrca                         ; (minutes & 7) << 5
    ld b,a
    ld a,(iy+23)
    srl a
    and 31                       ; seconds / 2
    or b
    ld l,a
    ld a,(iy+18)
    cp 80
    jr c,_DT_OLD
    sub 80
    cp 128
    jr c,_DT_Y
    ld a,127
_DT_Y:
    add a,a                      ; year << 1
    ld b,a
    ld a,(iy+19)
    and 15
    ld c,a
    rrca
    rrca
    rrca
    and 1                        ; month >> 3
    or b
    ld b,a
    ld a,c
    and 7
    rrca
    rrca
    rrca                         ; (month & 7) << 5
    ld c,a
    ld a,(iy+20)
    and 31
    or c
    ld c,a
    ret
_DT_OLD:
    ld bc,0021h
    ret

; ==========================================================================
; ISO_NAME83 - N_NAME (11 bytes "BASE    EXT") for the record at W_REC,
; k = S_K, i = W_RI (docs "Nombres 8.3"):
;  1. cut ";version" (only if all after the LAST ';' are digits), then one
;     trailing '.';
;  2. split at the LAST '.';
;  3. a-z -> A-Z, invalid characters -> '_' (a substitution);
;  4. 1 <= base <= 8, ext <= 3, no substitution -> as-is;
;  5. else "~n" (n = 64k + i + 1) after the base cut to fit, ext cut to 3.
; Corrupts AF, BC, DE, HL, IY.
; ==========================================================================
ISO_NAME83:
    ld iy,(W_REC)
    xor a
    ld (N_SUB),a
    push iy
    pop hl
    ld de,33
    add hl,de
    ld (N_PTR),hl
    ld a,(iy+32)
    ld (N_LEN),a
    ; 1. version
    ld c,';'
    call N_RFIND
    jr c,_NM_NOVER
    ld c,a                       ; C = index of the last ';'
    ld a,(N_LEN)
    sub c
    dec a                        ; characters after it
    jr z,_NM_NOVER
    ld b,a
    ld hl,(N_PTR)
    ld e,c
    ld d,0
    add hl,de
    inc hl
_NM_DG:
    ld a,(hl)
    sub '0'
    cp 10
    jr nc,_NM_NOVER              ; not all digits: keep the whole name
    inc hl
    djnz _NM_DG
    ld a,c
    ld (N_LEN),a
_NM_NOVER:
    ld a,(N_LEN)
    or a
    jr z,_NM_SPLIT
    ld hl,(N_PTR)
    ld e,a
    ld d,0
    add hl,de
    dec hl
    ld a,(hl)
    cp '.'
    jr nz,_NM_SPLIT
    ld hl,N_LEN
    dec (hl)                     ; one trailing '.'
_NM_SPLIT:
    ; 2. base / extension
    ld c,'.'
    call N_RFIND
    jr nc,_NM_DOT
    ld a,(N_LEN)
    ld (N_LB),a
    xor a
    ld (N_LE),a
    jr _NM_CONV
_NM_DOT:
    ld (N_LB),a
    ld c,a
    ld a,(N_LEN)
    sub c
    dec a
    ld (N_LE),a
_NM_CONV:
    ; 3. convert (all characters count for the substitution flag)
    ld hl,N_NAME
    ld a,' '
    ld b,11
_NM_SP:
    ld (hl),a
    inc hl
    djnz _NM_SP
    ld hl,(N_PTR)
    ld de,N_NAME
    ld a,(N_LB)
    ld c,8
    call N_CONVRUN
    ld a,(N_LE)
    or a
    jr z,_NM_CHK
    inc hl                       ; skip the '.'
    ld de,N_NAME+8
    ld c,3
    call N_CONVRUN
_NM_CHK:
    ; 4. as-is?
    ld a,(N_SUB)
    or a
    jr nz,_NM_MANGLE
    ld a,(N_LB)
    or a
    jr z,_NM_MANGLE
    cp 9
    jr nc,_NM_MANGLE
    ld a,(N_LE)
    cp 4
    ret c
_NM_MANGLE:
    ; 5. "~n" with n = 64*k + i + 1 (fits 16 bits: k < 1024, i <= 59)
    ld hl,(S_K)
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    ld a,(W_RI)
    ld e,a
    ld d,0
    add hl,de
    inc hl                       ; HL = n (1..65532)
    ld de,N_DIG                  ; decimal digits, most significant first
    ld bc,-10000
    call _NM_D
    ld bc,-1000
    call _NM_D
    ld bc,-100
    call _NM_D
    ld bc,-10
    call _NM_D
    ld a,l
    add a,'0'
    ld (de),a                    ; the units digit, always
    inc de
    ex de,hl
    ld de,N_DIG
    or a
    sbc hl,de
    ld c,l                       ; C = digits (1..5)
    ld a,7
    sub c                        ; base characters kept = 8 - (1 + digits)
    ld b,a
    ld a,(N_LB)
    cp b
    jr c,_NM_KEEP
    ld a,b
_NM_KEEP:
    ld hl,N_NAME
    ld e,a
    ld d,0
    add hl,de
    ld (hl),'~'
    inc hl
    ex de,hl
    ld hl,N_DIG
    ld b,0
    ldir                         ; BC = C digits
    ex de,hl                     ; HL -> after the digits
    ld de,N_NAME+8
_NM_PS:                          ; the rest of the base field: spaces
    push hl
    or a
    sbc hl,de
    pop hl
    ret nc
    ld (hl),' '
    inc hl
    jr _NM_PS

; _NM_D - one decimal digit of HL for the power of ten -BC (BC = -10^k):
; HL -= digit*10^k; the digit goes to (DE++) unless it is a leading zero
; (nothing stored yet: DE = N_DIG). Corrupts AF.
_NM_D:
    ld a,'0'-1
_ND_L:
    inc a
    add hl,bc                    ; Cy = no borrow: HL was >= 10^k
    jr c,_ND_L
    sbc hl,bc                    ; (Cy=0) undo the step that went below 0
    cp '0'
    jr nz,_ND_PUT
    push hl
    ld hl,N_DIG
    or a
    sbc hl,de
    pop hl
    ret z                        ; a leading zero
_ND_PUT:
    ld (de),a
    inc de
    ret

; N_RFIND - last occurrence of C in the identifier [0, N_LEN): A = index
; (Cy=0) or Cy=1. Corrupts AF, B, DE, HL.
N_RFIND:
    ld a,(N_LEN)
    or a
    scf
    ret z
    ld b,a
    ld hl,(N_PTR)
    ld e,a
    ld d,0
    add hl,de
_RF_L:
    dec hl
    ld a,(hl)
    cp c
    jr z,_RF_HIT
    djnz _RF_L
    scf
    ret
_RF_HIT:
    ld a,b
    dec a
    ret

; N_CONVRUN - convert A identifier bytes from (HL) with ISO_FATCHAR, storing
; the first C of them at (DE). HL advances by A. Corrupts AF, B, C, DE.
N_CONVRUN:
    or a
    ret z
    ld b,a
_CR_L:
    ld a,(hl)
    inc hl
    call ISO_FATCHAR
    inc c
    dec c
    jr z,_CR_N
    ld (de),a
    inc de
    dec c
_CR_N:
    djnz _CR_L
    ret

; ==========================================================================
; ISO_RESOLVE - HL = virtual cluster v -> IX = resolution cache entry
; (Cy=0), or Cy=1 with A = 0 (v not allocated: served as zeros) / A = Nextor
; error (a directory block could not be read). Miss: binary search of the
; LAST DIRBLK row with vbase <= v, then the walk of that block until the
; child that contains v. Corrupts everything.
; ==========================================================================
ISO_RESOLVE:
    ld (R_V),hl
    ld de,2
    or a
    sbc hl,de
    jp c,_RS_NONE                ; v < 2
    ld hl,(R_V)
    ld de,(ISO_VNEXT)
    or a
    sbc hl,de
    jp nc,_RS_NONE               ; v >= VNEXT: never allocated
    ld ix,ISO_RCACHE
    ld b,8
_RS_CL:
    bit 7,(ix+RC_FLAGS)
    jr z,_RS_CN
    ld hl,(R_V)
    ld e,(ix+RC_VSTART)
    ld d,(ix+RC_VSTART+1)
    or a
    sbc hl,de
    jr c,_RS_CN                  ; v < vstart
    ld hl,(R_V)
    ld e,(ix+RC_VEND)
    ld d,(ix+RC_VEND+1)
    or a
    sbc hl,de
    jr nc,_RS_CN                 ; v >= vend
    or a
    ret                          ; hit
_RS_CN:
    ld de,16
    add ix,de
    djnz _RS_CL
    ; ---- binary search: lo = 0, hi = NROWS ----
    ld hl,0
    ld (T_B),hl
    ld hl,(ISO_NROWS)
    ld (T_B+2),hl
_RS_BS:
    ld hl,(T_B+2)
    ld de,(T_B)
    or a
    sbc hl,de
    jr z,_RS_BSDONE
    srl h
    rr l
    add hl,de                    ; mid = lo + (hi - lo)/2
    push hl
    call ISO_ROWADDR
    inc hl
    inc hl
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)                    ; DE = row[mid].vbase
    ld hl,(R_V)
    or a
    sbc hl,de
    pop hl
    jr c,_RS_BSHI                ; vbase > v: hi = mid
    inc hl
    ld (T_B),hl                  ; vbase <= v: lo = mid + 1
    jr _RS_BS
_RS_BSHI:
    ld (T_B+2),hl
    jr _RS_BS
_RS_BSDONE:
    ld hl,(T_B)
    ld a,h
    or l
    jp z,_RS_NONE                ; no row at all (cannot happen: v < VNEXT)
    dec hl
    call ISO_ROWADDR
    ld (R_ROW),hl
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld a,(hl)
    inc hl
    ld (S_LBA),de
    ld (S_LBA+2),a
    xor a
    ld (S_LBA+3),a
    ld e,(hl)
    inc hl
    ld d,(hl)                    ; DE = vbase
    push de
    call ISO_FETCH               ; the parent directory block
    pop hl
    ret c                        ; A = error
    xor a
    call ISO_WALK_INIT
_RS_WL:
    call ISO_WALK_NEXT
    jp c,_RS_NONE                ; (unreachable for a consistent row)
    ld hl,(W_VLEN)
    ld a,h
    or l
    jr z,_RS_WL
    ld de,(W_VSTART)
    ld hl,(R_V)
    or a
    sbc hl,de
    jr c,_RS_WL                  ; v < vstart
    ld de,(W_VLEN)
    or a
    sbc hl,de
    jr nc,_RS_WL                 ; v >= vstart + vlen
    ; ---- found: fill the next cache entry (round robin) ----
    ld a,(ISO_RCNEXT)
    ld l,a
    inc a
    and 7
    ld (ISO_RCNEXT),a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    ld de,ISO_RCACHE
    add hl,de
    push hl
    pop ix
    ld hl,(W_VSTART)
    ld (ix+RC_VSTART),l
    ld (ix+RC_VSTART+1),h
    ld de,(W_VLEN)
    add hl,de
    ld (ix+RC_VEND),l
    ld (ix+RC_VEND+1),h
    ld iy,(W_REC)
    ld l,(iy+2)
    ld h,(iy+3)
    ld e,(iy+4)
    ld d,(iy+5)
    ld c,(iy+1)
    ld b,0
    add hl,bc                    ; extent + XAR
    jr nc,_RS_NC
    inc de
_RS_NC:
    ld (ix+RC_START),l
    ld (ix+RC_START+1),h
    ld (ix+RC_START+2),e
    ld (ix+RC_START+3),d
    call ISO_NBLK
    ld a,(T_A)
    ld (ix+RC_NBLK),a
    ld a,(T_A+1)
    ld (ix+RC_NBLK+1),a
    ld a,(T_A+2)
    ld (ix+RC_NBLK+2),a
    ld a,(W_KIND)
    cp K_DIR
    ld a,80h
    jr nz,_RS_FL
    ld a,81h
_RS_FL:
    ld (ix+RC_FLAGS),a
    ld hl,(R_ROW)
    ld de,5
    add hl,de
    ld a,(hl)
    ld (ix+RC_PARENT),a
    inc hl
    ld a,(hl)
    ld (ix+RC_PARENT+1),a
    or a
    ret
_RS_NONE:
    xor a
    scf
    ret

; ==========================================================================
; ISO_BOOTSEC - TRANS_BUF = the synthetic boot sector (docs "Boot sector").
; ==========================================================================
ISO_BOOTSEC:
    call ISO_ZERO_TRANS
    ld hl,BOOT_TEMPLATE
    ld de,TRANS_BUF
    ld bc,BOOT_TEMPLATE_LEN
    ldir
    ld ix,TRANS_BUF
    ld a,(ISO_BOOT)
    or a
    jr z,_BS_NB
    ld a,0EBh                    ; only a bootable disc gets the jump
_BS_NB:
    ld (ix+00h),a
    ld (ix+0Bh),00h              ; 512 bytes/sector
    ld (ix+0Ch),02h
    ld a,(ISO_SPC)
    ld (ix+0Dh),a
    ld (ix+0Eh),04h              ; reserved sectors
    ld (ix+0Fh),00h
    ld (ix+10h),01h              ; one FAT
    ld a,(ISO_RB)
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl                    ; root entries = 64*RB
    ld (ix+11h),l
    ld (ix+12h),h
    ld (ix+15h),0F8h             ; media
    ld hl,(ISO_F)
    ld (ix+16h),l
    ld (ix+17h),h
    ld (ix+1Eh),0C9h             ; RET for a failed boot (see docs)
    ld a,(ISO_TOTAL)
    ld (ix+20h),a
    ld a,(ISO_TOTAL+1)
    ld (ix+21h),a
    ld a,(ISO_TOTAL+2)
    ld (ix+22h),a
    ld a,(ISO_TOTAL+3)
    ld (ix+23h),a
    ld hl,ISO_SERIAL
    ld de,TRANS_BUF+27h
    ld bc,4
    ldir
    ld hl,ISO_LABEL
    ld de,TRANS_BUF+2Bh
    ld bc,11
    ldir
    ld hl,TRANS_BUF+1FEh
    ld (hl),55h
    inc hl
    ld (hl),0AAh
    ret

; ISO_FATSEC - TRANS_BUF = FAT sector A (entries 256A .. 256A+255):
; FAT[0] = FFF8h, FAT[1] = FFFFh, 2 <= e < MAXV -> e+1, e = MAXV -> FFFFh,
; e > MAXV -> 0000h. Corrupts everything.
ISO_FATSEC:
    ld h,a
    ld l,0
    ld de,TRANS_BUF
    ld b,0
_FS_L:
    push bc
    ld a,h
    or l
    jr nz,_FS_1
    ld bc,0FFF8h
    jr _FS_PUT
_FS_1:
    ld bc,(ISO_MAXV)
    push hl
    or a
    sbc hl,bc
    pop hl
    jr z,_FS_EOC                 ; e = MAXV
    jr nc,_FS_ZERO               ; e > MAXV
    ld a,h
    or a
    jr nz,_FS_NEXTE
    ld a,l
    cp 1
    jr z,_FS_EOC                 ; e = 1
_FS_NEXTE:
    ld b,h
    ld c,l
    inc bc
    jr _FS_PUT
_FS_EOC:
    ld bc,0FFFFh
    jr _FS_PUT
_FS_ZERO:
    ld bc,0
_FS_PUT:
    ex de,hl
    ld (hl),c
    inc hl
    ld (hl),b
    inc hl
    ex de,hl
    inc hl
    pop bc
    djnz _FS_L
    ret

; ISO_ZERO_TRANS - TRANS_BUF = 512 zeros. Corrupts BC, DE, HL.
ISO_ZERO_TRANS:
    ld hl,TRANS_BUF
    ld de,TRANS_BUF+1
    ld bc,511
    ld (hl),0
    ldir
    ret

; ==========================================================================
; ISO_RW - the DEV_RW body in ISO mode. Entered from DEV_RW with the segment
; mapped, the mechanical budget on and the inputs stashed (SECNUM, COUNT,
; RWDEST_CUR, RW_ISWRITE). Every write is refused (write-protect): the
; virtual sectors have no physical home. Sectors >= TOTAL: record not found.
; ==========================================================================
ISO_RW:
    ld a,(RW_ISWRITE)
    or a
    jr z,_IRW_LOOP
    call BUDGET_NORMAL
    call EXIT_SEG
    ld a,NX_EWPROT
    ld b,0
    ret
_IRW_LOOP:
    ld a,(COUNT)
    or a
    jp z,_RW_OK
    ld hl,(SECNUM+2)
    ld de,(ISO_TOTAL+2)
    or a
    sbc hl,de
    jr c,_IRW_INRANGE
    jp nz,_IRW_RNF
    ld hl,(SECNUM)
    ld de,(ISO_TOTAL)
    or a
    sbc hl,de
    jp nc,_IRW_RNF
_IRW_INRANGE:
    ld a,(SECNUM+2)
    or a
    jp nz,_IRW_DATA              ; >= 65536: data area
    ld hl,(SECNUM)
    ld a,h
    or l
    jp z,_IRW_BOOT
    ld de,4
    or a
    sbc hl,de
    jp c,_IRW_ZERO               ; 1..3: reserved
    ld hl,(SECNUM)
    ld de,(ISO_ROOTS)
    or a
    sbc hl,de
    jp c,_IRW_FAT
    ld hl,(SECNUM)
    ld de,(ISO_DS)
    or a
    sbc hl,de
    jp nc,_IRW_DATA
    ; ---- root directory: block j = (ls - ROOTS)/4, quarter q ----
    ld hl,(SECNUM)
    ld de,(ISO_ROOTS)
    or a
    sbc hl,de
    ld a,l
    and 3
    ld (S_Q),a
    srl h
    rr l
    srl h
    rr l
    ld (S_K),hl
    ld de,(ISO_ROOT)
    add hl,de
    ld (S_LBA),hl
    ld hl,(ISO_ROOT+2)
    ld de,0
    adc hl,de
    ld (S_LBA+2),hl
    ld hl,0
    ld (S_O),hl
    ld (S_P),hl
    ld a,1
    ld (S_ROOT),a
    call ISO_SYNTH
    jp c,_RW_ERR
    jp _IRW_OUT_TRANS
_IRW_BOOT:
    call ISO_BOOTSEC
    jr _IRW_OUT_TRANS
_IRW_ZERO:
    call ISO_ZERO_TRANS
    jr _IRW_OUT_TRANS
_IRW_FAT:
    ld a,(SECNUM)
    sub 4                        ; FAT sector index (< 256: ROOTS <= 260)
    call ISO_FATSEC
_IRW_OUT_TRANS:
    ld hl,TRANS_BUF
_IRW_OUT:
    ld de,(RWDEST_CUR)
    ld bc,512
    call COPY_OUT
    ld a,1
    call ADVANCE_SECTORS
    ld hl,(RWDEST_CUR)
    inc h
    inc h
    ld (RWDEST_CUR),hl
    jp _IRW_LOOP
_IRW_RNF:
    call BUDGET_NORMAL
    ld a,(DONE)
    ld b,a
    push bc
    call EXIT_SEG
    pop bc
    ld a,NX_ERNF
    ret
_IRW_DATA:
    ; x = ls - DS (24 bits); v = 2 + (x >> log2 SPC); s = x mod SPC
    ld hl,(SECNUM)
    ld de,(ISO_DS)
    or a
    sbc hl,de
    ld a,(SECNUM+2)
    sbc a,0
    ld e,a
    ld a,(ISO_SPC)
    dec a
    and l
    ld (R_S),a
    ld a,(ISO_SPCSH)
    ld b,a
_IRW_SH:
    srl e
    rr h
    rr l
    djnz _IRW_SH
    inc hl
    inc hl
    call ISO_RESOLVE
    jr nc,_IRW_HAVE
    or a
    jp z,_IRW_ZERO               ; not allocated: zeros
    jp _RW_ERR
_IRW_HAVE:
    ; off = (v - vstart)*SPC + s (24 bits); block b = off/4, quarter q
    ld hl,(R_V)
    ld e,(ix+RC_VSTART)
    ld d,(ix+RC_VSTART+1)
    or a
    sbc hl,de
    ld a,(ISO_SPCSH)
    ld b,a
    xor a
_IRW_SL:
    add hl,hl
    rla
    djnz _IRW_SL
    ld e,a                       ; E:HL = (v - vstart)*SPC
    ld a,(R_S)
    add a,l
    ld l,a
    jr nc,_IRW_NC1
    inc h
    jr nz,_IRW_NC1
    inc e
_IRW_NC1:
    ld a,l
    and 3
    ld (S_Q),a
    srl e
    rr h
    rr l
    srl e
    rr h
    rr l                         ; E:HL = b
    ld a,e
    cp (ix+RC_NBLK+2)
    jr c,_IRW_INB
    jp nz,_IRW_ZERO              ; past the data: zeros (file tail /
    ld a,h                       ;  directory terminator block)
    cp (ix+RC_NBLK+1)
    jr c,_IRW_INB
    jp nz,_IRW_ZERO
    ld a,l
    cp (ix+RC_NBLK)
    jp nc,_IRW_ZERO
_IRW_INB:
    ld a,(ix+RC_START)
    add a,l
    ld (S_LBA),a
    ld a,(ix+RC_START+1)
    adc a,h
    ld (S_LBA+1),a
    ld a,(ix+RC_START+2)
    adc a,e
    ld (S_LBA+2),a
    ld a,(ix+RC_START+3)
    adc a,0
    ld (S_LBA+3),a
    bit 0,(ix+RC_FLAGS)
    jr z,_IRW_FILE
    ; ---- block b of a subdirectory: synthesize it ----
    ld (S_K),hl
    ld l,(ix+RC_VSTART)
    ld h,(ix+RC_VSTART+1)
    ld (S_O),hl
    ld l,(ix+RC_PARENT)
    ld h,(ix+RC_PARENT+1)
    ld (S_P),hl
    xor a
    ld (S_ROOT),a
    call ISO_SYNTH
    jp c,_RW_ERR
    jp _IRW_OUT_TRANS
_IRW_FILE:
    ; ---- file data. Fast path: whole blocks straight to the caller when
    ; aligned, >= 4 sectors and the destination is not in page 2; clamped
    ; to the end of the file's data ----
    ld a,(S_Q)
    or a
    jr nz,_IRW_SINGLE
    ld a,(COUNT)
    cp 4
    jr c,_IRW_SINGLE
    ld a,(RWDEST_CUR+1)
    cp 80h
    jr c,_IRW_FAST
    cp 0C0h
    jr c,_IRW_SINGLE
_IRW_FAST:
    ld a,(COUNT)
    srl a
    srl a
    cp 9
    jr c,_IRW_NB1
    ld a,8                       ; 8 blocks = 16 KB per READ(10)
_IRW_NB1:
    ld c,a
    ld a,(ix+RC_NBLK)            ; blocks left in the file = nblk - b
    sub l
    ld l,a
    ld a,(ix+RC_NBLK+1)
    sbc a,h
    ld h,a
    ld a,(ix+RC_NBLK+2)
    sbc a,e
    or h
    jr nz,_IRW_NB2               ; >= 256 left: no clamp
    ld a,l
    cp c
    jr nc,_IRW_NB2
    ld c,a                       ; (>= 1: b < nblk)
_IRW_NB2:
    call CLAMP_NBLK
    jr z,_IRW_SINGLE
    ld a,c
    ld (RW_NBLK),a
    ld hl,(RWDEST_CUR)
    ld (RW_DEST),hl
    call ISO_SETLBA
    call READ_PHYS_RETRY
    jp c,_RW_ERR
    ld a,(RW_NBLK)
    add a,a
    add a,a
    call ADVANCE_SECTORS
    ld a,(RW_NBLK)
    add a,a
    add a,a
    add a,a
    ld b,a
    ld hl,(RWDEST_CUR)
    ld a,h
    add a,b
    ld h,a
    ld (RWDEST_CUR),hl
    jp _IRW_LOOP
_IRW_SINGLE:
    call ISO_FETCH
    jp c,_RW_ERR
    ld a,(S_Q)
    add a,a
    add a,80h                    ; BUF2K + q*512
    ld h,a
    ld l,0
    jp _IRW_OUT

; CMP11 - Z=1 if the 11 bytes at (HL) equal the 11 at (DE). Corrupts AF, B, DE, HL.
CMP11:
    ld b,11
    jp _C5_LOOP

; --------------------------------------------------------------------------
S_PVDID:     db 01h,"CD001"
S_LABEL_DEF: db "ISO9660    "
S_NEXTORSYS: db "NEXTOR  SYS"
S_MSXDOS2SYS: db "MSXDOS2 SYS"
S_DOTNAME:   db ".          "
S_DOTDOTNAME: db "..         "
; characters that may not appear in an 8.3 name ('~' on purpose: a mangled
; name always has one, an as-is name never, so they cannot collide)
S_INVALID83: db 20h,22h,"*+,./:;<=>?[",5Ch,"]|~"
S_INVALID83_LEN: equ $-S_INVALID83
