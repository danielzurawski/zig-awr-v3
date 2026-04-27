const std = @import("std");
const cfg = @import("config");

// Linux ioctl constants for I2C
const I2C_SLAVE: u16 = 0x0703;

// ── I2C Interface ────────────────────────────────────────────────────
pub const I2cDevice = struct {
    address: u7,
    bus: if (cfg.sim) SimI2cBus else LinuxI2cBus,

    pub fn init(address: u7) I2cDevice {
        return .{
            .address = address,
            .bus = if (cfg.sim) SimI2cBus.init(address) else LinuxI2cBus.init(address),
        };
    }

    pub fn writeReg(self: *I2cDevice, reg: u8, data: []const u8) !void {
        if (cfg.sim) {
            self.bus.writeReg(reg, data);
        } else {
            try self.bus.writeReg(reg, data);
        }
    }

    pub fn readReg(self: *I2cDevice, reg: u8) !u8 {
        if (cfg.sim) {
            return self.bus.readReg(reg);
        } else {
            return try self.bus.readReg(reg);
        }
    }

    /// Raw write (no register prefix) for devices like ADS7830
    pub fn rawWrite(self: *I2cDevice, data: []const u8) !void {
        if (cfg.sim) {
            if (data.len > 0) self.bus.writeReg(data[0], data[1..]);
        } else {
            try self.bus.rawWrite(data);
        }
    }

    /// Raw read (single byte, no register select) for devices like ADS7830
    pub fn rawRead(self: *I2cDevice) !u8 {
        if (cfg.sim) {
            return self.bus.readReg(0);
        } else {
            return try self.bus.rawRead();
        }
    }

    pub fn deinit(self: *I2cDevice) void {
        if (!cfg.sim) {
            self.bus.deinit();
        }
    }
};

// ── GPIO Interface ───────────────────────────────────────────────────
pub const GpioPin = struct {
    pin: u8,
    backend: if (cfg.sim) SimGpio else LinuxGpio,

    pub fn init(pin: u8) GpioPin {
        return .{
            .pin = pin,
            .backend = if (cfg.sim) SimGpio.init(pin) else LinuxGpio.init(pin),
        };
    }

    pub fn read(self: *GpioPin) bool {
        return self.backend.read();
    }

    pub fn write(self: *GpioPin, value: bool) void {
        self.backend.write(value);
    }

    pub fn deinit(self: *GpioPin) void {
        if (!cfg.sim) {
            self.backend.deinit();
        }
    }
};

// ── SPI Interface ────────────────────────────────────────────────────
pub const SpiDevice = struct {
    backend: if (cfg.sim) SimSpi else LinuxSpi,

    pub fn init() SpiDevice {
        return .{
            .backend = if (cfg.sim) SimSpi.init() else LinuxSpi.init(),
        };
    }

    pub fn transfer(self: *SpiDevice, data: []const u8) void {
        self.backend.transfer(data);
    }

    pub fn deinit(self: *SpiDevice) void {
        if (!cfg.sim) {
            self.backend.deinit();
        }
    }
};

// ── HAL Context ──────────────────────────────────────────────────────
pub const HalContext = struct {
    i2c_pca9685: I2cDevice,
    i2c_ads7830: I2cDevice,
    spi: SpiDevice,
    gpio_trig: GpioPin,
    gpio_echo: GpioPin,
    gpio_led1: GpioPin,
    gpio_led2: GpioPin,
    gpio_led3: GpioPin,
    gpio_buzzer: GpioPin,
    gpio_line_l: GpioPin,
    gpio_line_m: GpioPin,
    gpio_line_r: GpioPin,

    pub fn init() HalContext {
        return .{
            .i2c_pca9685 = I2cDevice.init(0x5f),
            .i2c_ads7830 = I2cDevice.init(0x48),
            .spi = SpiDevice.init(),
            .gpio_trig = GpioPin.init(23),
            .gpio_echo = GpioPin.init(24),
            .gpio_led1 = GpioPin.init(9),
            .gpio_led2 = GpioPin.init(25),
            .gpio_led3 = GpioPin.init(11),
            .gpio_buzzer = GpioPin.init(18),
            .gpio_line_l = GpioPin.init(22),
            .gpio_line_m = GpioPin.init(27),
            .gpio_line_r = GpioPin.init(17),
        };
    }

    pub fn deinit(self: *HalContext) void {
        self.i2c_pca9685.deinit();
        self.i2c_ads7830.deinit();
        self.spi.deinit();
        self.gpio_trig.deinit();
        self.gpio_echo.deinit();
        self.gpio_led1.deinit();
        self.gpio_led2.deinit();
        self.gpio_led3.deinit();
        self.gpio_buzzer.deinit();
        self.gpio_line_l.deinit();
        self.gpio_line_m.deinit();
        self.gpio_line_r.deinit();
    }
};

