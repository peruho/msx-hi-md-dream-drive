;
; constants.asm - CH376 ports, commands, status/error codes and timeouts
; MSX Hi-MD Drive project - Fase 0 (HIMDTEST.COM)
;
; This file is original work for the Hi-MD project; the CH376 command/status
; values are taken from the public CH376 datasheet and cross-checked against
; RookieDrive-FDD-ROM (Konamiman) and MSX-USB (S0urceror).
;
; Nestor80 (N80) syntax. No structs (MACRO-80 dialect): descriptor and CBW/CSW
; field offsets are plain EQU constants.
;
; --------------------------------------------------------------------------
; This layer must NOT assume it runs inside a .COM: no BDOS calls here. Screen
; I/O lives only in himdtest.asm. Work RAM is provided by the includer.
; --------------------------------------------------------------------------

; ==========================================================================
; CH376 I/O ports (RookieDrive default: 20h data / 21h command).
; Override by defining CH_DATA_PORT / CH_COMMAND_PORT before including.
; ==========================================================================
    IFNDEF CH_DATA_PORT
CH_DATA_PORT:       equ 20h     ; read/write data and command arguments
    ENDIF
    IFNDEF CH_COMMAND_PORT
CH_COMMAND_PORT:    equ 21h     ; write = command, read = parallel status register
    ENDIF

