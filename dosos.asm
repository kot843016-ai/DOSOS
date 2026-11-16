; ============================================================
;
; Stage:        6
; Architecture: x86 (16-bit real mode)
; Assembler:    FASM
; Filesystem:   FAT12
; Executable:   DX16
;
; Description:
;   An independent experimental operating system with
;   a DOS-like command-line interface, filesystem support
;   and custom executable format.
;
; License: GNU GPL v3.0
; Repository: https://github.com/kot843016-ai/DOSOS
;
; ============================================================

format binary

KSECT    = 48                   ; kernel size in sectors (48 * 512 = 24 KB)
KBASE    = 0x8000               ; kernel is loaded at 0000:8000

; Layout of the generated image (only used to build the empty FAT12 disk;
; the kernel itself reads everything from the BPB at run time)
RSV      = 1 + KSECT            ; reserved sectors = boot sector + kernel
FATSEC   = 9
ROOTSEC  = 14
ROOTLBA  = RSV + 2*FATSEC
DATALBA  = ROOTLBA + ROOTSEC
NCLUS    = 2880 - DATALBA

; real-mode memory map (segment 0 unless noted)
FATBUF   = 0x1000               ; whole FAT (up to 9 sectors)
DIRBUF   = 0x3000               ; current directory (up to 14 sectors)
SECBUF   = 0x5000               ; one sector for TYPE
PROGSEG  = 0x2000               ; programs run in segment 2000h (phys 0x20000)
PROGMAX  = 0xFE00               ; max program size (127 sectors)
PROGARG  = 0xFF00               ; command line arguments inside the program segment
PROGSP   = 0xFEFE               ; initial stack of a program

; open files of programs (file API): NHAND records of HSZ bytes
HTAB     = 0x5200
NHAND    = 4
HSZ      = 544
H_MODE   = 0                    ; 0 free, 1 read, 2 write
H_DIR    = 2                    ; first cluster of the directory holding the file
H_SLOT   = 4                    ; index of the directory entry
H_FIRST  = 6                    ; first cluster of the file
H_SIZE   = 8                    ; file size (dword)
H_LEFT   = 12                   ; bytes not yet loaded from the disk (read mode)
H_CLU    = 16                   ; cluster of the next / current sector
H_SEC    = 18                   ; sector number inside that cluster
H_BPOS   = 20                   ; read position inside the buffer
H_BVAL   = 22                   ; valid bytes in the buffer
H_BUF    = 32                   ; 512 byte sector buffer

; error codes returned by the file API (CF = 1, ax = code)
E_NOTFOUND = 1
E_BADNAME  = 2
E_DISK     = 3
E_FULL     = 4
E_NOHANDLE = 5
E_BADHANDLE = 6
E_DIRFULL  = 7
E_DENIED   = 8
E_EOF      = 9
E_BADFN    = 10

; ------------------------------------------------------------
;  Boot sector (real mode, loaded by BIOS at 0000:7C00)
; ------------------------------------------------------------
org 0x7C00
use16

boot:
        jmp     short start
        nop
        db      'DOSOS   '              ; OEM name
        dw      512                     ; bytes per sector
        db      1                       ; sectors per cluster
        dw      RSV                     ; reserved sectors
        db      2                       ; number of FATs
        dw      224                     ; root directory entries
        dw      2880                    ; total sectors
        db      0xF0                    ; media descriptor
        dw      FATSEC                  ; sectors per FAT
        dw      18                      ; sectors per track
        dw      2                       ; heads
        dd      0                       ; hidden sectors
        dd      0                       ; total sectors (32-bit)
        db      0                       ; drive number
        db      0                       ; reserved
        db      0x29                    ; extended boot signature
        dd      0x44534F53              ; volume serial
        db      'DOSOS      '           ; volume label
        db      'FAT12   '              ; file system type

start:
        cli
        xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, 0x7C00
        sti
        mov     [bootdrv], dl

        mov     si, bmsg_load
        call    bprint

        mov     bx, KBASE               ; es:bx = destination buffer
.sector:
        mov     byte [tries], 3
.try:
        mov     ax, [lba]               ; LBA -> CHS (18 sectors/track, 2 heads)
        xor     dx, dx
        mov     si, 18
        div     si
        inc     dx
        mov     cl, dl
        xor     dx, dx
        shr     ax, 1
        adc     dh, 0
        mov     ch, al
        mov     dl, [bootdrv]
        mov     ax, 0x0201
        int     0x13
        jnc     .ok
        dec     byte [tries]
        jz      .fail
        push    bx
        xor     ax, ax
        mov     dl, [bootdrv]
        int     0x13
        pop     bx
        jmp     .try
.ok:
        add     bx, 512
        inc     word [lba]
        dec     word [cnt]
        jnz     .sector

        mov     dl, [bootdrv]
        jmp     0x0000:KBASE

.fail:
        mov     si, bmsg_err
        call    bprint
        jmp     $

bprint:
        lodsb
        test    al, al
        jz      .done
        mov     ah, 0x0E
        mov     bx, 7
        int     0x10
        jmp     bprint
.done:
        ret

bmsg_load db 'Loading DOSOS...', 13, 10, 0
bmsg_err  db 'Disk read error!', 13, 10, 0
bootdrv   db 0
tries     db 0
lba       dw 1                          ; kernel starts at LBA 1
cnt       dw KSECT

times 510-($-$$) db 0
dw 0xAA55

; ------------------------------------------------------------
;  Kernel (16-bit, loaded at 0000:8000; ds = es = ss = 0 inside the kernel)
; ------------------------------------------------------------
org KBASE
use16

kstart:
        cli
        xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, 0x7C00
        sti
        cld
        mov     [drive], dl

        ; --- geometry from the BPB of the boot sector (still at 0000:7C00) ---
        cmp     word [0x7C0B], 512
        jne     bad_fs
        mov     al, [0x7C0D]
        xor     ah, ah
        mov     [spc], ax
        mov     ax, [0x7C18]
        mov     [spt], ax
        mov     ax, [0x7C1A]
        mov     [heads], ax
        mov     ax, [0x7C0E]
        mov     [fat_lba], ax
        mov     ax, [0x7C16]
        mov     [spf], ax
        cmp     ax, 9                   ; the FAT buffer holds 9 sectors
        ja      bad_fs
        mov     ax, [0x7C11]
        mov     [root_ents], ax
        mov     al, [0x7C10]            ; number of FATs
        xor     ah, ah
        mov     [nfat], ax
        mul     word [spf]
        add     ax, [fat_lba]
        mov     [root_lba], ax
        mov     ax, [root_ents]
        shl     ax, 5
        add     ax, 511
        shr     ax, 9
        mov     [root_secs], ax
        cmp     ax, 14                  ; the directory buffer holds 14 sectors
        ja      bad_fs
        add     ax, [root_lba]
        mov     [data_lba], ax
        mov     ax, [0x7C13]            ; total sectors (16-bit field only)
        test    ax, ax
        jz      bad_fs
        cmp     ax, [data_lba]
        jbe     bad_fs
        sub     ax, [data_lba]
        cmp     word [spc], 0
        je      bad_fs
        cmp     word [spt], 0
        je      bad_fs
        cmp     word [heads], 0
        je      bad_fs
        xor     dx, dx
        div     word [spc]
        mov     [ncl], ax
        cmp     ax, 4085                ; 4085 clusters or more = FAT16, not supported
        jae     bad_fs

        call    install_vectors
        call    cls
        mov     si, msg_banner
        call    puts
        call    unreal_enter
        call    mem_detect
        call    mem_summary
        call    fat_init
        jmp     shell

bad_fs:
        mov     si, msg_badfs
        call    puts
        cli
.h:
        hlt
        jmp     .h

; ------------------------------------------------------------
;  Unreal mode: GS gets a 4 GB limit and keeps it in real mode
; ------------------------------------------------------------
unreal_enter:
        push    eax
        pushf
        cli
        push    ds
        xor     ax, ax
        mov     ds, ax
        lgdt    [ugdtr]
        mov     eax, cr0
        or      al, 1
        mov     cr0, eax
        jmp     short $ + 2             ; flush the prefetch queue
        mov     ax, 0x08
        mov     gs, ax                  ; load the 4 GB data descriptor
        mov     eax, cr0
        and     al, 0xFE
        mov     cr0, eax
        pop     ds
        popf
        pop     eax
        ret

align 8
ugdt:
        dq 0x0000000000000000           ; null
        dq 0x00CF92000000FFFF           ; 0x08: data, base 0, limit 4 GB
ugdtr:
        dw 2*8 - 1
        dd ugdt

; ------------------------------------------------------------
;  Interrupt vectors: INT 0x60 (programs), INT 0 and 6 (faults)
; ------------------------------------------------------------
install_vectors:
        cli
        mov     word [0x60*4], int60
        mov     word [0x60*4 + 2], 0
        mov     word [0*4], fault0
        mov     word [0*4 + 2], 0
        mov     word [6*4], fault6
        mov     word [6*4 + 2], 0
        sti
        ret

fault0:
        mov     byte [cs:fault_no], 0
        jmp     fault_common
fault6:
        mov     byte [cs:fault_no], 6
fault_common:
        cli
        xor     ax, ax
        mov     ds, ax
        mov     es, ax
        cld
        cmp     byte [prog_running], 0
        je      .ks
        mov     ss, [kss]               ; leave the program's (possibly broken) stack
        mov     sp, [ksp]
.ks:
        sti
        mov     si, msg_fault
        call    puts
        movzx   eax, byte [fault_no]
        call    print_num
        mov     al, 10
        call    putc
        cmp     byte [prog_running], 0
        jne     prog_return             ; a program crashed: back to the shell
.h:
        cli
        hlt
        jmp     .h

; INT 0x60 - system calls for programs (ah = function):
;   00 exit
;   01 print character in dl
;   02 print asciiz string at ds:dx
;   03 wait for a key -> al = ASCII, ah = scan code
;   04 print unsigned number in edx
;   10 copy extended -> conventional: esi = linear source, es:di = destination, ecx = count
;   11 copy conventional -> extended: ds:si = source, edi = linear destination, ecx = count
;   file API, see file_api: 20 open, 21 create, 22 read, 23 write, 24 close,
;   25 delete, 28 directory entry, 2A get current dir, 2B change dir
int60:
        sti
        cmp     ah, 0
        je      prog_return
        cmp     ah, 1
        je      .putc
        cmp     ah, 2
        je      .puts
        cmp     ah, 3
        je      .getkey
        cmp     ah, 4
        je      .num
        cmp     ah, 0x10
        je      .xread
        cmp     ah, 0x11
        je      .xwrite
        cmp     ah, 0x20
        jb      .unk
        cmp     ah, 0x2F
        ja      .unk
        jmp     file_api
.unk:
        iret                            ; unknown function: ignored
.putc:
        push    ax
        mov     al, dl
        call    putc
        pop     ax
        iret
.puts:
        push    ax
        push    si
        mov     si, dx
.pl:
        lodsb                           ; from the caller's ds
        test    al, al
        jz      .pd
        call    putc
        jmp     .pl
.pd:
        pop     si
        pop     ax
        iret
.getkey:
        xor     ah, ah
        int     0x16
        iret
.num:
        push    eax
        mov     eax, edx
        call    print_num
        pop     eax
        iret