// ═══════════════════════════════════════════════════════════════════════
// Simulation backends (in-memory, no hardware)
// ═══════════════════════════════════════════════════════════════════════

pub const SimI2cBus = struct {
    address: u7,
    regs: [256]u8 = [_]u8{0} ** 256,

    pub fn init(address: u7) SimI2cBus {
        return .{ .address = address };
    }

    pub fn writeReg(self: *SimI2cBus, reg: u8, data: []const u8) void {
        for (data, 0..) |byte, i| {
            const idx = @as(usize, reg) + i;
            if (idx < 256) {
                self.regs[idx] = byte;
            }
        }
    }

    pub fn readReg(self: *SimI2cBus, reg: u8) u8 {
        return self.regs[reg];
    }
};

pub const SimGpio = struct {
    pin: u8,
    value: bool = false,

    pub fn init(pin: u8) SimGpio {
        return .{ .pin = pin };
    }

    pub fn read(self: *SimGpio) bool {
        return self.value;
    }

    pub fn write(self: *SimGpio, value: bool) void {
        self.value = value;
    }
};

pub const SimSpi = struct {
    last_len: usize = 0,

    pub fn init() SimSpi {
        return .{};
    }

    pub fn transfer(self: *SimSpi, data: []const u8) void {
        self.last_len = data.len;
    }
};

// ═══════════════════════════════════════════════════════════════════════
// Linux backends (real hardware via /dev and /sys)
// ═══════════════════════════════════════════════════════════════════════

pub const LinuxI2cBus = struct {
    address: u7,
    fd: std.posix.fd_t = -1,

    pub fn init(address: u7) LinuxI2cBus {
        var self = LinuxI2cBus{ .address = address };
        // Open /dev/i2c-1 and set slave address
        self.fd = std.posix.open("/dev/i2c-1", .{ .ACCMODE = .RDWR }, 0) catch -1;
        if (self.fd >= 0) {
            // ioctl(fd, I2C_SLAVE, address)
            const addr_ulong: usize = @intCast(address);
            _ = std.os.linux.ioctl(@intCast(self.fd), I2C_SLAVE, addr_ulong);
        }
        return self;
    }

    pub fn writeReg(self: *LinuxI2cBus, reg: u8, data: []const u8) !void {
        if (self.fd < 0) return error.DeviceNotOpen;
        // Write: [register_address, data_bytes...]
        var write_buf: [33]u8 = undefined; // max 32 data bytes + 1 reg byte
        write_buf[0] = reg;
        const copy_len = @min(data.len, 32);
        @memcpy(write_buf[1 .. 1 + copy_len], data[0..copy_len]);
        _ = try std.posix.write(self.fd, write_buf[0 .. 1 + copy_len]);
    }

    pub fn readReg(self: *LinuxI2cBus, reg: u8) !u8 {
        if (self.fd < 0) return error.DeviceNotOpen;
        // Write register address, then read one byte
        _ = try std.posix.write(self.fd, &[_]u8{reg});
        var result: [1]u8 = undefined;
        _ = try std.posix.read(self.fd, &result);
        return result[0];
    }

    pub fn rawWrite(self: *LinuxI2cBus, data: []const u8) !void {
        if (self.fd < 0) return error.DeviceNotOpen;
        _ = try std.posix.write(self.fd, data);
    }

    pub fn rawRead(self: *LinuxI2cBus) !u8 {
        if (self.fd < 0) return error.DeviceNotOpen;
        var result: [1]u8 = undefined;
        _ = try std.posix.read(self.fd, &result);
        return result[0];
    }

    pub fn deinit(self: *LinuxI2cBus) void {
        if (self.fd >= 0) {
            std.posix.close(self.fd);
            self.fd = -1;
        }
    }
};

