; ============================================================================
;  Shared folder: paths, STAT, OPEN/READ/WRITE/CLOSE, READDIR, MKDIR,
;  RENAME, REMOVE, TRUNCATE, SYNC, the handles
; ============================================================================
; @share
; The folder from tests/run.py holds hello.txt ("Hello, share!\n", 14
; bytes) and sub/data.bin (300 bytes, byte i is i & 0xFF).

	.include "../common/harness.asm"

BUF             = 0x0400            ; 512 bytes; reached as offset(r0)
DIRENT          = 0x0800            ; a directory entry, SH_DIRENT_MAX bytes

test_main:
	li r10, SHARE

	; ---- a folder is shared, read-write
	li r28, 1
	lw r4, SHARE_STATUS(r10)
	li r3, SHARE_PRESENT
	bne r4, r3, fail
	li r28, 2
	lw r4, SHARE_HANDLES(r10)
	li r3, 16
	bne r4, r3, fail

	; ---- STAT of a file
	li r28, 3
	la r1, p_hello
	li r2, BUF
	li r3, SH_STAT_SIZE
	call stat
	bnez r1, fail
	li r28, 4
	lw r4, SHARE_RESULT(r10)
	li r3, SH_STAT_SIZE
	bne r4, r3, fail
	lw r4, BUF(r0)
	li r3, SH_FILE
	bne r4, r3, fail
	li r28, 5
	lw r4, BUF + 8(r0)
	li r3, 14
	bne r4, r3, fail
	lw r4, BUF + 12(r0)
	bnez r4, fail
	li r28, 6                   ; modified some time after 1970
	lw r4, BUF + 0x10(r0)
	beqz r4, fail

	; ---- STAT of directories: the folder itself and sub
	li r28, 7
	la r1, p_root
	li r2, BUF
	li r3, SH_STAT_SIZE
	call stat
	bnez r1, fail
	lw r4, BUF(r0)
	li r3, SH_DIRECTORY
	bne r4, r3, fail
	li r28, 8
	la r1, p_sub_slashes        ; "/sub//", the same as "sub"
	li r2, BUF
	li r3, SH_STAT_SIZE
	call stat
	bnez r1, fail
	lw r4, BUF(r0)
	li r3, SH_DIRECTORY
	bne r4, r3, fail
	lw r4, BUF + 8(r0)          ; no size
	bnez r4, fail

	; ---- STAT errors
	li r28, 10                  ; the record doesn't fit
	la r1, p_hello
	li r2, BUF
	li r3, SH_STAT_SIZE - 1
	call stat
	li r3, SH_E_SIZE
	bne r1, r3, fail
	li r28, 11
	la r1, p_missing
	li r2, BUF
	li r3, SH_STAT_SIZE
	call stat
	li r3, SH_E_NOT_FOUND
	bne r1, r3, fail
	li r28, 12                  ; ".." can't leave the folder
	la r1, p_dotdot
	li r2, BUF
	li r3, SH_STAT_SIZE
	call stat
	li r3, SH_E_PATH
	bne r1, r3, fail
	li r28, 13                  ; nor can "." be used
	la r1, p_dot
	li r2, BUF
	li r3, SH_STAT_SIZE
	call stat
	li r3, SH_E_PATH
	bne r1, r3, fail
	li r28, 14                  ; a backslash
	la r1, p_backslash
	li r2, BUF
	li r3, SH_STAT_SIZE
	call stat
	li r3, SH_E_PATH
	bne r1, r3, fail
	li r28, 15                  ; the record to ROM
	la r1, p_hello
	li r2, ROM_BASE
	li r3, SH_STAT_SIZE
	call stat
	li r3, SH_E_ADDRESS
	bne r1, r3, fail
	li r28, 16                  ; a path in the I/O region
	li r1, PIC
	li r2, BUF
	li r3, SH_STAT_SIZE
	call stat
	li r3, SH_E_ADDRESS
	bne r1, r3, fail

	; ---- OPEN a file to read: the lowest handle
	li r28, 20
	la r1, p_hello
	li r2, 0
	call open
	bnez r1, fail
	lw r4, SHARE_HANDLE(r10)
	bnez r4, fail
	li r28, 21                  ; READ more than there is
	li r1, 0
	li r2, BUF
	li r3, 100
	call read
	bnez r1, fail
	lw r4, SHARE_RESULT(r10)
	li r3, 14
	bne r4, r3, fail
	li r28, 22                  ; the registers move on by 14
	lw r4, SHARE_COUNT(r10)
	li r3, 86
	bne r4, r3, fail
	lw r4, SHARE_ADDRESS(r10)
	li r3, BUF + 14
	bne r4, r3, fail
	lw r4, SHARE_POS_LO(r10)
	li r3, 14
	bne r4, r3, fail
	li r28, 23
	lw r4, BUF(r0)
	li r3, 0x6C6C6548           ; "Hell"
	bne r4, r3, fail
	li r28, 24                  ; at the end: nothing, without an error
	li r1, SH_READ
	call command
	bnez r1, fail
	lw r4, SHARE_RESULT(r10)
	bnez r4, fail
	li r28, 25                  ; from the middle, to an odd address
	li r1, 7
	li r2, BUF + 0x101
	li r3, 5
	call read
	bnez r1, fail
	lbu r4, BUF + 0x101(r0)
	li r3, 's'
	bne r4, r3, fail
	lbu r4, BUF + 0x105(r0)
	li r3, 'e'
	bne r4, r3, fail
	li r28, 26                  ; READ to ROM stops at once
	li r1, 0
	li r2, ROM_BASE
	li r3, 4
	call read
	li r3, SH_E_ADDRESS
	bne r1, r3, fail
	lw r4, SHARE_RESULT(r10)
	bnez r4, fail
	li r28, 27                  ; not opened to write
	li r1, SH_WRITE
	call command
	li r3, SH_E_READONLY
	bne r1, r3, fail
	li r28, 28                  ; a file, not a directory
	li r1, DIRENT
	sw r1, SHARE_ADDRESS(r10)
	li r1, SH_DIRENT_MAX
	sw r1, SHARE_COUNT(r10)
	li r1, SH_READDIR
	call command
	li r3, SH_E_HANDLE
	bne r1, r3, fail
	li r28, 29
	li r1, SH_CLOSE
	call command
	bnez r1, fail
	li r28, 30                  ; closed now
	li r1, SH_CLOSE
	call command
	li r3, SH_E_HANDLE
	bne r1, r3, fail
	li r1, SH_READ
	call command
	li r3, SH_E_HANDLE
	bne r1, r3, fail
	li r28, 31                  ; no such handle
	li r1, 16
	sw r1, SHARE_HANDLE(r10)
	li r1, SH_CLOSE
	call command
	li r3, SH_E_HANDLE
	bne r1, r3, fail

	; ---- OPEN errors
	li r28, 35                  ; a directory as a file
	la r1, p_sub
	li r2, 0
	call open
	li r3, SH_E_TYPE
	bne r1, r3, fail
	li r28, 36                  ; a file as a directory
	la r1, p_hello
	li r2, SH_F_DIRECTORY
	call open
	li r3, SH_E_TYPE
	bne r1, r3, fail
	li r28, 37                  ; CREATE without WRITE
	la r1, p_new
	li r2, SH_F_CREATE
	call open
	li r3, SH_E_COMMAND
	bne r1, r3, fail
	li r28, 38                  ; EXCLUSIVE without CREATE
	la r1, p_new
	li r2, SH_F_WRITE | SH_F_EXCLUSIVE
	call open
	li r3, SH_E_COMMAND
	bne r1, r3, fail
	li r28, 39                  ; an unknown flag
	la r1, p_hello
	li r2, 1 << 5
	call open
	li r3, SH_E_COMMAND
	bne r1, r3, fail
	li r28, 40                  ; not there, and not to be made
	la r1, p_new
	li r2, SH_F_WRITE
	call open
	li r3, SH_E_NOT_FOUND
	bne r1, r3, fail
	li r28, 41                  ; its directory isn't there either
	la r1, p_missing_dir_file
	li r2, SH_F_WRITE | SH_F_CREATE
	call open
	li r3, SH_E_NOT_FOUND
	bne r1, r3, fail

	; ---- make a file, write it from ROM and RAM
	li r28, 45
	la r1, p_new
	li r2, SH_F_WRITE | SH_F_CREATE | SH_F_EXCLUSIVE
	call open
	bnez r1, fail
	li r28, 46
	li r1, 0
	la r2, text                 ; 13 bytes in ROM
	li r3, 13
	call write
	bnez r1, fail
	lw r4, SHARE_RESULT(r10)
	li r3, 13
	bne r4, r3, fail
	li r28, 47                  ; past the end: a gap of zeros
	li r1, 0x44434241           ; "ABCD"
	sw r1, BUF(r0)
	li r1, 20
	li r2, BUF
	li r3, 4
	call write
	bnez r1, fail
	li r28, 48
	li r1, SH_SYNC
	call command
	bnez r1, fail
	li r28, 49                  ; read back across the gap
	li r1, 12
	li r2, BUF + 0x40
	li r3, 100
	call read
	bnez r1, fail
	lw r4, SHARE_RESULT(r10)
	li r3, 12
	bne r4, r3, fail
	lbu r4, BUF + 0x40(r0)      ; the last byte from ROM
	li r3, '!'
	bne r4, r3, fail
	lw r4, BUF + 0x48(r0)       ; bytes 20-23
	li r3, 0x44434241
	bne r4, r3, fail
	lw r4, BUF + 0x44(r0)       ; bytes 16-19, the gap
	bnez r4, fail
	li r28, 50                  ; TRUNCATE to 10 bytes
	sw r0, SHARE_POS_HI(r10)
	li r1, 10
	sw r1, SHARE_POS_LO(r10)
	li r1, SH_TRUNCATE
	call command
	bnez r1, fail
	li r1, SH_CLOSE
	call command
	bnez r1, fail
	li r28, 51
	la r1, p_new
	li r2, BUF
	li r3, SH_STAT_SIZE
	call stat
	bnez r1, fail
	lw r4, BUF + 8(r0)
	li r3, 10
	bne r4, r3, fail
	li r28, 52                  ; EXCLUSIVE: it is there now
	la r1, p_new
	li r2, SH_F_WRITE | SH_F_CREATE | SH_F_EXCLUSIVE
	call open
	li r3, SH_E_EXISTS
	bne r1, r3, fail
	li r28, 53                  ; TRUNCATE on opening
	la r1, p_new
	li r2, SH_F_WRITE | SH_F_TRUNCATE
	call open
	bnez r1, fail
	li r1, SH_CLOSE
	call command
	la r1, p_new
	li r2, BUF
	li r3, SH_STAT_SIZE
	call stat
	lw r4, BUF + 8(r0)
	bnez r4, fail

	; ---- READDIR of the folder: hello.txt, sub and new.txt
	li r28, 60
	la r1, p_root
	li r2, SH_F_DIRECTORY
	call open
	bnez r1, fail
	li r28, 61                  ; COUNT must leave room for any entry
	li r1, DIRENT
	sw r1, SHARE_ADDRESS(r10)
	li r1, SH_DIRENT_MAX - 1
	sw r1, SHARE_COUNT(r10)
	li r1, SH_READDIR
	call command
	li r3, SH_E_SIZE
	bne r1, r3, fail
	li r28, 62
	li r1, SH_DIRENT_MAX
	sw r1, SHARE_COUNT(r10)
	li r11, 0                   ; entries
	li r12, 0                   ; directories among them