.xread:
        call    unreal_enter
.xr:
        test    ecx, ecx
        jz      .xd
        mov     al, [gs:esi]
        stosb                           ; es:di
        inc     esi
        dec     ecx
        jmp     .xr
.xd:
        iret
.xwrite:
        call    unreal_enter
.xw:
        test    ecx, ecx
        jz      .xe
        lodsb                           ; ds:si
        mov     [gs:edi], al
        inc     edi
        dec     ecx
        jmp     .xw
.xe:
        iret

; ------------------------------------------------------------
;  Console through the BIOS
; ------------------------------------------------------------
putc:                                   ; al = character (10 = new line, 8 = backspace)
        push    ax
        push    bx
        push    bp
        cmp     al, 10
        jne     .p
        mov     ax, 0x0E0D              ; CR before LF
        mov     bx, 7
        int     0x10
        mov     al, 10
.p:
        mov     ah, 0x0E
        mov     bx, 7
        int     0x10
        pop     bp
        pop     bx
        pop     ax
        ret

puts:                                   ; ds:si -> zero-terminated string
        push    ax
        push    si
.l:
        lodsb
        test    al, al
        jz      .d
        call    putc
        jmp     .l
.d:
        pop     si
        pop     ax
        ret

cls:
        push    ax
        mov     ax, 0x0003              ; set text mode = clear screen
        int     0x10
        pop     ax
        ret

getkey:                                 ; al = ASCII code, ah = scan code
        xor     ah, ah
        int     0x16
        ret

print_num:                              ; eax = unsigned number, decimal
        push    eax
        push    ebx
        push    ecx
        push    edx
        mov     ebx, 10
        xor     cx, cx
.d:
        xor     edx, edx
        div     ebx
        push    dx
        inc     cx
        test    eax, eax
        jnz     .d
.p:
        pop     dx
        mov     al, dl
        add     al, '0'
        call    putc
        loop    .p
        pop     edx
        pop     ecx
        pop     ebx
        pop     eax
        ret

print_num_pad:                          ; eax = number, cx = minimal width
        push    eax
        push    ebx
        push    ecx
        push    edx
        push    si
        mov     si, cx
        push    eax
        mov     ebx, 10
        xor     cx, cx
.cnt:
        xor     edx, edx
        div     ebx
        inc     cx
        test    eax, eax
        jnz     .cnt
        pop     eax
        mov     dx, si
        sub     dx, cx
        jle     .num
.pad:
        push    ax
        mov     al, ' '
        call    putc
        pop     ax
        dec     dx
        jnz     .pad
.num:
        call    print_num
        pop     si
        pop     edx
        pop     ecx
        pop     ebx
        pop     eax
        ret

print_hex32:                            ; eax printed as 8 hex digits
        push    eax
        push    cx
        mov     cx, 8
.l:
        rol     eax, 4
        push    ax
        and     al, 0x0F
        cmp     al, 10
        jb      .d
        add     al, 7
.d:
        add     al, '0'
        call    putc
        pop     ax
        loop    .l
        pop     cx
        pop     eax
        ret

; ------------------------------------------------------------
;  Memory map
; ------------------------------------------------------------
mem_detect:
        mov     word [e820_n], 0
        mov     dword [ext_kb_fb], 0
        xor     ebx, ebx
        mov     di, e820buf
.l:
        mov     eax, 0xE820
        mov     edx, 0x534D4150         ; 'SMAP'
        mov     ecx, 24
        int     0x15
        jc      .done
        cmp     eax, 0x534D4150
        jne     .done
        inc     word [e820_n]
        add     di, 24
        cmp     word [e820_n], 32
        jae     .done
        test    ebx, ebx
        jnz     .l
.done:
        cmp     word [e820_n], 0
        jne     .ret
        mov     ah, 0x88                ; fallback: KB above 1 MB (max 64 MB)
        int     0x15
        jc      .ret
        movzx   eax, ax
        mov     [ext_kb_fb], eax
.ret:
        ret

mem_summary:                            ; ext_kb = usable KB above 1 MB
        mov     dword [ext_kb], 0
        mov     cx, [e820_n]
        test    cx, cx
        jz      .fb
        mov     bx, e820buf
.l:
        cmp     dword [bx + 16], 1      ; type 1 = usable RAM
        jne     .nx
        cmp     dword [bx + 4], 0       ; base must be below 4 GB
        jne     .nx
        cmp     dword [bx], 0x100000
        jb      .nx
        mov     eax, [bx + 8]
        shr     eax, 10
        mov     edx, [bx + 12]
        shl     edx, 22
        or      eax, edx
        add     [ext_kb], eax
.nx:
        add     bx, 24
        loop    .l
        ret
.fb:
        mov     eax, [ext_kb_fb]
        mov     [ext_kb], eax
        ret

; ------------------------------------------------------------
;  Disk (BIOS INT 13h, CHS from the BPB)
; ------------------------------------------------------------

; ax = LBA, es:bx = destination (512 bytes). CF = 1 on error. Registers preserved.
read_sector:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        mov     byte [rd_try], 3
        mov     si, ax
.retry:
        mov     ax, si
        xor     dx, dx
        div     word [spt]              ; ax = track, dx = sector - 1
        inc     dx
        mov     cl, dl
        xor     dx, dx
        div     word [heads]            ; ax = cylinder, dx = head
        mov     ch, al
        mov     dh, dl
        mov     dl, [drive]
        mov     ax, 0x0201
        int     0x13
        jnc     .ok
        dec     byte [rd_try]
        jz      .fail
        push    bx
        xor     ax, ax                  ; reset the controller and retry
        mov     dl, [drive]
        int     0x13
        pop     bx
        jmp     .retry
.ok:
        clc
        jmp     .out
.fail:
        stc
.out:
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

fat_init:                               ; loads the whole FAT into FATBUF
        mov     ax, [fat_lba]
        mov     cx, [spf]
        mov     bx, FATBUF
.l:
        call    read_sector
        jc      .err
        inc     ax
        add     bx, 512
        loop    .l
        mov     byte [fat_dirty], 0
        ret
.err:
        mov     si, msg_ioerr
        call    puts
        ret

fat_next:                               ; ax = cluster -> ax = next (>= 0xFF8: end, 0: free)
        push    bx
        push    dx
        mov     bx, ax
        shr     bx, 1
        add     bx, ax                  ; bx = cluster * 3 / 2
        mov     dx, [FATBUF + bx]
        test    al, 1
        jz      .even
        shr     dx, 4
        jmp     .got
.even:
        and     dx, 0x0FFF
.got:
        mov     ax, dx
        pop     dx
        pop     bx
        ret

clu2lba:                                ; ax = cluster -> ax = first sector
        push    dx
        sub     ax, 2
        mul     word [spc]
        add     ax, [data_lba]
        pop     dx
        ret

; if the floppy was swapped, forget the old FAT and directory (INT 13h / AH=16h)
media_check:
        push    ax
        push    dx
        mov     ah, 0x16
        mov     dl, [drive]
        int     0x13
        jnc     .ok
        cmp     ah, 6                   ; 6 = change line active
        jne     .ok
        mov     word [cur_dir], 0
        mov     word [saved_dir], 0
        mov     byte [curpath], 0
        call    fat_init
        mov     si, msg_changed
        call    puts
.ok:
        pop     dx
        pop     ax
        ret

; loads the current directory into DIRBUF and sets [dir_ents]. CF = 1 on error.
load_dir:
        call    media_check
        mov     bx, DIRBUF
        cmp     word [cur_dir], 0
        jne     .sub
        mov     ax, [root_lba]
        mov     cx, [root_secs]
.r:
        call    read_sector
        jc      .err
        inc     ax
        add     bx, 512
        loop    .r
        mov     ax, [root_ents]
        mov     [dir_ents], ax
        clc
        ret
.sub:
        mov     dx, [cur_dir]           ; current cluster
        xor     si, si                  ; sectors loaded
.cl:
        mov     ax, dx
        call    clu2lba
        mov     cx, [spc]
.sc:
        cmp     si, 14
        jae     .full
        call    read_sector
        jc      .err
        inc     ax
        add     bx, 512
        inc     si
        loop    .sc
        mov     ax, dx
        call    fat_next
        mov     dx, ax
        cmp     dx, 0xFF8
        jb      .cl
.full:
        mov     ax, si
        shl     ax, 4                   ; 16 entries per sector
        mov     [dir_ents], ax
        clc
        ret
.err:
        mov     si, msg_ioerr
        call    puts
        stc
        ret

; si -> 11-byte name. CF = 0: found, di -> directory entry. CF = 1: not found.
find_entry:
        mov     di, DIRBUF
        mov     cx, [dir_ents]
        test    cx, cx
        jz      .no
.l:
        cmp     byte [di], 0
        je      .no
        cmp     byte [di], 0xE5
        je      .nx
        test    byte [di + 11], 0x08    ; volume label / long name part
        jnz     .nx
        push    si
        push    di
        push    cx
        mov     cx, 11
        repe    cmpsb
        pop     cx
        pop     di
        pop     si
        je      .yes
.nx:
        add     di, 32
        loop    .l
.no:
        stc
        ret
.yes:
        clc
        ret

; si -> user text (zero- or space-terminated); builds fname83 (11 bytes, upper case).
; CF = 1 if the name is invalid.
parse_name:
        pusha
        mov     di, fname83
        mov     cx, 11
        mov     al, ' '
        rep     stosb
        cmp     byte [si], '.'
        jne     .norm
        cmp     byte [si + 1], 0
        je      .dot
        cmp     byte [si + 1], ' '
        je      .dot
        cmp     byte [si + 1], '.'
        jne     .bad
        mov     al, [si + 2]
        test    al, al
        jz      .dotdot
        cmp     al, ' '
        jne     .bad
.dotdot:
        mov     byte [fname83 + 1], '.'
.dot:
        mov     byte [fname83], '.'
        jmp     .ok
.norm:
        mov     di, fname83
        xor     cx, cx                  ; characters in the current part
        xor     bx, bx                  ; 0 = name, 1 = extension
.ch:
        lodsb
        test    al, al
        jz      .ok
        cmp     al, ' '
        je      .ok
        cmp     al, '.'
        jne     .c
        test    bx, bx
        jnz     .bad                    ; second dot
        mov     bx, 1
        xor     cx, cx
        mov     di, fname83 + 8
        jmp     .ch
.c:
        cmp     al, 'a'
        jb      .up
        cmp     al, 'z'
        ja      .up
        sub     al, 32
.up:
        cmp     al, 32                  ; control characters and DEL are invalid
        jb      .bad
        cmp     al, 0x7F
        je      .bad
        push    si
        mov     si, badchars            ; characters not allowed in 8.3 names (also wildcards)
.bc:
        cmp     byte [si], 0
        je      .bcok
        cmp     al, [si]
        je      .bcbad
        inc     si
        jmp     .bc
.bcbad:
        pop     si
        jmp     .bad
.bcok:
        pop     si
        test    bx, bx
        jnz     .e
        cmp     cx, 8
        jae     .bad
        jmp     .store
.e:
        cmp     cx, 3
        jae     .bad
.store:
        stosb
        inc     cx
        jmp     .ch
.ok:
        cmp     byte [fname83], ' '     ; empty name is invalid
        je      .bad
        clc
        popa
        ret
