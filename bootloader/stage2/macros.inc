macro print msg {
if ~ msg eq si
    push si
    mov si, msg
end if
    call printfunc
if ~ msg eq si
    pop si
end if
}