OUTPUT_FORMAT("elf64-x86-64", "elf64-x86-64", "elf64-x86-64")
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

fb          = 0xffffffffc0000000;
bootinfo    = 0xfffffffffc000000;
env	    = 0xfffffffffc001000;

SECTIONS
{
  . = 0xFFFFFFFFFC002000;
	.text ALIGN(4K):
	{
		*(.text .stub .text.* .gnu.linkonce.t.*)
	} = 0x90909090

  .init.text ALIGN(4K): {
   *(.init.text)
  }

	.rodata	ALIGN(4K)	:
	{
		*(.rodata .rodata.* .gnu.linkonce.r.*)
	}
	.rodata1	:
	{
		*(.rodata1)
	}

	.data	ALIGN(4K)	:
	{
		*(.data .data.* .gnu.linkonce.d.*)
		*(.got)
	}
	.data1		:
	{
		*(.data1)
	}

	__bss_start = .;
	.bss	ALIGN(4K)	:
	{
		*(.dynbss)
		*(.bss .bss.* .gnu.linkonce.b.*)
		*(COMMON)
	}

	.heap ALIGN(4K) (NOLOAD) :
	{
    . = ALIGN(4K);
    *(.kernel_heap)
	}

	. = ALIGN(8);
	_kernel_end = .;
	PROVIDE(_kernel_end = .);

/DISCARD/ : { *(.eh_frame) *(.eh_frame_hdr) *(.note.GNU-stack) *(.gnu_debuglink) *(.exitcall.exit) *(.exit.data) *(.exit.text)}
}