.bad:
        stc
        popa
        ret

; --- sequential file reading ---
; ff_open: opens fname83 in the current directory.
; CF = 1: ax -> error message (0 = already shown)
ff_open:
        call    load_dir
        jc      .rep
        mov     si, fname83
        call    find_entry
        jc      .nofile
        test    byte [di + 11], 0x10
        jnz     .nofile
        mov     ax, [di + 26]           ; first cluster
        mov     [ff_clu], ax
        mov     eax, [di + 28]          ; size
        mov     [ff_left], eax
        mov     word [ff_sec], 0
        clc
        ret
.nofile:
        mov     ax, msg_nofile
        stc
        ret
.rep:
        xor     ax, ax
        stc
        ret

; ff_read: reads the next sector of the open file into es:bx.
; CF = 0 and cx = number of valid bytes (0 = end of file); CF = 1 on a disk error.
ff_read:
        cmp     dword [ff_left], 0
        je      .eof
        mov     ax, [ff_clu]
        cmp     ax, 2
        jb      .eof
        cmp     ax, 0xFF8
        jae     .eof
        call    clu2lba
        add     ax, [ff_sec]
        call    read_sector
        jc      .err
        mov     ecx, [ff_left]
        cmp     ecx, 512
        jbe     .last
        mov     ecx, 512
.last:
        sub     [ff_left], ecx
        inc     word [ff_sec]
        mov     ax, [ff_sec]
        cmp     ax, [spc]
        jb      .done
        mov     word [ff_sec], 0
        mov     ax, [ff_clu]
        call    fat_next
        mov     [ff_clu], ax
.done:
        clc
        ret
.eof:
        xor     cx, cx
        clc
        ret
.err:
        stc
        ret

; ------------------------------------------------------------
;  Shell
; ------------------------------------------------------------
print_prompt:
        mov     si, msg_drive
        call    puts
        mov     si, curpath
        cmp     byte [si], 0
        jne     @f
        mov     si, msg_root
@@:
        call    puts
        mov     si, msg_gt
        call    puts
        ret

shell:
        call    print_prompt
        xor     cx, cx                  ; line length
.key:
        call    getkey
        cmp     al, 13
        je      .enter
        cmp     al, 8
        je      .back
        cmp     al, 32
        jb      .key
        cmp     cx, 70
        jae     .key
        mov     bx, cx
        mov     [linebuf + bx], al
        inc     cx
        call    putc
        jmp     .key
.back:
        test    cx, cx
        jz      .key
        dec     cx
        mov     al, 8
        call    putc
        mov     al, ' '
        call    putc
        mov     al, 8
        call    putc
        jmp     .key
.enter:
        mov     al, 10
        call    putc
.trim:
        test    cx, cx                  ; strip trailing spaces
        jz      .term
        mov     bx, cx
        cmp     byte [linebuf + bx - 1], ' '
        jne     .term
        dec     cx
        jmp     .trim
.term:
        mov     bx, cx
        mov     byte [linebuf + bx], 0
        call    execute
        jmp     shell

; compares the first word of the line (si) with command string (di),
; case-insensitive. ZF = 1 on match, dx -> arguments
cmd_match:
        push    si
        push    di
.l:
        mov     al, [si]
        cmp     al, 'A'
        jb      .nolow
        cmp     al, 'Z'
        ja      .nolow
        add     al, 32
.nolow:
        mov     ah, [di]
        test    ah, ah
        jz      .endcmd
        cmp     al, ah
        jne     .no
        inc     si
        inc     di
        jmp     .l
.endcmd:
        test    al, al
        jz      .yes
        cmp     al, ' '
        jne     .no
.yes:
.sp:
        cmp     byte [si], ' '
        jne     .ok
        inc     si
        jmp     .sp
.ok:
        mov     dx, si
        pop     di
        pop     si
        xor     ax, ax                  ; ZF = 1
        ret
.no:
        pop     di
        pop     si
        or      ax, 1                   ; ZF = 0
        ret

execute:
        cmp     byte [linebuf], 0
        je      .ret
        mov     bx, cmdtab
.next:
        mov     di, [bx]
        test    di, di
        jz      .unknown
        mov     si, linebuf
        call    cmd_match
        je      .run
        add     bx, 4
        jmp     .next
.run:
        mov     si, dx                  ; si -> arguments
        call    word [bx + 2]
.ret:
        ret
.unknown:
        call    split_cmd
        call    try_run
        ret

; copies the first word of the line to cmdword, sets cmdargs to the rest
split_cmd:
        mov     si, linebuf
        mov     di, cmdword
        xor     cx, cx
.w:
        mov     al, [si]
        test    al, al
        jz      .end
        cmp     al, ' '
        je      .end
        cmp     cx, 12
        jae     .skip
        mov     [di], al
        inc     di
        inc     cx
.skip:
        inc     si
        jmp     .w
.end:
        mov     byte [di], 0
.sp:
        cmp     byte [si], ' '
        jne     .done
        inc     si
        jmp     .sp
.done:
        mov     [cmdargs], si
        ret

; ------------------------------------------------------------
;  Running programs: NAME[.BIN], header 'DX16', entry point at offset 4
;  The program is loaded to PROGSEG:0000 and runs with cs = ds = es = ss = PROGSEG,
;  si -> command line arguments, sp = PROGSP. It ends with INT 0x60 / ah = 0 or retf.
; ------------------------------------------------------------
try_run:
        mov     si, cmdword
        call    parse_name
        jc      .bad
        cmp     byte [fname83 + 8], ' '
        jne     .ext
        mov     byte [fname83 + 8], 'B'
        mov     byte [fname83 + 9], 'I'
        mov     byte [fname83 + 10], 'N'
        jmp     .go
.ext:
        cmp     byte [fname83 + 8], 'B'
        jne     .bad
        cmp     byte [fname83 + 9], 'I'
        jne     .bad
        cmp     byte [fname83 + 10], 'N'
        jne     .bad
.go:
        call    ff_open
        jnc     .opened
        cmp     ax, msg_nofile
        je      .bad
        test    ax, ax
        jz      .ret
        mov     si, ax
        call    puts
        ret
.opened:
        cmp     dword [ff_left], 8
        jb      .notexe
        cmp     dword [ff_left], PROGMAX
        ja      .big
        mov     ax, PROGSEG
        mov     es, ax
        xor     bx, bx
.ld:
        call    ff_read
        jc      .ioerr
        test    cx, cx
        jz      .loaded
        add     bx, 512
        jmp     .ld
.loaded:
        mov     ax, PROGSEG
        mov     fs, ax
        xor     ax, ax
        mov     es, ax
        cmp     dword [fs:0], 'DX16'
        jne     .notexe
        ; copy the arguments next to the program
        mov     si, [cmdargs]
        mov     ax, PROGSEG
        mov     es, ax
        mov     di, PROGARG
        mov     cx, 100
.cp:
        lodsb
        stosb
        test    al, al
        jz      .cpd
        loop    .cp
        mov     byte [es:di], 0
.cpd:
        xor     ax, ax
        mov     es, ax
        call    run_program
        ret
.notexe:
        mov     si, msg_notexe
        jmp     .say
.big:
        mov     si, msg_big
        jmp     .say
.ioerr:
        xor     ax, ax
        mov     es, ax
        mov     si, msg_ioerr
        jmp     .say
.bad:
        mov     si, msg_bad
.say:
        call    puts
.ret:
        ret

run_program:
        call    h_reset
        push    ds
        push    es
        pusha
        mov     [ksp], sp
        mov     [kss], ss
        mov     byte [prog_running], 1
        mov     ax, PROGSEG
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, PROGSP
        mov     si, PROGARG
        push    word 0                  ; far return address: kernel segment ...
        push    word prog_return        ; ... and offset (for a plain retf)
        jmp     PROGSEG:4

prog_return:                            ; reached by retf, INT 0x60 exit or a fault
        cli
        xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ss, [kss]
        mov     sp, [ksp]
        sti
        cld
        mov     byte [prog_running], 0
        call    h_close_all             ; files the program forgot to close
        popa
        pop     es
        pop     ds
        ret

; ------------------------------------------------------------
;  Commands (si -> arguments)
; ------------------------------------------------------------
do_help:
        mov     si, msg_help
        call    puts
        ret

do_ver:
        mov     si, msg_ver
        call    puts
        ret

do_cls:
        call    cls
        ret

do_echo:
        call    puts
        mov     al, 10
        call    putc
        ret

do_reboot:
        mov     word [0x472], 0x1234    ; warm boot flag
        jmp     0xFFFF:0x0000

do_halt:
        cli
.h:
        hlt
        jmp     .h

; MEM: conventional memory, extended memory and the BIOS memory map
do_mem:
        mov     si, msg_conv
        call    puts
        int     0x12                    ; KB of conventional memory
        movzx   eax, ax
        call    print_num
        mov     si, msg_kb
        call    puts
        mov     si, msg_ext
        call    puts
        mov     eax, [ext_kb]
        call    print_num
        mov     si, msg_kb
        call    puts
        cmp     word [e820_n], 0
        je      .nomap
        mov     si, msg_map
        call    puts
        mov     bx, e820buf
        mov     cx, [e820_n]
.l:
        push    cx
        mov     eax, [bx + 4]
        call    print_hex32
        mov     eax, [bx]
        call    print_hex32
        mov     al, ' '
        call    putc
        mov     eax, [bx + 12]
        call    print_hex32
        mov     eax, [bx + 8]
        call    print_hex32
        mov     al, ' '
        call    putc
        mov     eax, [bx + 16]
        call    print_num
        mov     al, 10
        call    putc
        pop     cx
        add     bx, 24
        loop    .l
        ret
.nomap:
        mov     si, msg_nomap
        call    puts
        ret

; XTEST: writes and reads memory at 0x00110000 through the 4 GB GS segment
do_xtest:
        cmp     dword [ext_kb], 128
        jb      .none
        xor     ax, ax                  ; deliberately drop GS back to a 64 KB limit ...
        mov     gs, ax
        call    unreal_enter            ; ... unreal_enter must restore the 4 GB limit
        mov     esi, 0x00110000
        mov     dword [gs:esi], 0xA5C3F00D
        mov     dword [gs:esi + 4], 0x0F1E2D3C
        mov     eax, [gs:esi]
        cmp     eax, 0xA5C3F00D
        jne     .fail
        mov     eax, [gs:esi + 4]
        cmp     eax, 0x0F1E2D3C
        jne     .fail
        mov     ax, ds
        mov     bx, es
        or      ax, bx
        mov     bx, ss
        or      ax, bx
        jnz     .segs
        mov     si, msg_xok
        call    puts
        ret
.segs:
        mov     si, msg_xsegs
        call    puts
        ret
.fail:
        mov     si, msg_xfail
        call    puts
        ret
.none:
        mov     si, msg_xnone
        call    puts
        ret

; DIR: lists the current directory
do_dir:
        call    load_dir
        jc      .ret
        mov     dword [dir_files], 0
        mov     dword [dir_bytes], 0
        mov     si, DIRBUF
        mov     dx, [dir_ents]
        test    dx, dx
        jz      .done
