import Foundation
import Virtualization

// Headless Linux boot probe for PearDroid.
//
// Boots a kernel + initramfs under Virtualization.framework with a virtio serial
// console. Console output is written to a file so it can be inspected even when
// the process is launched by LaunchServices.
//
// Usage: vmprobe <kernel> [initramfs]

let logURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PEARDROID_LOG"] ?? "/tmp/vmprobe.log")
let consoleURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PEARDROID_CONSOLE"] ?? "/tmp/vmprobe.console")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
FileManager.default.createFile(atPath: consoleURL.path, contents: nil)
let logHandle = FileHandle(forWritingAtPath: logURL.path)
let consoleHandle = FileHandle(forWritingAtPath: consoleURL.path)

func log(_ message: String) {
    let line = Data(("PearDroid: " + message + "\n").utf8)
    FileHandle.standardError.write(line)
    logHandle?.write(line)
}

final class VMDelegate: NSObject, VZVirtualMachineDelegate {
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        log("VM stopped with error: \(error)")
        exit(2)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        log("VM guest stopped.")
        exit(0)
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: vmprobe <kernel> [initramfs]\n".utf8))
    exit(1)
}

let kernelURL = URL(fileURLWithPath: arguments[1])
let initrdURL = arguments.count >= 3 ? URL(fileURLWithPath: arguments[2]) : nil

let configuration = VZVirtualMachineConfiguration()

let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
if let initrdURL, FileManager.default.fileExists(atPath: initrdURL.path) {
    bootLoader.initialRamdiskURL = initrdURL
}
bootLoader.commandLine = "console=hvc0"
configuration.bootLoader = bootLoader

configuration.cpuCount = 2
configuration.memorySize = 512 * 1024 * 1024

let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
serialPort.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil,
                                                         fileHandleForWriting: consoleHandle!)
configuration.serialPorts = [serialPort]

do {
    try configuration.validate()
    log("VM configuration valid")
} catch {
    log("configuration invalid: \(error)")
    exit(1)
}

// All VZVirtualMachine API calls must happen on the queue the machine was
// created with — including start().
let vmQueue = DispatchQueue(label: "peardroid.vm")
let virtualMachine = VZVirtualMachine(configuration: configuration, queue: vmQueue)
let delegate = VMDelegate()
virtualMachine.delegate = delegate

log("starting VM…")
vmQueue.async {
    virtualMachine.start { result in
        switch result {
        case .success:
            log("VM started (state=\(virtualMachine.state.rawValue))")
        case .failure(let error):
            log("VM failed to start: \(error)")
            exit(1)
        }
    }
}

let seconds = Double(ProcessInfo.processInfo.environment["PEARDROID_SECONDS"] ?? "") ?? 15
RunLoop.main.run(until: Date().addingTimeInterval(seconds))

vmQueue.sync {
    log("probe finished (running: \(virtualMachine.state == .running))")
}
try? logHandle?.synchronize()
try? consoleHandle?.synchronize()
exit(0)