.entry:
	li r1, SH_READDIR
	call command
	bnez r1, fail
	lw r4, SHARE_RESULT(r10)
	beqz r4, .entries
	li r3, SH_STAT_SIZE + 2     ; a name of at least one byte and its NUL
	bltu r4, r3, fail
	addi r11, r11, 1
	lw r4, DIRENT(r0)
	li r3, SH_DIRECTORY
	bne r4, r3, .file
	addi r12, r12, 1
	lbu r4, DIRENT + SH_STAT_SIZE(r0)   ; "sub"
	li r3, 's'
	bne r4, r3, fail
	j .entry
.file:
	li r3, SH_FILE
	bne r4, r3, fail
	j .entry
.entries:
	li r28, 63
	mv r4, r11
	li r3, 3
	bne r4, r3, fail
	li r28, 64
	mv r4, r12
	li r3, 1
	bne r4, r3, fail
	li r28, 65                  ; READ on a directory
	li r1, SH_READ
	call command
	li r3, SH_E_HANDLE
	bne r1, r3, fail
	li r1, SH_CLOSE
	call command
	bnez r1, fail

	; ---- MKDIR, RENAME, REMOVE
	li r28, 70
	la r1, p_dir2
	sw r1, SHARE_PATH(r10)
	li r1, SH_MKDIR
	call command
	bnez r1, fail
	li r28, 71
	li r1, SH_MKDIR
	call command
	li r3, SH_E_EXISTS
	bne r1, r3, fail
	li r28, 72                  ; new.txt goes to dir2/moved.txt
	la r1, p_new
	sw r1, SHARE_PATH(r10)
	la r1, p_moved
	sw r1, SHARE_PATH2(r10)
	li r1, SH_RENAME
	call command
	bnez r1, fail
	li r28, 73
	la r1, p_new
	li r2, BUF
	li r3, SH_STAT_SIZE
	call stat
	li r3, SH_E_NOT_FOUND
	bne r1, r3, fail
	la r1, p_moved
	li r2, BUF
	li r3, SH_STAT_SIZE
	call stat
	bnez r1, fail
	li r28, 74                  ; dir2 holds moved.txt
	la r1, p_dir2
	sw r1, SHARE_PATH(r10)
	li r1, SH_REMOVE
	call command
	li r3, SH_E_NOT_EMPTY
	bne r1, r3, fail
	li r28, 75
	la r1, p_moved
	sw r1, SHARE_PATH(r10)
	li r1, SH_REMOVE
	call command
	bnez r1, fail
	li r28, 76
	la r1, p_dir2
	sw r1, SHARE_PATH(r10)
	li r1, SH_REMOVE
	call command
	bnez r1, fail
	li r28, 77
	li r1, SH_REMOVE
	call command
	li r3, SH_E_NOT_FOUND
	bne r1, r3, fail
	li r28, 78                  ; not the folder itself
	la r1, p_root
	sw r1, SHARE_PATH(r10)
	li r1, SH_REMOVE
	call command
	li r3, SH_E_PATH
	bne r1, r3, fail
	li r28, 79                  ; MKDIR where a file is in the way
	la r1, p_hello
	sw r1, SHARE_PATH(r10)
	li r1, SH_MKDIR
	call command
	li r3, SH_E_EXISTS
	bne r1, r3, fail

	; ---- all 16 handles, then none is left
	li r28, 80
	li r11, 0
