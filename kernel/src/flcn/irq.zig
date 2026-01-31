// NOTE: Ideas for a generic IRQ handling model
// [x] Main "interface" is IrqManager. What the drivers talk to (timers/devices/pci/etc), maybe through an arch specific IrqBackend
// [x] Drivers would ask for Irq registration by giving an IrqConfig with the irq source (ioapic/local apic/msi), maybe a name or a subsystem and some priority ?
// maybe a handler fn, some other details, maybe hardware config for ioapic like polarity/trigger mode
// [x] IrqManager would then allocate a free vector from some VectorAllocator then proceeds to call the hardware level
// subsystem to configure the irq to trigger the int at the allocated vector (this part should be arch specific).
// maybe in IrqManager (or somewhere else) we track for each vector the irq registered for that. this actually brings me to think about 
// handler priority. currently we run handlers in the order of registration, we can do better.
// other nice to haves:
// * irq stats: track irq counts/handling time per vector (maybe per subsystem, not sure)
// * irq balancing: use irq stats + some trigger to migrate chosen irq to the least busy core

// NOTE: design notes for "soft" irqs
// * base idea: handling "hard" interrupts by disabling interrupts block the cpu for too long from servicing other interrupts
// * base idea: we can defer some less critical work by first freeing the core by sending an eoi and then going through
// * base idea: the deferred work in which case this deferred work can be interrupted by a new interrupt
// * so we need a list of work that has been deferred constructed/appended to from the hard interrupt
// * then once we send eoi we start handling the deferred work.
// * maybe we have some budget that gets exhausted and forces us to move on

