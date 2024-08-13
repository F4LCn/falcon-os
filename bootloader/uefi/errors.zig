pub const BootloaderError = error{
    MemoryMapError,
    InvalidPathError,
    FileLoadError,
    ConfigParseError,
    GraphicOutputDeviceError,
    LocateGraphicOutputError,
    EdidNotFoundError,
};