.l:
        cmp     byte [si], 0
        je      .done
        cmp     byte [si], 0xE5
        je      .nx
        test    byte [si + 11], 0x08    ; skip volume label / long names
        jnz     .nx
        push    si
        mov     cx, 8
.nm:
        mov     al, [si]
        call    putc
        inc     si
        loop    .nm
        mov     al, ' '
        call    putc
        mov     cx, 3
.ex:
        mov     al, [si]
        call    putc
        inc     si
        loop    .ex
        pop     si
        test    byte [si + 11], 0x10
        jnz     .isdir
        mov     eax, [si + 28]
        add     [dir_bytes], eax
        inc     dword [dir_files]
        mov     cx, 10
        call    print_num_pad
        jmp     .eol
.isdir:
        push    si
        mov     si, msg_dirtag
        call    puts
        pop     si
.eol:
        mov     al, 10
        call    putc
.nx:
        add     si, 32
        dec     dx
        jnz     .l
.done:
        mov     eax, [dir_files]
        mov     cx, 6
        call    print_num_pad
        mov     si, msg_files
        call    puts
        mov     eax, [dir_bytes]
        mov     cx, 9
        call    print_num_pad
        mov     si, msg_bytes
        call    puts
        mov     al, 10
        call    putc

        xor     di, di                  ; count free clusters
        mov     cx, 2
.f:
        mov     ax, cx
        call    fat_next
        test    ax, ax
        jnz     .u
        inc     di
.u:
        inc     cx
        mov     ax, [ncl]
        add     ax, 2
        cmp     cx, ax
        jb      .f
        movzx   eax, di
        movzx   edx, word [spc]
        imul    eax, edx
        shl     eax, 9
        mov     cx, 9
        call    print_num_pad
        mov     si, msg_free
        call    puts
.ret:
        ret

; TYPE file: streams a text file with a pause after each screen
do_type:
        cmp     byte [si], 0
        je      .usage
        call    parse_name
        jc      .badname
        call    ff_open
        jc      .err
        mov     word [lines], 0
.sector:
        mov     bx, SECBUF
        call    ff_read
        jc      .ioerr
        test    cx, cx
        jz      .end
        mov     si, SECBUF
.p:
        lodsb
        cmp     al, 26                  ; Ctrl+Z = end of text
        je      .end
        cmp     al, 13
        je      .nx
        cmp     al, 9
        je      .tab
        cmp     al, 10
        je      .nl
        cmp     al, 32
        jb      .nx
        call    putc
        jmp     .nx
.tab:
        mov     al, ' '
        call    putc
        call    putc
        call    putc
        call    putc
        jmp     .nx
.nl:
        call    putc
        inc     word [lines]
        cmp     word [lines], 23
        jb      .nx
        push    si
        push    cx
        mov     si, msg_more
        call    puts
        call    getkey
        mov     al, 10
        call    putc
        pop     cx
        pop     si
        mov     word [lines], 0
.nx:
        loop    .p
        jmp     .sector
.end:
        mov     al, 10
        call    putc
        ret
.usage:
        mov     si, msg_usage
        jmp     .say
.badname:
        mov     si, msg_badname
        jmp     .say
.ioerr:
        mov     si, msg_ioerr
        jmp     .say
.err:
        mov     si, ax
        test    si, si                  ; 0 = message already shown
        jz      .ret
.say:
        call    puts
.ret:
        ret

; CD [path]: change directory (A\B, \A, .., ...); CD alone prints the path
do_cd:
        cmp     byte [si], 0
        je      .show
        call    cd_path
        jc      .nodir
        ret
.show:
        mov     si, msg_drive
        call    puts
        mov     si, curpath
        cmp     byte [si], 0
        jne     @f
        mov     si, msg_root
@@:
        call    puts
        mov     al, 10
        call    putc
        ret
.nodir:
        mov     si, msg_nodir
        call    puts
        ret

; ------------------------------------------------------------
;  Writing to the disk
; ------------------------------------------------------------

; ax = LBA, es:bx = source (512 bytes). CF = 1 on error. Registers preserved.
write_sector:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        mov     byte [rd_try], 3
        mov     si, ax
.retry:
        mov     ax, si
        xor     dx, dx
        div     word [spt]
        inc     dx
        mov     cl, dl
        xor     dx, dx
        div     word [heads]
        mov     ch, al
        mov     dh, dl
        mov     dl, [drive]
        mov     ax, 0x0301              ; write one sector
        int     0x13
        jnc     .ok
        dec     byte [rd_try]
        jz      .fail
        push    bx
        xor     ax, ax
        mov     dl, [drive]
        int     0x13
        pop     bx
        jmp     .retry
.ok:
        clc
        jmp     .out
.fail:
        stc
.out:
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ax = cluster, dx = new 12-bit value. Changes the FAT copy in memory.
fat_set:
        push    ax
        push    bx
        push    cx
        push    dx
        and     dx, 0x0FFF
        mov     bx, ax
        shr     bx, 1
        add     bx, ax                  ; bx = cluster * 3 / 2
        mov     cx, [FATBUF + bx]
        test    al, 1
        jnz     .odd
        and     cx, 0xF000
        or      cx, dx
        jmp     .put
.odd:
        and     cx, 0x000F
        shl     dx, 4
        or      cx, dx
.put:
        mov     [FATBUF + bx], cx
        mov     byte [fat_dirty], 1
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; writes the FAT (all copies) back to the disk if it was changed. CF = 1 on error.
fat_flush:
        cmp     byte [fat_dirty], 0
        je      .ok
        xor     si, si                  ; FAT copy number
.copy:
        mov     ax, [spf]
        mul     si
        add     ax, [fat_lba]
        mov     cx, [spf]
        mov     bx, FATBUF
.l:
        call    write_sector
        jc      .err
        inc     ax
        add     bx, 512
        loop    .l
        inc     si
        cmp     si, [nfat]
        jb      .copy
        mov     byte [fat_dirty], 0
.ok:
        clc
        ret
.err:
        mov     si, msg_wrerr
        call    puts
        stc
        ret

; allocates a free cluster and marks it as the end of a chain.
; ax = cluster, CF = 1 if the disk is full
alloc_cluster:
        push    bx
        push    cx
        push    dx
        mov     cx, 2
.l:
        mov     ax, cx
        call    fat_next
        test    ax, ax
        jz      .found
        inc     cx
        mov     ax, [ncl]
        add     ax, 2
        cmp     cx, ax
        jb      .l
        pop     dx
        pop     cx
        pop     bx
        stc
        ret
.found:
        mov     ax, cx
        mov     dx, 0xFFF
        call    fat_set
        pop     dx
        pop     cx
        pop     bx
        clc
        ret

; ax = first cluster of a chain: marks all its clusters as free (in memory)
free_chain:
        push    ax
        push    dx
.l:
        cmp     ax, 2
        jb      .done
        cmp     ax, 0xFF8
        jae     .done
        push    ax
        call    fat_next
        mov     dx, ax                  ; next cluster
        pop     ax
        push    dx
        xor     dx, dx
        call    fat_set                 ; this cluster = 0 (free)
        pop     ax
        jmp     .l
.done:
        pop     dx
        pop     ax
        ret

; writes DIRBUF back to the current directory. CF = 1 on error.
store_dir:
        mov     bx, DIRBUF
        cmp     word [cur_dir], 0
        jne     .sub
        mov     ax, [root_lba]
        mov     cx, [root_secs]
.r:
        call    write_sector
        jc      .err
        inc     ax
        add     bx, 512
        loop    .r
        clc
        ret
.sub:
        mov     dx, [cur_dir]
        xor     si, si
.cl:
        mov     ax, dx
        call    clu2lba
        mov     cx, [spc]
.sc:
        cmp     si, 14
        jae     .done
        call    write_sector
        jc      .err
        inc     ax
        add     bx, 512
        inc     si
        loop    .sc
        mov     ax, dx
        call    fat_next
        mov     dx, ax
        cmp     dx, 0xFF8
        jb      .cl
.done:
        clc
        ret
.err:
        mov     si, msg_wrerr
        call    puts
        stc
        ret

; finds a free slot in DIRBUF. CF = 0: di -> slot, CF = 1: directory full
find_free_slot:
        mov     di, DIRBUF
        mov     cx, [dir_ents]
        test    cx, cx
        jz      .no
.l:
        cmp     byte [di], 0
        je      .yes
        cmp     byte [di], 0xE5
        je      .yes
        add     di, 32
        loop    .l
.no:
        stc
        ret
.yes:
        clc
        ret

bcd2bin:                                ; al = BCD -> al = binary
        push    cx
        mov     cl, al
        shr     al, 4
        mov     ch, 10
        mul     ch
        and     cl, 0x0F
        add     al, cl
        pop     cx
        ret

; reads the real-time clock into cur_date / cur_time (FAT format)
get_datetime:
        pusha
        mov     word [cur_date], 0x0021 ; 1980-01-01 if the clock cannot be read
        mov     word [cur_time], 0
        mov     ah, 4                   ; RTC date: ch = century, cl = year, dh = month, dl = day
        int     0x1A
        jc      .time
        cmp     ch, 0x20                ; 20xx only
        jne     .time
        mov     al, cl
        call    bcd2bin
        movzx   bx, al
        add     bx, 20                  ; year - 1980
        shl     bx, 9
        mov     al, dh
        call    bcd2bin
        movzx   ax, al
        shl     ax, 5
        or      bx, ax
        mov     al, dl
        call    bcd2bin
        xor     ah, ah
        or      bx, ax
        mov     [cur_date], bx
.time:
        mov     ah, 2                   ; RTC time: ch = hours, cl = minutes, dh = seconds
        int     0x1A
        jc      .done
        mov     al, ch
        call    bcd2bin
        movzx   bx, al
        shl     bx, 11
        mov     al, cl
        call    bcd2bin
        movzx   ax, al
        shl     ax, 5
        or      bx, ax
        mov     al, dh
        call    bcd2bin
        xor     ah, ah
        shr     ax, 1
        or      bx, ax
        mov     [cur_time], bx
.done:
        popa
        ret

; builds a directory entry: di = slot, si -> 11-byte name, bl = attribute,
; dx = first cluster, eax = size. Uses cur_date / cur_time.
fill_entry:
        mov     [fe_size], eax
        push    cx
        push    di
        mov     cx, 11
        rep     movsb
        pop     di
        pop     cx
        mov     [di + 11], bl
        mov     word [di + 12], 0
        mov     ax, [cur_time]
        mov     [di + 14], ax
        mov     [di + 22], ax
        mov     ax, [cur_date]
        mov     [di + 16], ax
        mov     [di + 18], ax
        mov     [di + 24], ax
        mov     word [di + 20], 0
        mov     [di + 26], dx
        mov     eax, [fe_size]
        mov     [di + 28], eax
        ret

; parses "name1 name2" from si into src83 and dst83. CF = 1 on error.
parse_two:
        call    parse_name
        jc      .bad
        push    si
        mov     si, fname83
        mov     di, src83
        mov     cx, 11
        rep     movsb
        pop     si
.w:
        cmp     byte [si], 0
        je      .bad
        cmp     byte [si], ' '
        je      .sp
        inc     si
        jmp     .w
.sp:
        cmp     byte [si], ' '
        jne     .second
        inc     si
        jmp     .sp
