; Prints "Hello, PDP-11!" on the console and halts.
; Numbers are decimal by default, 0o-prefixed values are octal.

        mov #msg, r0        ; R0 = address of the string (PC-relative)
        mov #15, r1         ; R1 = length (14 chars + newline)

loop:   movb (r0)+, @#0o177566  ; print byte at R0, advance R0
        sob r1, loop

        halt

msg:    .ascii "Hello, PDP-11!"
        .byte 10
