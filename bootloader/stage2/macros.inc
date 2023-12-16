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

macro go_real {
use32
    call near set_real_mode
use16
}

macro go_prot {
use16
    call near set_prot_mode
use32
}