.second:
        cmp     byte [si], 0
        je      .bad
        call    parse_name
        jc      .bad
        mov     si, fname83
        mov     di, dst83
        mov     cx, 11
        rep     movsb
        clc
        ret
.bad:
        stc
        ret

; DEL file
do_del:
        cmp     byte [si], 0
        je      .usage
        call    parse_name
        jc      .badname
        call    load_dir
        jc      .ret
        mov     si, fname83
        call    find_entry
        jc      .nofile
        test    byte [di + 11], 0x10
        jnz     .nofile                 ; folders are removed with RD
        test    byte [di + 11], 0x01
        jnz     .ro
        mov     ax, [di + 26]
        mov     byte [di], 0xE5         ; mark the entry as deleted
        call    free_chain
        call    store_dir
        jc      .ret
        call    fat_flush
        ret
.usage:
        mov     si, msg_u_del
        jmp     .say
.badname:
        mov     si, msg_badname
        jmp     .say
.nofile:
        mov     si, msg_nofile
        jmp     .say
.ro:
        mov     si, msg_ro
.say:
        call    puts
.ret:
        ret

; REN old new
do_ren:
        call    parse_two
        jc      .usage
        cmp     byte [src83], '.'       ; "." and ".." cannot be renamed
        je      .nofile
        cmp     byte [dst83], '.'       ; ... or used as a new name
        je      .badname
        call    load_dir
        jc      .ret
        mov     si, dst83
        call    find_entry
        jnc     .exists
        mov     si, src83
        call    find_entry
        jc      .nofile
        mov     si, dst83
        mov     cx, 11
        rep     movsb                   ; new name into the entry
        call    store_dir
        ret
.usage:
        mov     si, msg_u_ren
        jmp     .say
.badname:
        mov     si, msg_badname
        jmp     .say
.exists:
        mov     si, msg_exists
        jmp     .say
.nofile:
        mov     si, msg_nofile
.say:
        call    puts
.ret:
        ret

; COPY source target - paths allowed; if the target is a directory, the name is kept
do_copy:
        mov     ax, [cur_dir]
        mov     [saved_dir], ax
        mov     di, argbuf              ; copy the arguments and split them at the first space
        mov     cx, 90
.a1:
        lodsb
        stosb
        test    al, al
        jz      .a2
        loop    .a1
        mov     byte [di], 0
.a2:
        mov     si, argbuf
.t1:
        cmp     byte [si], 0
        je      .usage
        cmp     byte [si], ' '
        je      .t1e
        inc     si
        jmp     .t1
.t1e:
        mov     byte [si], 0            ; end of the source path
        inc     si
.t2:
        cmp     byte [si], ' '
        jne     .t2e
        inc     si
        jmp     .t2
.t2e:
        cmp     byte [si], 0
        je      .usage
        mov     [cp_dstp], si           ; start of the target path
        ; ---- the source file
        mov     si, argbuf
        mov     di, pathbuf
        call    copystr
        call    enter_path
        jc      .patherr
        mov     si, fname83
        mov     di, src83
        mov     cx, 11
        rep     movsb
        call    ff_open
        jc      .err
        mov     eax, [ff_left]
        mov     [cp_size], eax
        mov     ax, [saved_dir]
        mov     [cur_dir], ax
        ; ---- the target
        mov     si, [cp_dstp]
        mov     di, pathbuf
        call    copystr
        call    enter_path
        jc      .patherr
        cmp     byte [fname83], '.'
        je      .badname
        call    load_dir
        jc      .ret
        mov     si, fname83
        call    find_entry
        jc      .newname
        test    byte [di + 11], 0x10
        jz      .exists                 ; an existing file is never overwritten
        mov     ax, [di + 26]           ; a directory: copy into it, keep the name
        mov     [cur_dir], ax
        mov     si, src83
        mov     di, fname83
        mov     cx, 11
        rep     movsb
        call    load_dir
        jc      .ret
        mov     si, fname83
        call    find_entry
        jnc     .exists
.newname:
        mov     si, fname83
        mov     di, dst83
        mov     cx, 11
        rep     movsb
        call    find_free_slot
        jc      .dirfull
        mov     [cp_slot], di
        mov     word [cp_first], 0
        mov     word [cp_prev], 0
        mov     word [cp_idx], 0
.next:
        mov     bx, SECBUF
        call    ff_read
        jc      .ioerr
        test    cx, cx
        jz      .finish
        cmp     cx, 512                 ; zero the tail of the last sector
        jae     .nopad
        mov     di, SECBUF
        add     di, cx
        mov     ax, 512
        sub     ax, cx
        mov     cx, ax
        xor     al, al
        rep     stosb
.nopad:
        cmp     word [cp_idx], 0
        jne     .have
        call    alloc_cluster           ; first sector of a new cluster
        jc      .full
        cmp     word [cp_first], 0
        jne     .link
        mov     [cp_first], ax
        jmp     .setprev
.link:
        mov     dx, ax
        mov     ax, [cp_prev]
        call    fat_set                 ; previous cluster -> new cluster
        mov     ax, dx
.setprev:
        mov     [cp_prev], ax
.have:
        mov     ax, [cp_prev]
        call    clu2lba
        add     ax, [cp_idx]
        mov     bx, SECBUF
        call    write_sector
        jc      .wrerr
        inc     word [cp_idx]
        mov     ax, [cp_idx]
        cmp     ax, [spc]
        jb      .next
        mov     word [cp_idx], 0
        jmp     .next
.finish:
        call    get_datetime
        mov     di, [cp_slot]
        mov     si, dst83
        mov     bl, 0x20
        mov     dx, [cp_first]
        mov     eax, [cp_size]
        call    fill_entry
        call    fat_flush               ; FAT first, directory entry last
        jc      .discard
        call    store_dir
        jmp     .ret
.discard:
        call    fat_init
        jmp     .ret
.usage:
        mov     si, msg_u_copy
        jmp     .say
.badname:
        mov     si, msg_badname
        jmp     .say
.patherr:
        mov     si, msg_nodir
        jmp     .say
.exists:
        mov     si, msg_exists
        jmp     .say
.err:
        mov     si, ax
        test    si, si                  ; 0 = message already shown
        jz      .ret
        jmp     .say
.dirfull:
        mov     si, msg_dirfull
        jmp     .say
.full:
        mov     si, msg_full
        jmp     .undo
.ioerr:
        mov     si, msg_ioerr
        jmp     .undo
.wrerr:
        mov     si, msg_wrerr
.undo:
        call    puts
        call    fat_init                ; forget the clusters allocated so far
        jmp     .ret
.say:
        call    puts
.ret:
        mov     ax, [saved_dir]         ; always go back to the directory we started in
        mov     [cur_dir], ax
        ret

; MD name: creates a directory
do_md:
        cmp     byte [si], 0
        je      .usage
        call    parse_name
        jc      .badname
        cmp     byte [fname83], '.'
        je      .badname
        call    load_dir
        jc      .ret
        mov     si, fname83
        call    find_entry
        jnc     .exists
        call    find_free_slot
        jc      .dirfull
        mov     [cp_slot], di
        call    alloc_cluster
        jc      .full
        mov     [cp_first], ax
        call    get_datetime
        mov     di, SECBUF              ; first sector: "." and ".." entries
        mov     cx, 512
        xor     al, al
        rep     stosb
        mov     di, SECBUF
        mov     si, dot_name
        mov     bl, 0x10
        mov     dx, [cp_first]
        xor     eax, eax
        call    fill_entry
        mov     di, SECBUF + 32
        mov     si, dotdot_name
        mov     bl, 0x10
        mov     dx, [cur_dir]           ; parent (0 = root)
        xor     eax, eax
        call    fill_entry
        mov     ax, [cp_first]
        call    clu2lba
        mov     bx, SECBUF
        call    write_sector
        jc      .wrerr
        mov     dx, [spc]               ; other sectors of the cluster: zeros
        dec     dx
        jz      .entry
        mov     di, SECBUF
        mov     cx, 512
        push    ax
        xor     al, al
        rep     stosb
        pop     ax
.z:
        inc     ax
        call    write_sector
        jc      .wrerr
        dec     dx
        jnz     .z
.entry:
        mov     di, [cp_slot]
        mov     si, fname83
        mov     bl, 0x10
        mov     dx, [cp_first]
        xor     eax, eax
        call    fill_entry
        call    fat_flush               ; FAT first, directory entry last
        jc      .discard
        call    store_dir
        ret
.discard:
        call    fat_init
        ret
.usage:
        mov     si, msg_u_md
        jmp     .say
.badname:
        mov     si, msg_badname
        jmp     .say
.exists:
        mov     si, msg_exists
        jmp     .say
.dirfull:
        mov     si, msg_dirfull
        jmp     .say
.full:
        mov     si, msg_full
        jmp     .say
.wrerr:
        mov     si, msg_wrerr
        call    puts
        call    fat_init
        ret
.say:
        call    puts
.ret:
        ret

; RD name: removes an empty directory
do_rd:
        cmp     byte [si], 0
        je      .usage
        call    parse_name
        jc      .badname
        cmp     byte [fname83], '.'
        je      .nodir
        call    load_dir
        jc      .ret
        mov     si, fname83
        call    find_entry
        jc      .nodir
        test    byte [di + 11], 0x10
        jz      .nodir
        mov     [cp_slot], di
        mov     ax, [di + 26]
        mov     [cp_first], ax
        mov     [rd_clu], ax
        mov     word [rd_skip], 2       ; "." and ".." do not count
.chain:
        mov     ax, [rd_clu]
        cmp     ax, 2
        jb      .empty
        cmp     ax, 0xFF8
        jae     .empty
        call    clu2lba
        mov     [rd_lba], ax
        mov     word [rd_s], 0
.sec:
        mov     ax, [rd_lba]
        add     ax, [rd_s]
        mov     bx, SECBUF
        call    read_sector
        jc      .ioerr
        mov     si, SECBUF
        mov     cx, 16
.ent:
        cmp     word [rd_skip], 0
        je      .test
        dec     word [rd_skip]
        cmp     byte [si], '.'          ; the first two entries must be "." and ".."
        jne     .notempty
        jmp     .nx
.test:
        mov     al, [si]
        test    al, al
        jz      .empty                  ; end marker: the rest is free
        cmp     al, 0xE5
        je      .nx
        jmp     .notempty
.nx:
        add     si, 32
        loop    .ent
        inc     word [rd_s]
        mov     ax, [rd_s]
        cmp     ax, [spc]
        jb      .sec
        mov     ax, [rd_clu]
        call    fat_next
        mov     [rd_clu], ax
        jmp     .chain
.empty:
        mov     di, [cp_slot]
        mov     byte [di], 0xE5
        mov     ax, [cp_first]
        call    free_chain
        call    store_dir
        jc      .ret
        call    fat_flush
        ret
.usage:
        mov     si, msg_u_rd
        jmp     .say
.badname:
        mov     si, msg_badname
        jmp     .say
.nodir:
        mov     si, msg_nodir
        jmp     .say
.notempty:
        mov     si, msg_notempty
        jmp     .say
.ioerr:
        mov     si, msg_ioerr
.say:
        call    puts
.ret:
        ret

; ------------------------------------------------------------
;  Paths
; ------------------------------------------------------------
copystr:                                ; si -> di, including the terminating zero
        lodsb
        stosb
        test    al, al
        jnz     copystr
        ret