.open:
	la r1, p_data
	li r2, 0
	call open
	bnez r1, fail
	lw r4, SHARE_HANDLE(r10)
	bne r4, r11, fail
	addi r11, r11, 1
	li r3, 16
	bltu r11, r3, .open
	li r28, 81
	la r1, p_data
	li r2, 0
	call open
	li r3, SH_E_NO_HANDLE
	bne r1, r3, fail
	li r28, 82                  ; handle 15 reads sub/data.bin at 256
	li r1, 15
	sw r1, SHARE_HANDLE(r10)
	li r1, 256
	li r2, BUF
	li r3, 64
	call read
	bnez r1, fail
	lw r4, SHARE_RESULT(r10)
	li r3, 44
	bne r4, r3, fail
	lw r4, BUF(r0)
	li r3, 0x03020100
	bne r4, r3, fail
	li r28, 83                  ; close them all
	li r11, 0
.close:
	sw r11, SHARE_HANDLE(r10)
	li r1, SH_CLOSE
	call command
	bnez r1, fail
	addi r11, r11, 1
	li r3, 16
	bltu r11, r3, .close

	; ---- unknown commands
	li r28, 90
	li r1, 0
	call command
	li r3, SH_E_COMMAND
	bne r1, r3, fail
	li r1, 12
	call command
	li r3, SH_E_COMMAND
	bne r1, r3, fail

	j pass

