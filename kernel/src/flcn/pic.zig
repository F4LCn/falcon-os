const assembly = @import("arch").assembly;

const pic1_command = 0x20;
const pic2_command = 0xa0;
const pic1_data = pic1_command + 1;
const pic2_data = pic2_command + 1;

pub fn disable() void {
    assembly.outb(pic1_data, 0xff);
    assembly.outb(pic2_data, 0xff);
}