path_leave:                             ; back to the directory saved by enter_path / path_wrap
        mov     ax, [saved_dir]
        mov     [cur_dir], ax
        ret

; pathbuf = "dir\dir\name". Splits it: the last component goes to namebuf,
; pathbuf keeps only the directory part ("" = current, "\" = root).
split_path:
        mov     si, pathbuf
        xor     bx, bx                  ; start of the last component
        xor     cx, cx
.f:
        mov     al, [si]
        test    al, al
        jz      .done
        cmp     al, '\'
        je      .s
        cmp     al, '/'
        jne     .n
.s:
        mov     bx, cx
        inc     bx
.n:
        inc     si
        inc     cx
        jmp     .f
.done:
        mov     si, pathbuf
        add     si, bx
        mov     di, namebuf
        mov     cx, 14
.cp:
        lodsb
        stosb
        test    al, al
        jz      .cpd
        loop    .cp
        mov     byte [di], 0
.cpd:
        test    bx, bx
        jz      .nodir
        cmp     bx, 1
        ja      .trunc
        mov     byte [pathbuf + 1], 0   ; "\name": the directory part is the root
        ret
.trunc:
        dec     bx
        mov     byte [pathbuf + bx], 0  ; cut at the last separator
        ret
.nodir:
        mov     byte [pathbuf], 0
        ret

; si -> directory path. Walks into the directories by changing [cur_dir]
; (the caller restores it). CF = 1 if a component is missing or is not a directory.
walk_path:
        cmp     byte [si], '\'
        je      .abs
        cmp     byte [si], '/'
        jne     .comp
.abs:
        mov     word [cur_dir], 0
        inc     si
.comp:
        cmp     byte [si], 0
        je      .ok
        mov     di, compbuf
        xor     cx, cx
.c:
        mov     al, [si]
        test    al, al
        jz      .endc
        cmp     al, '\'
        je      .endc
        cmp     al, '/'
        je      .endc
        cmp     cx, 14
        jae     .bad
        mov     [di], al
        inc     di
        inc     si
        inc     cx
        jmp     .c
.endc:
        mov     byte [di], 0
        cmp     byte [si], 0
        je      .have
        inc     si                      ; skip the separator
.have:
        test    cx, cx
        jz      .comp                   ; empty component
        mov     [pp_ptr], si
        mov     si, compbuf
        call    parse_name
        jc      .bad
        call    load_dir
        jc      .bad
        mov     si, fname83
        call    find_entry
        jc      .bad
        test    byte [di + 11], 0x10
        jz      .bad
        mov     ax, [di + 26]
        mov     [cur_dir], ax
        mov     si, [pp_ptr]
        jmp     .comp
.ok:
        clc
        ret
.bad:
        stc
        ret

; pathbuf = full path of a file. Walks to its directory ([cur_dir], saved in saved_dir)
; and leaves the file name in fname83. CF = 1: ax = error code, [cur_dir] restored.
enter_path:
        mov     ax, [cur_dir]
        mov     [saved_dir], ax
        call    split_path
        cmp     byte [pathbuf], 0
        je      .name
        mov     si, pathbuf
        call    walk_path
        jc      .nf
.name:
        mov     si, namebuf
        call    parse_name
        jc      .bn
        clc
        ret
.nf:
        call    path_leave
        mov     ax, E_NOTFOUND
        stc
        ret
.bn:
        call    path_leave
        mov     ax, E_BADNAME
        stc
        ret

; ax = cluster, fname83 = name of the directory entered. Updates cur_dir and curpath.
cd_apply:
        cmp     byte [fname83], '.'
        jne     .append
        cmp     byte [fname83 + 1], '.'
        je      .up
        clc
        ret                             ; "." - stay here
.up:
        mov     [cur_dir], ax
        xor     bx, bx
.e:
        cmp     byte [curpath + bx], 0
        je      .f
        inc     bx
        jmp     .e
.f:
        test    bx, bx
        jz      .ok
        dec     bx
        cmp     byte [curpath + bx], '\'
        jne     .f
        mov     byte [curpath + bx], 0
.ok:
        clc
        ret
.append:
        xor     bx, bx
.e2:
        cmp     byte [curpath + bx], 0
        je      .a
        inc     bx
        jmp     .e2
.a:
        cmp     bx, 100                 ; path too long
        ja      .long
        mov     [cur_dir], ax
        lea     di, [curpath + bx]
        mov     byte [di], '\'
        inc     di
        mov     si, fname83
        mov     cx, 8
.c8:
        mov     al, [si]
        cmp     al, ' '
        je      .ext
        mov     [di], al
        inc     di
        inc     si
        loop    .c8
.ext:
        mov     si, fname83 + 8
        cmp     byte [si], ' '
        je      .term
        mov     byte [di], '.'
        inc     di
        mov     cx, 3
.c3:
        mov     al, [si]
        cmp     al, ' '
        je      .term
        mov     [di], al
        inc     di
        inc     si
        loop    .c3
.term:
        mov     byte [di], 0
        clc
        ret
.long:
        stc
        ret

; si -> path. Changes the current directory step by step. CF = 1: nothing changed.
cd_path:
        mov     ax, [cur_dir]
        mov     [cd_savedir], ax
        push    si
        mov     si, curpath
        mov     di, cd_savepath
        call    copystr
        pop     si
        cmp     byte [si], '\'
        je      .abs
        cmp     byte [si], '/'
        jne     .comp
.abs:
        mov     word [cur_dir], 0
        mov     byte [curpath], 0
        inc     si
.comp:
        cmp     byte [si], 0
        je      .ok
        mov     di, compbuf
        xor     cx, cx
.c:
        mov     al, [si]
        test    al, al
        jz      .endc
        cmp     al, '\'
        je      .endc
        cmp     al, '/'
        je      .endc
        cmp     cx, 14
        jae     .bad
        mov     [di], al
        inc     di
        inc     si
        inc     cx
        jmp     .c
.endc:
        mov     byte [di], 0
        cmp     byte [si], 0
        je      .have
        inc     si
.have:
        test    cx, cx
        jz      .comp
        mov     [pp_ptr], si
        mov     si, compbuf
        call    parse_name
        jc      .bad
        call    load_dir
        jc      .bad
        mov     si, fname83
        call    find_entry
        jc      .bad
        test    byte [di + 11], 0x10
        jz      .bad
        mov     ax, [di + 26]
        call    cd_apply
        jc      .bad
        mov     si, [pp_ptr]
        jmp     .comp
.ok:
        clc
        ret
.bad:
        mov     ax, [cd_savedir]
        mov     [cur_dir], ax
        mov     si, cd_savepath
        mov     di, curpath
        call    copystr
        stc
        ret

; Runs the command handler bx with si -> arguments. If the first word of the
; arguments contains a path, the handler runs inside that directory and sees only the name.
path_wrap:
        mov     [pw_handler], bx
        mov     di, argbuf
        mov     cx, 90
.cp:
        lodsb
        stosb
        test    al, al
        jz      .cpd
        loop    .cp
        mov     byte [di], 0
.cpd:
        mov     si, argbuf
        xor     dx, dx                  ; last separator in the first word
.scan:
        mov     al, [si]
        test    al, al
        jz      .scanned
        cmp     al, ' '
        je      .scanned
        cmp     al, '\'
        je      .sep
        cmp     al, '/'
        jne     .nx
.sep:
        mov     dx, si
.nx:
        inc     si
        jmp     .scan
.scanned:
        test    dx, dx
        jnz     .haspath
        mov     si, argbuf
        mov     bx, [pw_handler]
        jmp     bx                      ; no path: run the handler as it is
.haspath:
        mov     bx, dx
        inc     bx
        mov     [pw_name], bx           ; the name follows the last separator
        mov     si, argbuf              ; directory part -> pathbuf
        mov     di, pathbuf
.d1:
        cmp     si, dx
        jae     .d2
        movsb
        jmp     .d1
.d2:
        cmp     dx, argbuf
        jne     .term
        mov     bx, dx                  ; separator at the very start = root
        mov     al, [bx]
        stosb
.term:
        mov     byte [di], 0
        mov     ax, [cur_dir]
        mov     [saved_dir], ax
        mov     si, pathbuf
        call    walk_path
        jc      .bad
        mov     si, [pw_name]
        mov     bx, [pw_handler]
        call    bx
        call    path_leave
        ret
.bad:
        call    path_leave
        mov     si, msg_nodir
        call    puts
        ret

do_type_w:
        mov     bx, do_type
        jmp     path_wrap
do_del_w:
        mov     bx, do_del
        jmp     path_wrap
do_ren_w:
        mov     bx, do_ren
        jmp     path_wrap
do_md_w:
        mov     bx, do_md
        jmp     path_wrap
do_rd_w:
        mov     bx, do_rd
        jmp     path_wrap

do_dir_w:                               ; DIR [path]
        cmp     byte [si], 0
        je      do_dir
        mov     ax, [cur_dir]
        mov     [saved_dir], ax
        mov     di, pathbuf
        call    copystr
        mov     si, pathbuf
        call    walk_path
        jc      .bad
        call    do_dir
        jmp     .back
.bad:
        mov     si, msg_nodir
        call    puts
.back:
        call    path_leave
        ret

; ------------------------------------------------------------
;  File API for programs (INT 0x60, ah = function; CF = 1 on error with ax = code)
;    20  open for reading : ds:dx = path               -> ax = handle
;    21  create / truncate: ds:dx = path               -> ax = handle (write only)
;    22  read             : bx = handle, es:di = buffer, cx = count -> ax = bytes (0 = end)
;    23  write            : bx = handle, ds:si = data, cx = count   -> ax = bytes written
;    24  close            : bx = handle (writing: saves size and directory entry)
;    25  delete           : ds:dx = path
;    28  directory entry  : ds:dx = directory path ("" = current), cx = index,
;                           es:di = 32-byte buffer (name 11 bytes, attribute at +11,
;                           first cluster +26, size at +28). CF = 1, ax = 9 after the last one
;    2A  get current dir  : es:di = buffer (\DIR\SUB, "\" = root)
;    2B  change dir       : ds:dx = path
;  At most 4 files are open at a time; files still open when the program ends are closed.
; ------------------------------------------------------------
file_api:
        pusha
        push    ds
        push    es
        mov     [cs:u_ds], ds
        mov     [cs:u_es], es
        mov     [cs:u_func], ah
        mov     [cs:u_bx], bx
        mov     [cs:u_cx], cx
        mov     [cs:u_dx], dx
        mov     [cs:u_si], si
        mov     [cs:u_di], di
        cmp     ah, 0x20
        je      .path
        cmp     ah, 0x21
        je      .path
        cmp     ah, 0x25
        je      .path
        cmp     ah, 0x28
        je      .path
        cmp     ah, 0x2B
        je      .path
        jmp     .go
.path:
        mov     si, dx                  ; copy the path from the caller's segment
        xor     ax, ax
        mov     es, ax
        mov     di, pathbuf
        mov     cx, 79
.pc:
        lodsb
        stosb
        test    al, al
        jz      .go
        loop    .pc
        mov     byte [es:di], 0
.go:
        xor     ax, ax
        mov     ds, ax
        mov     es, ax
        call    fapi_main
        mov     [r_ax], ax
        pushf
        pop     ax
        mov     [r_fl], ax
        pop     es
        pop     ds
        popa
        mov     ax, [cs:r_ax]
        push    bp
        mov     bp, sp
        test    word [cs:r_fl], 1
        jz      .clr
        or      word [bp + 6], 1        ; CF in the flags saved by INT
        jmp     .d
.clr:
        and     word [bp + 6], 0xFFFE
.d:
        pop     bp
        iret

fapi_main:                              ; ds = es = 0, inputs in u_* variables
        mov     al, [u_func]
        cmp     al, 0x20
        je      fa_open
        cmp     al, 0x21
        je      fa_create
        cmp     al, 0x22
        je      fa_read
        cmp     al, 0x23
        je      fa_write
        cmp     al, 0x24
        je      fa_close
        cmp     al, 0x25
        je      fa_delete
        cmp     al, 0x28
        je      fa_dirent
        cmp     al, 0x2A
        je      fa_getcwd
        cmp     al, 0x2B
        je      fa_chdir
        mov     ax, E_BADFN
        stc
        ret

; --- handle table ---
h_reset:
        push    ax
        push    bx
        push    dx
        xor     bx, bx
.l:
        mov     ax, HSZ
        mul     bx
        add     ax, HTAB
        push    bx
        mov     bx, ax
        mov     byte [bx + H_MODE], 0
        pop     bx
        inc     bx
        cmp     bx, NHAND
        jb      .l
        pop     dx
        pop     bx
        pop     ax
        ret

h_ptr:                                  ; bx = handle -> si -> record. CF = 1 if not open
        cmp     bx, NHAND
        jae     .bad
        mov     ax, HSZ
        mul     bx
        add     ax, HTAB
        mov     si, ax
        cmp     byte [si + H_MODE], 0
        je      .bad
        clc
        ret
.bad:
        stc
        ret

h_alloc:                                ; free record: bx = handle, si -> record. CF = 1 if none
        xor     bx, bx
.l:
        mov     ax, HSZ
        mul     bx
        add     ax, HTAB
        mov     si, ax
        cmp     byte [si + H_MODE], 0
        je      .found
        inc     bx
        cmp     bx, NHAND
        jb      .l
        stc
        ret
.found:
        clc
        ret

; si -> read handle: loads the next sector of the file into its buffer. CF = 1 on error.
h_fill:
        mov     word [si + H_BPOS], 0
        mov     word [si + H_BVAL], 0
        cmp     dword [si + H_LEFT], 0
        je      .eof
        mov     ax, [si + H_CLU]
        cmp     ax, 2
        jb      .eof
        cmp     ax, 0xFF8
        jae     .eof
        push    si
        call    clu2lba
        add     ax, [si + H_SEC]
        mov     bx, si
        add     bx, H_BUF
        call    read_sector
        pop     si
        jc      .err
        mov     ecx, [si + H_LEFT]
        cmp     ecx, 512
        jbe     .l
        mov     ecx, 512
.l:
        sub     [si + H_LEFT], ecx
        mov     [si + H_BVAL], cx
        inc     word [si + H_SEC]
        mov     ax, [si + H_SEC]
        cmp     ax, [spc]
        jb      .ok
        mov     word [si + H_SEC], 0
        mov     ax, [si + H_CLU]
        call    fat_next
        mov     [si + H_CLU], ax
.ok:
.eof:
        clc
        ret
.err:
        stc
        ret

; si -> write handle: writes its (full) buffer to the disk. CF = 1: ax = error code
h_flush:
        push    si
        cmp     word [si + H_SEC], 0
        jne     .have
        call    alloc_cluster           ; a new cluster for this sector
        jc      .full
        cmp     word [si + H_FIRST], 0
        jne     .link
        mov     [si + H_FIRST], ax
        jmp     .setc
.link:
        mov     dx, ax
        mov     ax, [si + H_CLU]
        call    fat_set                 ; previous cluster -> new cluster
        mov     ax, dx
.setc:
        mov     [si + H_CLU], ax
.have:
        mov     ax, [si + H_CLU]
        call    clu2lba
        add     ax, [si + H_SEC]
        mov     bx, si
        add     bx, H_BUF
        call    write_sector
        jc      .disk
        inc     word [si + H_SEC]
        mov     ax, [si + H_SEC]
        cmp     ax, [spc]
        jb      .ok
        mov     word [si + H_SEC], 0
.ok:
        mov     word [si + H_BVAL], 0
        pop     si
        clc
        ret
.full:
        pop     si
        mov     ax, E_FULL
        stc
        ret
.disk:
        pop     si
        mov     ax, E_DISK
        stc
        ret

; bx = handle number: closes it (writing: flushes data, FAT and the directory entry)
h_close:
        call    h_ptr
        jc      .badh
        cmp     byte [si + H_MODE], 2
        je      .write
        mov     byte [si + H_MODE], 0
        xor     ax, ax
        clc
        ret
.write:
        mov     byte [si + H_MODE], 0   ; the handle is gone whatever happens
        cmp     word [si + H_BVAL], 0
        je      .entry
        push    si
        mov     di, si
        add     di, H_BUF
        add     di, [si + H_BVAL]
        mov     cx, 512
        sub     cx, [si + H_BVAL]
        xor     al, al
        rep     stosb                   ; zero the tail of the last sector
        pop     si
        call    h_flush
        jc      .ret
.entry:
        mov     ax, [cur_dir]
        mov     [fc_save], ax
        mov     ax, [si + H_DIR]
        mov     [cur_dir], ax
        push    si
        call    load_dir
        pop     si
        jc      .disk2
        mov     ax, [si + H_SLOT]
        shl     ax, 5
        add     ax, DIRBUF
        mov     di, ax
        mov     ax, [si + H_FIRST]
        mov     [di + 26], ax
        mov     eax, [si + H_SIZE]
        mov     [di + 28], eax
        call    get_datetime
        mov     ax, [cur_time]
        mov     [di + 22], ax
        mov     ax, [cur_date]
        mov     [di + 24], ax
        mov     [di + 18], ax
        call    fat_flush               ; FAT first, directory entry last
        jc      .disk2
        call    store_dir
        jc      .disk2
        mov     ax, [fc_save]
        mov     [cur_dir], ax
        xor     ax, ax
        clc
        ret
.disk2:
        mov     ax, [fc_save]
        mov     [cur_dir], ax
        mov     ax, E_DISK
        stc
.ret:
        ret
.badh:
        mov     ax, E_BADHANDLE
        stc
        ret

h_close_all:
        xor     bx, bx
.l:
        push    bx
        call    h_close
        pop     bx
        inc     bx
        cmp     bx, NHAND
        jb      .l
        ret

; --- API functions ---
fa_open:
        call    enter_path
        jc      .ret
        call    ff_open
        jc      .nf
        call    h_alloc
        jc      .nohandle
        mov     byte [si + H_MODE], 1
        mov     ax, [cur_dir]
        mov     [si + H_DIR], ax
        mov     ax, [ff_clu]
        mov     [si + H_CLU], ax
        mov     [si + H_FIRST], ax
        mov     word [si + H_SEC], 0
        mov     eax, [ff_left]
        mov     [si + H_LEFT], eax
        mov     [si + H_SIZE], eax
        mov     word [si + H_BPOS], 0
        mov     word [si + H_BVAL], 0
        call    path_leave
        mov     ax, bx                  ; the handle number
        clc
        ret
.nf:
        call    path_leave
        mov     ax, E_NOTFOUND
        stc
        ret
.nohandle:
        call    path_leave
        mov     ax, E_NOHANDLE
        stc
.ret:
        ret

fa_create:
        call    enter_path
        jc      .ret
        call    load_dir
        jc      .disk
        mov     si, fname83
        call    find_entry
        jc      .new
        test    byte [di + 11], 0x11    ; directory or read-only
        jnz     .denied
        mov     ax, [di + 26]           ; truncate: the old clusters become free
        mov     word [di + 26], 0
        mov     dword [di + 28], 0
        call    free_chain
        jmp     .slot
.new:
        call    find_free_slot
        jc      .dirfull
        call    get_datetime
        mov     si, fname83
        mov     bl, 0x20
        xor     dx, dx
        xor     eax, eax
        call    fill_entry
.slot:
        mov     ax, di
        sub     ax, DIRBUF
        shr     ax, 5
        mov     [f_slot], ax
        call    store_dir               ; directory first (the old data is being dropped) ...
        jc      .disk
        call    fat_flush               ; ... then the freed clusters
        jc      .disk
        call    h_alloc
        jc      .nohandle
        mov     byte [si + H_MODE], 2
        mov     ax, [cur_dir]
        mov     [si + H_DIR], ax
        mov     ax, [f_slot]
        mov     [si + H_SLOT], ax
        mov     word [si + H_FIRST], 0
        mov     dword [si + H_SIZE], 0
        mov     dword [si + H_LEFT], 0
        mov     word [si + H_CLU], 0
        mov     word [si + H_SEC], 0
        mov     word [si + H_BPOS], 0
        mov     word [si + H_BVAL], 0
        call    path_leave
        mov     ax, bx
        clc
        ret
.denied:
        call    path_leave
        mov     ax, E_DENIED
        stc
        ret
.dirfull:
        call    path_leave
        mov     ax, E_DIRFULL
        stc
        ret
.nohandle:
        call    path_leave
        mov     ax, E_NOHANDLE
        stc
        ret
.disk:
        call    path_leave
        mov     ax, E_DISK
        stc
.ret:
        ret

fa_read:
        mov     bx, [u_bx]
        call    h_ptr
        jc      .badh
        cmp     byte [si + H_MODE], 1
        jne     .badh
        mov     ax, [u_cx]
        mov     [f_rem], ax
        mov     ax, [u_di]
        mov     [f_dst], ax
        mov     word [f_done], 0
.loop:
        cmp     word [f_rem], 0
        je      .end
        mov     ax, [si + H_BPOS]
        cmp     ax, [si + H_BVAL]
        jb      .have
        call    h_fill
        jc      .disk
        cmp     word [si + H_BVAL], 0
        je      .end                    ; end of file
.have:
        mov     cx, [si + H_BVAL]
        sub     cx, [si + H_BPOS]
        cmp     cx, [f_rem]
        jbe     .n
        mov     cx, [f_rem]
.n:
        push    si
        mov     di, [f_dst]
        mov     ax, [si + H_BPOS]
        add     si, H_BUF
        add     si, ax
        mov     es, [u_es]
        push    cx
        rep     movsb                   ; handle buffer -> caller's es:di
        pop     cx
        xor     ax, ax
        mov     es, ax
        pop     si
        add     [si + H_BPOS], cx
        add     [f_dst], cx
        add     [f_done], cx
        sub     [f_rem], cx
        jmp     .loop
.end:
        mov     ax, [f_done]
        clc
        ret
.disk:
        mov     ax, E_DISK
        stc
        ret
.badh:
        mov     ax, E_BADHANDLE
        stc
        ret

fa_write:
        mov     bx, [u_bx]
        call    h_ptr
        jc      .badh
        cmp     byte [si + H_MODE], 2
        jne     .badh
        mov     ax, [u_cx]
        mov     [f_rem], ax
        mov     ax, [u_si]
        mov     [f_dst], ax             ; source offset in the caller's segment
        mov     word [f_done], 0
.loop:
        cmp     word [f_rem], 0
        je      .end
        cmp     word [si + H_BVAL], 512
        jb      .room
        call    h_flush
        jc      .ret
.room:
        mov     cx, 512
        sub     cx, [si + H_BVAL]
        cmp     cx, [f_rem]
        jbe     .n
        mov     cx, [f_rem]
.n:
        push    si
        mov     di, si
        add     di, H_BUF
        add     di, [si + H_BVAL]
        mov     si, [f_dst]
        push    ds
        mov     ds, [u_ds]
        push    cx
        rep     movsb                   ; caller's ds:si -> handle buffer
        pop     cx
        pop     ds
        pop     si
        add     [si + H_BVAL], cx
        add     [f_dst], cx
        add     [f_done], cx
        sub     [f_rem], cx
        movzx   ecx, cx
        add     [si + H_SIZE], ecx
        jmp     .loop
.end:
        mov     ax, [f_done]
        clc
        ret
.badh:
        mov     ax, E_BADHANDLE
        stc
.ret:
        ret

fa_close:
        mov     bx, [u_bx]
        jmp     h_close

fa_delete:
        call    enter_path
        jc      .ret
        call    load_dir
        jc      .disk
        mov     si, fname83
        call    find_entry
        jc      .nf
        test    byte [di + 11], 0x11    ; directory or read-only
        jnz     .denied
        mov     ax, [di + 26]
        mov     byte [di], 0xE5
        call    free_chain
        call    store_dir
        jc      .disk
        call    fat_flush
        jc      .disk
        call    path_leave
        xor     ax, ax
        clc
        ret
.nf:
        call    path_leave
        mov     ax, E_NOTFOUND
        stc
        ret
.denied:
        call    path_leave
        mov     ax, E_DENIED
        stc
        ret
.disk:
        call    path_leave
        mov     ax, E_DISK
        stc
.ret:
        ret

fa_dirent:
        mov     ax, [cur_dir]
        mov     [saved_dir], ax
        mov     si, pathbuf
        cmp     byte [si], 0
        je      .here
        call    walk_path
        jc      .nf
.here:
        call    load_dir
        jc      .disk
        mov     si, DIRBUF
        mov     cx, [dir_ents]
        mov     dx, [u_cx]              ; wanted index
        test    cx, cx
        jz      .end
.l:
        cmp     byte [si], 0
        je      .end
        cmp     byte [si], 0xE5
        je      .nx
        test    byte [si + 11], 0x08
        jnz     .nx
        test    dx, dx
        jz      .found
        dec     dx
.nx:
        add     si, 32
        loop    .l
.end:
        call    path_leave
        mov     ax, E_EOF
        stc
        ret
.found:
        mov     di, [u_di]
        mov     es, [u_es]
        mov     cx, 32
        rep     movsb
        xor     ax, ax
        mov     es, ax
        call    path_leave
        xor     ax, ax
        clc
        ret
.nf:
        call    path_leave
        mov     ax, E_NOTFOUND
        stc
        ret
.disk:
        call    path_leave
        mov     ax, E_DISK
        stc
        ret

fa_getcwd:
        mov     si, curpath
        cmp     byte [si], 0
        jne     .c
        mov     si, msg_root
.c:
        mov     di, [u_di]
        mov     es, [u_es]
.l:
        lodsb
        stosb
        test    al, al
        jnz     .l
        xor     ax, ax
        mov     es, ax
        clc
        ret

fa_chdir:
        mov     si, pathbuf
        call    cd_path
        jc      .nf
        xor     ax, ax
        clc
        ret
.nf:
        mov     ax, E_NOTFOUND
        stc
        ret

; ------------------------------------------------------------
;  Data
; ------------------------------------------------------------
cmdtab:
        dw c_help,   do_help
        dw c_ver,    do_ver
        dw c_cls,    do_cls
        dw c_echo,   do_echo
        dw c_dir,    do_dir_w
        dw c_type,   do_type_w
        dw c_cd,     do_cd
        dw c_copy,   do_copy
        dw c_del,    do_del_w
        dw c_ren,    do_ren_w
        dw c_md,     do_md_w
        dw c_mkdir,  do_md_w
        dw c_rd,     do_rd_w
        dw c_rmdir,  do_rd_w
        dw c_mem,    do_mem
        dw c_xtest,  do_xtest
        dw c_reboot, do_reboot
        dw c_halt,   do_halt
        dw 0

c_help   db 'help', 0
c_ver    db 'ver', 0
c_cls    db 'cls', 0
c_echo   db 'echo', 0
c_dir    db 'dir', 0
c_type   db 'type', 0
c_cd     db 'cd', 0
c_copy   db 'copy', 0
c_del    db 'del', 0
c_ren    db 'ren', 0
c_md     db 'md', 0
c_mkdir  db 'mkdir', 0
c_rd     db 'rd', 0
c_rmdir  db 'rmdir', 0
c_mem    db 'mem', 0
c_xtest  db 'xtest', 0
c_reboot db 'reboot', 0
c_halt   db 'halt', 0

msg_banner db 'DOSOS 16 - minimal real-mode system with unreal mode', 13, 10
           db 'Type HELP for the list of commands.', 13, 10, 13, 10, 0
msg_drive  db 'A:', 0
msg_root   db '\', 0
msg_gt     db '> ', 0
msg_bad    db 'Bad command or file name', 10, 0
msg_ver    db 'DOSOS 16 version 0.6 (FAT12 read/write, file API)', 10, 0
msg_badfs  db 'Unsupported disk format (need FAT12, 512 bytes/sector)', 13, 10, 0
msg_ioerr  db 'Disk read error', 10, 0
msg_nofile db 'File not found', 10, 0
msg_nodir  db 'Invalid directory', 10, 0
msg_badname db 'Invalid file name', 10, 0
msg_usage  db 'Usage: TYPE filename', 10, 0
msg_notexe db 'Not a DOSOS 16 program (DX16 header missing)', 10, 0
msg_big    db 'Program is too large', 10, 0
msg_fault  db 'Program fault: exception #', 0
msg_more   db '-- More --', 0
badchars   db '"*+,/:;<=>?[\]|', 0
msg_changed db 'Disk changed - FAT reloaded, back in the root directory', 10, 0
msg_xsegs  db 'ERROR: unreal_enter changed ds/es/ss!', 10, 0
msg_wrerr  db 'Disk write error (write-protected disk?)', 10, 0
msg_exists db 'File or directory already exists', 10, 0
msg_full   db 'Disk full', 10, 0
msg_dirfull db 'Directory full', 10, 0
msg_ro     db 'File is read-only', 10, 0
msg_notempty db 'Directory not empty (or damaged)', 10, 0
msg_u_del  db 'Usage: DEL filename', 10, 0
msg_u_ren  db 'Usage: REN oldname newname', 10, 0
msg_u_copy db 'Usage: COPY source target', 10, 0
msg_u_md   db 'Usage: MD dirname', 10, 0
msg_u_rd   db 'Usage: RD dirname', 10, 0
dot_name   db '.          '
dotdot_name db '..         '
msg_dirtag db '  <DIR>', 0
msg_files  db ' file(s)', 0
msg_bytes  db ' bytes', 0
msg_free   db ' bytes free', 10, 0
msg_conv   db 'Conventional memory: ', 0
msg_ext    db 'Extended memory above 1 MB: ', 0
msg_kb     db ' KB', 10, 0
msg_map    db 'BIOS memory map (base length type):', 10, 0
msg_nomap  db 'No E820 memory map (old BIOS).', 10, 0
msg_xok    db 'Extended memory test at 00110000: OK', 10, 0
msg_xfail  db 'Extended memory test at 00110000: FAILED', 10, 0
msg_xnone  db 'Not enough extended memory for the test', 10, 0
msg_help   db 'Commands:', 10
           db '  HELP        this list', 10
           db '  VER         show version', 10
           db '  CLS         clear the screen', 10
           db '  ECHO txt    print text', 10
           db '  DIR         list the current directory', 10
           db '  TYPE file   show a text file', 10
           db '  CD [path]   change directory (CD \ = root, CD .. = up, CD A\B)', 10
           db '  COPY a b    copy file a to b (paths allowed; b may be a directory)', 10
           db '  DEL file    delete a file', 10
           db '  REN a b     rename a file or directory', 10
           db '  MD dir      make a directory (also MKDIR)', 10
           db '  RD dir      remove an empty directory (also RMDIR)', 10
           db '  MEM         memory sizes and BIOS memory map', 10
           db '  XTEST       test access to memory above 1 MB', 10
           db '  NAME [args] run NAME.BIN (a DX16 program) from this directory', 10
           db '  REBOOT      restart the machine', 10
           db '  HALT        stop the CPU', 10, 0

; variables (filled in at start-up)
drive     db 0
spc       dw 0
spt       dw 0
heads     dw 0
fat_lba   dw 0
spf       dw 0
root_lba  dw 0
root_secs dw 0
root_ents dw 0
data_lba  dw 0
ncl       dw 0
rd_try    db 0
nfat      dw 0
fat_dirty db 0
cur_date  dw 0
cur_time  dw 0
fe_size   dd 0
cp_size   dd 0
cp_first  dw 0
cp_prev   dw 0
cp_idx    dw 0
cp_slot   dw 0
cp_dstp   dw 0
saved_dir dw 0
cd_savedir dw 0
pp_ptr    dw 0
pw_handler dw 0
pw_name   dw 0
fc_save   dw 0
f_slot    dw 0
f_rem     dw 0
f_dst     dw 0
f_done    dw 0
u_ds      dw 0
u_es      dw 0
u_func    db 0
u_bx      dw 0
u_cx      dw 0
u_dx      dw 0
u_si      dw 0
u_di      dw 0
r_ax      dw 0
r_fl      dw 0
rd_clu    dw 0
rd_lba    dw 0
rd_s      dw 0
rd_skip   dw 0
cur_dir   dw 0                          ; first cluster of the current directory (0 = root)
dir_ents  dw 0
dir_files dd 0
dir_bytes dd 0
ff_clu    dw 0
ff_sec    dw 0
ff_left   dd 0
lines     dw 0
cmdargs   dw 0
ksp       dw 0
kss       dw 0
prog_running db 0
fault_no  db 0
e820_n    dw 0
ext_kb    dd 0
ext_kb_fb dd 0
fname83:  times 12 db 0
namebuf:  times 16 db 0
compbuf:  times 16 db 0
pathbuf:  times 96 db 0
argbuf:   times 96 db 0
cd_savepath: times 128 db 0
src83:    times 12 db 0
dst83:    times 12 db 0
linebuf:  times 80 db 0
curpath:  times 128 db 0
cmdword:  times 16 db 0
e820buf:  times 24*32 db 0

; pad the kernel to a whole number of sectors (error here = kernel too big)
times KSECT*512 - ($ - $$) db 0

; ------------------------------------------------------------
;  Rest of the FAT12 floppy: FAT1, FAT2, root directory, data area
; ------------------------------------------------------------
db 0xF0, 0xFF, 0xFF
times FATSEC*512 - 3 db 0
db 0xF0, 0xFF, 0xFF
times FATSEC*512 - 3 db 0
times ROOTSEC*512 db 0
times NCLUS*512 db 0