; ==========================================================================
; CH376 command codes (subset used in Fase 0)
; ==========================================================================
CH_CMD_GET_IC_VER:      equ 01h     ; get chip / firmware version
CH_CMD_SET_SPEED:       equ 04h     ; set USB speed (0=full 12Mbps, 2=low)
CH_CMD_RESET_ALL:       equ 05h     ; full hardware reset
CH_CMD_CHECK_EXIST:     equ 06h     ; presence test, echoes NOT(arg)
CH_CMD_SET_RETRY:       equ 0Bh     ; configure NAK / timeout retry policy
CH_CMD_DELAY_100US:     equ 0Fh     ; hardware delay in units of 0.1 ms
CH_CMD_SET_USB_ADDR:    equ 13h     ; set target USB device address
CH_CMD_SET_USB_MODE:    equ 15h     ; set host mode (5/6/7)
CH_CMD_TEST_CONNECT:    equ 16h     ; connection status
CH_CMD_ABORT_NAK:       equ 17h     ; abort a NAK wait
CH_CMD_GET_STATUS:      equ 22h     ; read status code after INT
CH_CMD_RD_USB_DATA0:    equ 27h     ; read receive buffer
CH_CMD_WR_HOST_DATA:    equ 2Ch     ; write host send buffer
CH_CMD_DISK_CONNECT:    equ 30h     ; auto-pilot: wait for storage device
CH_CMD_DISK_MOUNT:      equ 31h     ; auto-pilot: mount storage device (INQUIRY)
CH_CMD_CLR_STALL:       equ 41h     ; clear endpoint STALL
CH_CMD_DISK_BOC_CMD:    equ 50h     ; auto-pilot: raw Bulk-Only SCSI command
                                    ;   (only command that honours the CBW's
                                    ;    transfer length -> works with any
                                    ;    sector size, incl. the Hi-MD's 2048 B)
CH_CMD_DISK_READ:       equ 54h     ; auto-pilot: read PHYSICAL sectors. NOT used
                                    ;   here: hardcodes 512 B/sector, returns
                                    ;   ERR_LARGE_SECTOR (84h) on a 2048 B disk.
                                    ;   (kept for documentation)
CH_CMD_DISK_RD_GO:      equ 55h     ; auto-pilot: continue a disk read block
CH_CMD_DISK_WRITE:      equ 56h     ; auto-pilot: write PHYSICAL sectors (512 B/sec)
CH_CMD_DISK_WR_GO:      equ 57h     ; auto-pilot: continue a disk write block
CH_CMD_ISSUE_TKN_X:     equ 4Eh     ; issue IN/OUT/SETUP token

; USB packet IDs (used with CH_CMD_ISSUE_TKN_X)
CH_PID_SETUP:           equ 0Dh
CH_PID_IN:              equ 09h
CH_PID_OUT:             equ 01h

; USB host modes for CH_CMD_SET_USB_MODE
CH_MODE_NOSOF:          equ 5       ; host, no SOF (after disconnect / idle)
CH_MODE_HOST:           equ 6       ; host, generate SOF (normal operation)
CH_MODE_HOST_RESET:     equ 7       ; host, SOF + bus reset

; USB speeds for CH_CMD_SET_SPEED
CH_SPEED_FULL:          equ 0       ; 12 Mbps (only speed the CH376 truly supports)
CH_SPEED_LOW:           equ 2       ; 1.5 Mbps

; SET_RETRY fixed magic first byte, required by the CH376
CH_SET_RETRY_MAGIC:     equ 25h
; SET_RETRY second byte: bits7-6 NAK policy (10=retry indefinitely,
; 11=retry up to ~3 s), bits5-0 timeout retries.
CH_SET_RETRY_LIMITED:   equ 0FFh    ; 11_111111: NAK retry capped at ~3 s (RookieDrive default)
CH_SET_RETRY_FOREVER:   equ 0BFh    ; 10_111111: retry NAKs indefinitely

; ==========================================================================
; CH376 status / interrupt result codes (from CH_CMD_GET_STATUS)
; ==========================================================================
CH_ST_INT_SUCCESS:      equ 14h     ; USB operation OK
CH_ST_INT_CONNECT:      equ 15h     ; device connected
CH_ST_INT_DISCONNECT:   equ 16h     ; device disconnected
CH_ST_INT_BUF_OVER:     equ 17h     ; buffer overflow / data error
CH_ST_INT_DISK_READ:    equ 1Dh     ; auto-pilot: disk data ready to read (64B)
CH_ST_INT_DISK_WRITE:   equ 1Eh     ; auto-pilot: chip ready to accept write data
CH_ST_INT_DISK_ERR:     equ 1Fh     ; auto-pilot: disk error
CH_ST_RET_SUCCESS:      equ 51h     ; non-USB command success (SET_USB_MODE etc.)
CH_ST_RET_ABORT:        equ 5Fh     ; aborted
CH_ST_ERR_LARGE_SECTOR: equ 84h     ; DISK_READ/WRITE: sector > 512 B (unsupported)

; ==========================================================================
; Internal USB error codes returned by our routines (compatible with the
; RookieDrive/usb_errors.asm scheme). 0 = OK.
; ==========================================================================
USB_ERR_OK:             equ 0
USB_ERR_NAK:            equ 1
USB_ERR_STALL:          equ 2
USB_ERR_TIMEOUT:        equ 3
USB_ERR_DATA_ERROR:     equ 4
USB_ERR_NO_DEVICE:      equ 5
USB_ERR_UNEXPECTED:     equ 7

; ==========================================================================
; Timeouts
; --------------------------------------------------------------------------
; The reference code (RookieDrive, MSX-USB) waits for the CH376 INT pin with
; NO timeout (RookieDrive relies on a CAPS+ESC panic button; MSX-USB uses a
; 255-iteration counter that is really just a soft limit). Here infinite
; loops are forbidden by design: every wait uses a 16-bit down-counter.
;
; The wait loop body is roughly:
;     call CH_CHECK_INT_IS_ACTIVE  ; ~ IN + AND + RET ~= 30 T-states
;     jr / dec bc / ld a / or c / jr ~= 40 T-states
; => ~70 T-states per iteration. At 3.58 MHz that is ~19.5 us/iteration.
;
;   65535 iterations ~= 1.28 s   (used for normal USB transfers)
;
; For operations that spin the MiniDisc mechanism (TEST UNIT READY, READ) the
; caller retries the whole SCSI command several times with a BDOS/frame pause
; in between, giving an effective multi-second budget (see himdtest.asm).
; ==========================================================================
CH_INT_TIMEOUT:         equ 0FFFFh  ; ~1.28 s per INT wait (see note above)

; SET_USB_MODE waits for CH_ST_RET_SUCCESS. ~65535 * (IN+CP+DEC BC+OR+JR)
; ~= 55 T-states each ~= 15 us => ~1 s worst case. Plenty for a mode switch.
CH_MODE_TIMEOUT:        equ 0FFFFh

; TEST_CONNECT waits for a non-zero status byte; same budget.
CH_CONNECT_TIMEOUT:     equ 0FFFFh

; ==========================================================================
; Auto-pilot (DISK_*) timeouts and retry budgets. The chip's internal firmware
; drives the whole BOT transaction, so a single INT wait may cover a real bus
; round-trip (INQUIRY, a 2 KB READ, etc.). DISK_MOUNT in particular can take
; seconds on a mechanical Hi-MD, so it is retried many times (RookieDrive does
; the same). All still bounded (no infinite waits, by design).
; ==========================================================================
; Number of DISK_MOUNT attempts. Each attempt waits up to CH_INT_TIMEOUT for
; the INT, then CH_DELAYs ~200 ms before the next. 60 * ~1.5 s ~= worst case
; well over a minute of spin-up budget, but success returns immediately.
; Overridable (IFNDEF): the Nextor driver uses a smaller budget so a boot
; without disc does not stall for a minute.
    IFNDEF CHD_MOUNT_RETRIES
CHD_MOUNT_RETRIES:      equ 60
    ENDIF
; Inter-attempt pause for DISK_MOUNT, in units of 0.1 ms (2000 = ~200 ms).
CHD_MOUNT_PAUSE:        equ 2000

; ==========================================================================
; USB standard descriptor field offsets (no structs in MACRO-80 dialect)
; ==========================================================================
; DEVICE descriptor
DD_bLength:             equ 0
DD_bDescriptorType:     equ 1
DD_bcdUSB:              equ 2
DD_bDeviceClass:        equ 4
DD_bDeviceSubClass:     equ 5
DD_bDeviceProtocol:     equ 6
DD_bMaxPacketSize0:     equ 7
DD_idVendor:            equ 8
DD_idProduct:           equ 10
DD_bcdDevice:           equ 12
DD_iManufacturer:       equ 14
DD_iProduct:            equ 15
DD_iSerialNumber:       equ 16
DD_bNumConfigurations:  equ 17
DEVICE_DESCRIPTOR_LEN:  equ 18

; CONFIGURATION descriptor
CD_bLength:             equ 0
CD_bDescriptorType:     equ 1
CD_wTotalLength:        equ 2
CD_bNumInterfaces:      equ 4
CD_bConfigurationValue: equ 5
CD_iConfiguration:      equ 6
CD_bmAttributes:        equ 7
CD_bMaxPower:           equ 8
CONFIG_DESCRIPTOR_LEN:  equ 9

; INTERFACE descriptor
ID_bLength:             equ 0
ID_bDescriptorType:     equ 1
ID_bInterfaceNumber:    equ 2
ID_bAlternateSetting:   equ 3
ID_bNumEndpoints:       equ 4
ID_bInterfaceClass:     equ 5
ID_bInterfaceSubClass:  equ 6
ID_bInterfaceProtocol:  equ 7
ID_iInterface:          equ 8

; ENDPOINT descriptor
ED_bLength:             equ 0
ED_bDescriptorType:     equ 1
ED_bEndpointAddress:    equ 2
ED_bmAttributes:        equ 3
ED_wMaxPacketSize:      equ 4
ED_bInterval:           equ 6

; Descriptor type codes
DESC_TYPE_DEVICE:       equ 1
DESC_TYPE_CONFIG:       equ 2
DESC_TYPE_INTERFACE:    equ 4
DESC_TYPE_ENDPOINT:     equ 5

; Mass Storage Bulk-Only Transport identifiers
USB_CLASS_MASS_STORAGE: equ 08h
USB_SUBCLASS_SCSI:      equ 06h     ; SCSI transparent command set
USB_PROTO_BULK_ONLY:    equ 50h     ; Bulk-Only Transport

; ==========================================================================
; SCSI Bulk-Only Transport: CBW / CSW field offsets
; ==========================================================================
; Command Block Wrapper (31 bytes)
CBW_dSignature:         equ 0       ; 55h 53h 42h 43h ("USBC")
CBW_dTag:               equ 4
CBW_dDataTransferLength: equ 8      ; 4 bytes LE
CBW_bmFlags:            equ 12      ; bit7=1 IN(read), 0 OUT(write)
CBW_bLUN:               equ 13
CBW_bCBLength:          equ 14      ; length of the CDB that follows
CBW_CDB:                equ 15      ; 16-byte CDB area
CBW_SIZE:               equ 31

; Command Status Wrapper (13 bytes)
CSW_dSignature:         equ 0       ; 55h 53h 42h 53h ("USBS")
CSW_dTag:               equ 4
CSW_dDataResidue:       equ 8
CSW_bStatus:            equ 12      ; 0=OK, 1=failed, 2=phase error
CSW_SIZE:               equ 13

CBW_FLAG_IN:            equ 80h

; ==========================================================================
; SCSI operation codes
; ==========================================================================
SCSI_OP_TEST_UNIT_READY: equ 00h
SCSI_OP_REQUEST_SENSE:  equ 03h
SCSI_OP_INQUIRY:        equ 12h
SCSI_OP_READ_CAPACITY:  equ 25h
SCSI_OP_READ10:         equ 28h
SCSI_OP_WRITE10:        equ 2Ah
SCSI_OP_START_STOP:     equ 1Bh
SCSI_OP_SYNC_CACHE:     equ 35h     ; SYNCHRONIZE CACHE(10): flush before eject
