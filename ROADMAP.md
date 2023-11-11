# OS game plan

## bootloading (BIOS)
- First stage bootloader
    - Loads the 2nd stage (try to make it reusable/configurable)
- Second stage bootloader:
    - physical memory mapping
    - video mode setup
    - switch to protected mode (we might need to switch back and forth between real and prot modes still)
    - init paging (first look at virtual mem mapping)
    - read some config file
    - load the kernel file as defined in config
    - switch to long mode
    - handoff execution to kernel (send data to kernel somehow)

## bootloading (UEFI)
- maybe ?? 

## kernel
- Actual kernel
    - threading
    - smp
    - fs
    - fun stuff ??