; command(r1 = command) -> r1 = ERROR
command:
	sw r1, SHARE_COMMAND(r10)
	lw r1, SHARE_ERROR(r10)
	ret

; stat(r1 = path, r2 = record address, r3 = COUNT) -> r1 = ERROR
stat:
	sw r1, SHARE_PATH(r10)
	sw r2, SHARE_ADDRESS(r10)
	sw r3, SHARE_COUNT(r10)
	li r1, SH_STAT
	j command

; open(r1 = path, r2 = FLAGS) -> r1 = ERROR, the handle in HANDLE
open:
	sw r1, SHARE_PATH(r10)
	sw r2, SHARE_FLAGS(r10)
	li r1, SH_OPEN
	j command

; read(r1 = position, r2 = address, r3 = count) -> r1 = ERROR
read:
	sw r1, SHARE_POS_LO(r10)
	sw r0, SHARE_POS_HI(r10)
	sw r2, SHARE_ADDRESS(r10)
	sw r3, SHARE_COUNT(r10)
	li r1, SH_READ
	j command

; write(r1 = position, r2 = address, r3 = count) -> r1 = ERROR
write:
	sw r1, SHARE_POS_LO(r10)
	sw r0, SHARE_POS_HI(r10)
	sw r2, SHARE_ADDRESS(r10)
	sw r3, SHARE_COUNT(r10)
	li r1, SH_WRITE
	j command

p_root:         .asciz ""
p_hello:        .asciz "hello.txt"
p_sub:          .asciz "sub"
p_sub_slashes:  .asciz "/sub//"
p_data:         .asciz "sub/data.bin"
p_missing:      .asciz "missing.txt"
p_missing_dir_file: .asciz "nodir/file.txt"
p_dotdot:       .asciz "sub/../../etc"
p_dot:          .asciz "./hello.txt"
p_backslash:    .asciz "sub\\data.bin"
p_new:          .asciz "new.txt"
p_dir2:         .asciz "dir2"
p_moved:        .asciz "dir2/moved.txt"
text:           .ascii "Written here!"
