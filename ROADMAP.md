# OS game plan

## bootloading (BIOS)
- First stage bootloader
  - [x] Loads the 2nd stage (try to make it reusable/configurable)
- Second stage bootloader:
    - [x] physical memory mapping
    - [x] video mode setup
    - [ ] switch to protected mode (we might need to switch back and forth between real and prot modes still)
    - [ ] init paging (first look at virtual mem mapping)
    - [ ] read some config file
    - [ ] load the kernel executable as defined in config
    - [ ] switch to long mode
    - [ ] handoff execution to kernel (send data to kernel somehow)

## bootloading (UEFI)
- maybe ?? 

## kernel
- Actual kernel
    - threading
    - smp
    - fs
    - fun stuff ??