pub const LinuxGpio = struct {
    pin: u8,
    exported: bool = false,
    value_path: [48]u8 = undefined,
    value_path_len: usize = 0,

    pub fn init(pin: u8) LinuxGpio {
        var self = LinuxGpio{ .pin = pin };
        var pin_buf: [4]u8 = undefined;
        var stream = std.io.fixedBufferStream(&pin_buf);
        stream.writer().print("{d}", .{pin}) catch return self;
        const pin_str = stream.getWritten();

        const export_fd = std.posix.open("/sys/class/gpio/export", .{ .ACCMODE = .WRONLY }, 0) catch return self;
        _ = std.posix.write(export_fd, pin_str) catch {};
        std.posix.close(export_fd);

        const is_input = (pin == 24 or pin == 22 or pin == 27 or pin == 17);

        var dir_path: [64]u8 = undefined;
        var dp_stream = std.io.fixedBufferStream(&dir_path);
        dp_stream.writer().print("/sys/class/gpio/gpio{d}/direction", .{pin}) catch return self;
        const dir_fd = std.posix.open(dir_path[0..dp_stream.pos], .{ .ACCMODE = .WRONLY }, 0) catch {
            std.time.sleep(50_000_000); // 50ms
            const retry_fd = std.posix.open(dir_path[0..dp_stream.pos], .{ .ACCMODE = .WRONLY }, 0) catch return self;
            _ = std.posix.write(retry_fd, if (is_input) "in" else "out") catch {};
            std.posix.close(retry_fd);
            var path_stream2 = std.io.fixedBufferStream(&self.value_path);
            path_stream2.writer().print("/sys/class/gpio/gpio{d}/value", .{pin}) catch return self;
            self.value_path_len = path_stream2.pos;
            self.exported = true;
            return self;
        };
        _ = std.posix.write(dir_fd, if (is_input) "in" else "out") catch {};
        std.posix.close(dir_fd);

        var path_stream = std.io.fixedBufferStream(&self.value_path);
        path_stream.writer().print("/sys/class/gpio/gpio{d}/value", .{pin}) catch return self;
        self.value_path_len = path_stream.pos;
        self.exported = true;
        return self;
    }

    pub fn read(self: *LinuxGpio) bool {
        if (!self.exported or self.value_path_len == 0) return false;
        const fd = std.posix.open(self.value_path[0..self.value_path_len], .{ .ACCMODE = .RDONLY }, 0) catch return false;
        defer std.posix.close(fd);
        var buf: [2]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch return false;
        return n > 0 and buf[0] == '1';
    }

    pub fn write(self: *LinuxGpio, value: bool) void {
        if (!self.exported or self.value_path_len == 0) return;
        const fd = std.posix.open(self.value_path[0..self.value_path_len], .{ .ACCMODE = .WRONLY }, 0) catch return;
        defer std.posix.close(fd);
        const byte: [1]u8 = .{if (value) '1' else '0'};
        _ = std.posix.write(fd, &byte) catch {};
    }

    pub fn deinit(self: *LinuxGpio) void {
        if (self.exported) {
            var pin_buf: [4]u8 = undefined;
            var stream = std.io.fixedBufferStream(&pin_buf);
            stream.writer().print("{d}", .{self.pin}) catch return;
            const unexport_fd = std.posix.open("/sys/class/gpio/unexport", .{ .ACCMODE = .WRONLY }, 0) catch return;
            _ = std.posix.write(unexport_fd, stream.getWritten()) catch {};
            std.posix.close(unexport_fd);
            self.exported = false;
        }
    }
};

pub const LinuxSpi = struct {
    fd: std.posix.fd_t = -1,

    pub fn init() LinuxSpi {
        var self = LinuxSpi{};
        self.fd = std.posix.open("/dev/spidev0.0", .{ .ACCMODE = .RDWR }, 0) catch -1;
        return self;
    }

    pub fn transfer(self: *LinuxSpi, data: []const u8) void {
        if (self.fd < 0) return;
        _ = std.posix.write(self.fd, data) catch {};
    }

    pub fn deinit(self: *LinuxSpi) void {
        if (self.fd >= 0) {
            std.posix.close(self.fd);
            self.fd = -1;
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────
test "HAL context initializes" {
    var ctx = HalContext.init();
    defer ctx.deinit();
    try std.testing.expectEqual(@as(u7, 0x5f), ctx.i2c_pca9685.address);
    try std.testing.expectEqual(@as(u7, 0x48), ctx.i2c_ads7830.address);
}

test "SimI2cBus read/write" {
    if (!cfg.sim) return;
    var bus = SimI2cBus.init(0x5f);
    const data = [_]u8{ 0xAB, 0xCD };
    bus.writeReg(0x10, &data);
    try std.testing.expectEqual(@as(u8, 0xAB), bus.readReg(0x10));
    try std.testing.expectEqual(@as(u8, 0xCD), bus.readReg(0x11));
}

test "SimGpio read/write" {
    if (!cfg.sim) return;
    var gpio = SimGpio.init(23);
    try std.testing.expect(!gpio.read());
    gpio.write(true);
    try std.testing.expect(gpio.read());
}