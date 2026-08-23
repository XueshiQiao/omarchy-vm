//  omarchy-vm — a minimal Linux VM host built on Apple's Virtualization.framework.
//
//  Boots an aarch64 Linux guest through the EFI bootloader, which is the only
//  thing this framework can do on Apple Silicon: it virtualises the native ARM
//  CPU and has no instruction translation, so x86_64 images cannot boot here.

import AppKit
import Foundation
import Virtualization

// MARK: - Options

struct Options {
    var cpuCount = 6
    var memoryGB: UInt64 = 12
    var diskGB: UInt64 = 64
    var isoPath: String?
    var width = 1920
    var height = 1200
    var bundle = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Code/omarchy-vm/vm")
}

func usage() -> String {
    """
    omarchy-vm — run an aarch64 Linux VM on Apple's Virtualization.framework

    USAGE
      omarchy-vm [--iso <path>] [--cpus N] [--memory GB] [--disk GB]
                 [--width PX] [--height PX] [--bundle <dir>]

      --iso     Attach an installer image as a USB mass-storage device. Omit it
                once the system is installed so the VM boots off its own disk.
      --bundle  Directory holding disk.img, efistore.nvram and console.log.
                Defaults to ~/Code/omarchy-vm/vm.
    """
}

func parseArgs() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    func next(_ flag: String) -> String {
        guard let v = args.next() else { fail("\(flag) needs a value") }
        return v
    }
    while let a = args.next() {
        switch a {
        case "--iso": o.isoPath = next(a)
        case "--cpus": o.cpuCount = Int(next(a)) ?? o.cpuCount
        case "--memory": o.memoryGB = UInt64(next(a)) ?? o.memoryGB
        case "--disk": o.diskGB = UInt64(next(a)) ?? o.diskGB
        case "--width": o.width = Int(next(a)) ?? o.width
        case "--height": o.height = Int(next(a)) ?? o.height
        case "--bundle": o.bundle = URL(fileURLWithPath: next(a))
        case "-h", "--help": print(usage()); exit(0)
        default: fail("unknown argument \(a)\n\n\(usage())")
        }
    }
    return o
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("omarchy-vm: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func note(_ message: String) {
    print("omarchy-vm: \(message)")
    fflush(stdout)
}

// MARK: - On-disk state

/// Creates the guest's backing disk as a sparse file, so a 64 GB disk costs
/// nothing until the guest actually writes to it.
func ensureDisk(at url: URL, sizeGB: UInt64) {
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) { return }
    guard fm.createFile(atPath: url.path, contents: nil) else {
        fail("could not create \(url.path)")
    }
    do {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: sizeGB * 1024 * 1024 * 1024)
        try handle.close()
    } catch {
        fail("could not size \(url.path): \(error.localizedDescription)")
    }
    note("created a \(sizeGB) GB sparse disk at \(url.path)")
}

func ensureVariableStore(at url: URL) -> VZEFIVariableStore {
    if FileManager.default.fileExists(atPath: url.path) {
        return VZEFIVariableStore(url: url)
    }
    do {
        let store = try VZEFIVariableStore(creatingVariableStoreAt: url)
        note("created a fresh EFI variable store at \(url.path)")
        return store
    } catch {
        fail("could not create the EFI variable store: \(error.localizedDescription)")
    }
}

/// Puts the guest's serial console on a host pty, so it is a real two-way
/// terminal: read the returned device to see what the guest prints, write to it
/// to type at the guest. A write-only log file would only ever let us watch,
/// which is not enough to drive an installer when the GUI is unreachable.
func serialPortOnPTY() -> (VZVirtioConsoleDeviceSerialPortConfiguration, String) {
    let primary = posix_openpt(O_RDWR | O_NOCTTY)
    guard primary >= 0, grantpt(primary) == 0, unlockpt(primary) == 0,
          let name = ptsname(primary)
    else {
        fail("could not allocate a pty for the serial console")
    }
    let handle = FileHandle(fileDescriptor: primary, closeOnDealloc: false)
    let port = VZVirtioConsoleDeviceSerialPortConfiguration()
    port.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: handle, fileHandleForWriting: handle)
    return (port, String(cString: name))
}

