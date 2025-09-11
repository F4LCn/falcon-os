// TODO: on the bootloaders side
// debug info should be loaded by the bootloader if the relevant sections exist
// in the elf binary. A new field should be added to the bootinfo struct pointing to a mapped page
// containing the debug info (parsed? prob not just load the sections into memory and we'll read them).

// NOTE: Design goals ..
// This module should handle parsing the dwarf data from debug sections and provide an API that
// lets us find a symbol (variable/function/module) given an address (a stack trace entry for example)
