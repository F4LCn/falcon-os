// NOTE: design notes for time keeping subsystem
// * arch independent tick source "interface" offers a read() -> u64 function to read the underlying timer chip counter
// * time keeping can register different tick source implementations each of which has a precision factor (sort of minimal/typical period ?) that determines priority
// * always read from the highest priority timer available
// * maybe another tick notifier "interface", offers a function to program a timer interrupt
// * time keeping keeps a clock (ticks) + different "clock sources" as offsets to the clock ticks
// * for ex: maybe we have a time of day clock; offset set on start up by reading the time of day from the RTC
// * for ex: a monotonic clock; offset 0 from clock
// * time keeping registers a timer interrupt handler
// * on interrupt read tick source and update clock ticks
// * processes can request ticks for different clock source ?
// * timer interrupt programmed on-demand by looking at all things that need to be serviced on that interrupt
// * and taking the soonest expiration, maybe that way the kernel would get out of the way of userspace if there is no need to
// * schedule/service timers


// NOTE: design notes for timers
// * time keeping subsystem has an API to create timers
// * timers have a callback + a deadline (delay before first tick) + period (delay before ticks) ?
// * timers get put in buckets 
//   (bucket0 has all timers that will expire next tick, )
//   (bucket1 has all timers that will expire in the next 1ms)
//   (bucketN has all timers that will expire in the next 2^N - 1 ms)
// * on each timer interrupt tick, service all timers by calling their callbacks in bucket0
// * then take timers from bucket1 that would expire next then put them in bucket0