/// Keeps reading the guest side of the console and appends it to a log.
///
/// This is not just for the log: a pty whose buffer nobody empties will block
/// the writer, and the writer here is the guest's console. Leave it undrained
/// and every process that prints to the console wedges, which starves the whole
/// guest — services time out, load climbs, and the machine looks hung for
/// reasons that have nothing to do with what it was asked to do.
func drainConsole(from devicePath: String, into logURL: URL) {
    let fm = FileManager.default
    if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
    guard let log = try? FileHandle(forWritingTo: logURL) else {
        note("warning: cannot open \(logURL.path); console will not be logged")
        return
    }
    log.seekToEndOfFile()

    let fd = open(devicePath, O_RDWR | O_NOCTTY)
    guard fd >= 0 else {
        note("warning: cannot open \(devicePath); the guest console may stall")
        return
    }
    // Raw mode, or the line discipline would echo the guest's own output back at it.
    var term = termios()
    if tcgetattr(fd, &term) == 0 {
        cfmakeraw(&term)
        tcsetattr(fd, TCSANOW, &term)
    }

    Thread.detachNewThread {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
            if n > 0 {
                log.write(Data(buffer[0..<n]))
            } else if n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN) {
                break
            }
        }
    }
}

// MARK: - Machine configuration

func makeConfiguration(_ o: Options) -> VZVirtualMachineConfiguration {
    let fm = FileManager.default
    try? fm.createDirectory(at: o.bundle, withIntermediateDirectories: true)

    let diskURL = o.bundle.appendingPathComponent("disk.img")
    let nvramURL = o.bundle.appendingPathComponent("efistore.nvram")
    let consoleURL = o.bundle.appendingPathComponent("console.log")

    ensureDisk(at: diskURL, sizeGB: o.diskGB)

    let config = VZVirtualMachineConfiguration()
    config.cpuCount = o.cpuCount
    config.memorySize = o.memoryGB * 1024 * 1024 * 1024

    let bootLoader = VZEFIBootLoader()
    bootLoader.variableStore = ensureVariableStore(at: nvramURL)
    config.bootLoader = bootLoader

    var storage: [VZStorageDeviceConfiguration] = []
    do {
        let disk = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        storage.append(VZVirtioBlockDeviceConfiguration(attachment: disk))
    } catch {
        fail("could not attach \(diskURL.path): \(error.localizedDescription)")
    }
    if let isoPath = o.isoPath {
        let isoURL = URL(fileURLWithPath: isoPath)
        guard fm.fileExists(atPath: isoURL.path) else { fail("no such image: \(isoPath)") }
        do {
            let iso = try VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)
            storage.append(VZUSBMassStorageDeviceConfiguration(attachment: iso))
            note("attached installer image \(isoURL.lastPathComponent)")
        } catch {
            fail("could not attach \(isoPath): \(error.localizedDescription)")
        }
    }
    config.storageDevices = storage

    let network = VZVirtioNetworkDeviceConfiguration()
    network.attachment = VZNATNetworkDeviceAttachment()
    config.networkDevices = [network]

    let graphics = VZVirtioGraphicsDeviceConfiguration()
    graphics.scanouts = [
        VZVirtioGraphicsScanoutConfiguration(widthInPixels: o.width, heightInPixels: o.height)
    ]
    config.graphicsDevices = [graphics]

    config.keyboards = [VZUSBKeyboardConfiguration()]
    config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    let (serial, ptyPath) = serialPortOnPTY()
    config.serialPorts = [serial]
    // Leave the device path where the host tooling can find it.
    try? ptyPath.write(to: consoleURL.deletingLastPathComponent()
        .appendingPathComponent("serial.pty"), atomically: true, encoding: .utf8)
    drainConsole(from: ptyPath, into: consoleURL)
    note("serial console on \(ptyPath), logging to \(consoleURL.path)")

    do {
        try config.validate()
    } catch {
        fail("invalid VM configuration: \(error.localizedDescription)")
    }
    return config
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate {
    private let options: Options
    private var machine: VZVirtualMachine!
    private var window: NSWindow!

    init(options: Options) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = makeConfiguration(options)
        machine = VZVirtualMachine(configuration: config)
        machine.delegate = self

        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = true

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Omarchy — aarch64 Linux on Virtualization.framework"
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        machine.start { result in
            switch result {
            case .success:
                note("VM started — \(self.options.cpuCount) CPUs, \(self.options.memoryGB) GB RAM")
                note("serial device path saved to \(self.options.bundle.appendingPathComponent("serial.pty").path)")
            case .failure(let error):
                fail("VM failed to start: \(error.localizedDescription)")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard machine != nil, machine.canRequestStop else { return .terminateNow }
        // Ask the guest to power down cleanly rather than yanking its disk away.
        try? machine.requestStop()
        return .terminateLater
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        note("guest powered off")
        NSApp.reply(toApplicationShouldTerminate: true)
        NSApp.terminate(nil)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        note("guest stopped with an error: \(error.localizedDescription)")
        NSApp.reply(toApplicationShouldTerminate: true)
        NSApp.terminate(nil)
    }
}

let options = parseArgs()
let app = NSApplication.shared
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
