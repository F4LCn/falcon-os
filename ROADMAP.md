# OS game plan

## bootloading (BIOS)
- First stage bootloader
  - [x] Loads the 2nd stage (try to make it reusable/configurable)
- Second stage bootloader
  - [x] physical memory mapping
  - [x] video mode setup
  - [x] switch to protected mode (we might need to switch back and forth between real and prot modes still)
  - [x] Add support for PSF font
  - [x] implement printf (roughly)
  - [x] physical memory allocator
  - [x] read partition table
  - [x] FAT16 filesystem support
  - [x] read some config file given a path
  - [x] parsing config file
  - [x] load the kernel executable as defined in config
  - [x] elf executable support
  - [x] init paging (first look at virtual mem mapping)
  - [x] switch to long mode
  - [x] handoff execution to kernel

## bootloading (UEFI)
- side quest accepted: make a uefi bootloader
  - [x] introduction to UEFI
  - [x] logging infrastructure
  - [x] memory mapping (phase 1)
  - [x] load config file
  - [ ] parse config file
  - [ ] video modes
  - [ ] load kernel
  - [ ] elf support
  - [ ] paging
  - [ ] memory map (phase 2)
  - [ ] execution handoff to kernel

## kernel
- Actual kernel
    - threading
    - smp
    - fs
    - fun stuff ??

