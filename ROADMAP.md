# OS game plan

## bootloading (BIOS)
- First stage bootloader
  - [x] Loads the 2nd stage (try to make it reusable/configurable)
- Second stage bootloader:
    - [x] physical memory mapping
    - [x] video mode setup
    - [x] switch to protected mode (we might need to switch back and forth between real and prot modes still)
    - [x] Add support for PSF font
    - [x] implement printf (roughly)
    - [x] physical memory allocator
    - [x] read partition table
    - [ ] filesystem support
    - [ ] read some config file
    - [ ] load the kernel executable as defined in config
    - [ ] init paging (first look at virtual mem mapping)
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

