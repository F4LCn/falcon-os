pub const BootloaderError = error{
    MemoryMapError,
    InvalidPathError,
    FileLoadError,
    ConfigParseError,
    GraphicOutputDeviceError,
    LocateGraphicOutputError,
    EdidNotFoundError,
    InvalidKernelExecutable,
    KernelTooLargeError,
    AddressSpaceAllocatePages,
    BadAddressType,
};
