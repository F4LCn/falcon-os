# write an operating system (from scratch)

## constraints
- intel x86_64 arch only
- assume hardware from 2010

## main goals
- 64bit
- smp (symmetric multiprocessing)
- multithreading & preemptive scheduling
- written in c (and a bit of asm)
- (maybe) pci/e device enumeration
- (maybe) pci/e device driver

## tools
- vm: bochs, qemu
- assembler: fasm
- c compiler: clang
- objdump, objcopy, ... or better yet some sort of gnu env (linux, wsl, cygwin)

## References
References moved to [here](REFERENCES.md)

## Roadmap
The roadmap for this project can be found [here](ROADMAP.md)

## Contribution
This project is meant for a YouTube series on how to write an os from scratch. PR on topics not yet covered will not be accepted (unless an issue was discussed and approved beforehand).
Bug fixes and improvements for topics already covered are welcome as long as they don't deviate too much from the aim of this project (simplicity and clarity over perfection/performance)