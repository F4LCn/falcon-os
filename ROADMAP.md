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
  - [x] parse config file
  - [x] get display preferred resolution using EDID
  - [x] change to graphics mode
  - [x] load kernel
  - [x] elf support
  - [x] paging
  - [x] map kernel address space
  - [x] putting the memory map in bootinfo (done with uefi memory types, regions of interest (kernel/fb/etc.) not yet clearly identified)
  - [x] execution handoff to kernel

## kernel
  - Early init
    * [x] Cpu identification and capabilities (initial setup)
    * [x] Setup serial logger
    * [-] Early heap allocation
    * [x] Linked list implementation
    * [ ] GDT redefinition
    * [ ] Hardware exceptions & interrupts
    * [ ] CPU resolution & init
    * [ ] Synchronization (Mutex, lock, ...)

  - Core features
    * [ ] Allocators hierarchy
      * [ ] Virtual memory manager / Page allocator
      * [-] Physical memory manager / Frame allocator
      * [ ] General purpose heap allocator
    * [ ] Advanced interrupt handling (IRQ allocation, ...)
    * [ ] SMP
    * [ ] Processes, Threads & context switching
    * [ ] Task / Task queues ?
    * [ ] Scheduling
    * [ ] Timers
    * [ ] Basic graphics (Console + basic font rendering)

  - Nice to haves
    * [ ] PCI enumeration
    * [ ] a few PCI drivers (NVMe/ATA/USB)
    * [ ] USB (a few usb drivers, maybe HID, mass storage)
    * [ ] File system (physical fs (ext2/fat32) and virtual (root) fs)
    * [ ] In kernel debugging (gdb server)
    * [ ] Networking (NIC driver, DHCP client, TCP, HTTP)
    * [ ] Userspace
    * [ ] Graphics (graphic context, windows & compositing) or (consoles, tmux like panes)

