import Foundation
import Hypervisor

// PearDroid VMM — Linux boot attempt.
//
// Extends the verified device-model core (tools/vmm) toward booting a real Linux
// guest: it maps RAM, sets up Apple's emulated GICv3, loads a kernel `Image` +
// initramfs, builds a flattened device tree, and runs a single vCPU, decoding
// MMIO faults (an emulated PL011 console) and PSCI/HVC calls.
//
// First milestone: see the kernel's early console output on our emulated UART.
//
// Usage: vmmboot <kernel-image> [initramfs] [seconds]

// MARK: - Logging

let logURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PEARDROID_LOG"] ?? "/tmp/vmmboot.log")
let consoleURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PEARDROID_CONSOLE"] ?? "/tmp/vmmboot.console")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
FileManager.default.createFile(atPath: consoleURL.path, contents: nil)
let logHandle = FileHandle(forWritingAtPath: logURL.path)
let consoleHandle = FileHandle(forWritingAtPath: consoleURL.path)

func log(_ message: String) {
    let line = Data((message + "\n").utf8)
    FileHandle.standardError.write(line)
    logHandle?.write(line)
}

// MARK: - Flattened device tree

struct FDT {
    private var structure: [UInt8] = []
    private var strings: [UInt8] = []
    private var stringOffsets: [String: UInt32] = [:]

    private mutating func align4() { while structure.count % 4 != 0 { structure.append(0) } }

    private mutating func appendBE(_ value: UInt32) {
        structure.append(UInt8((value >> 24) & 0xFF))
        structure.append(UInt8((value >> 16) & 0xFF))
        structure.append(UInt8((value >> 8) & 0xFF))
        structure.append(UInt8(value & 0xFF))
    }

    private mutating func stringOffset(_ name: String) -> UInt32 {
        if let existing = stringOffsets[name] { return existing }
        let offset = UInt32(strings.count)
        strings.append(contentsOf: name.utf8)
        strings.append(0)
        stringOffsets[name] = offset
        return offset
    }

    mutating func beginNode(_ name: String) {
        align4()
        appendBE(1) // FDT_BEGIN_NODE
        structure.append(contentsOf: name.utf8)
        structure.append(0)
        align4()
    }

    mutating func endNode() {
        align4()
        appendBE(2) // FDT_END_NODE
    }

    mutating func property(_ name: String, raw data: [UInt8]) {
        align4()
        appendBE(3) // FDT_PROP
        appendBE(UInt32(data.count))
        appendBE(stringOffset(name))
        structure.append(contentsOf: data)
        align4()
    }

    mutating func property(_ name: String, u32s values: [UInt32]) {
        var data: [UInt8] = []
        for value in values {
            data.append(UInt8((value >> 24) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        }
        property(name, raw: data)
    }

    mutating func property(_ name: String, u64s values: [UInt64]) {
        property(name, u32s: values.flatMap { [UInt32($0 >> 32), UInt32($0 & 0xFFFF_FFFF)] })
    }

    mutating func property(_ name: String, string: String) {
        var data = Array(string.utf8)
        data.append(0)
        property(name, raw: data)
    }

    mutating func propertyEmpty(_ name: String) { property(name, raw: []) }

    func build() -> [UInt8] {
        var structureBlock = structure
        structureBlock.append(contentsOf: [0, 0, 0, 9]) // FDT_END

        let headerSize = 40
        let reservation = [UInt8](repeating: 0, count: 16) // mem reservation terminator
        let offStruct = headerSize + reservation.count
        let offStrings = offStruct + structureBlock.count
        let totalSize = offStrings + strings.count

        var header: [UInt8] = []
        func appendBE(_ value: UInt32) {
            header.append(UInt8((value >> 24) & 0xFF))
            header.append(UInt8((value >> 16) & 0xFF))
            header.append(UInt8((value >> 8) & 0xFF))
            header.append(UInt8(value & 0xFF))
        }

        appendBE(0xD00D_FEED)
        appendBE(UInt32(totalSize))
        appendBE(UInt32(offStruct))
        appendBE(UInt32(offStrings))
        appendBE(UInt32(headerSize))              // off_mem_rsvmap
        appendBE(17)                              // version
        appendBE(16)                              // last_comp_version
        appendBE(0)                               // boot_cpuid_phys
        appendBE(UInt32(strings.count))           // size_dt_strings
        appendBE(UInt32(structureBlock.count))    // size_dt_struct

        return header + reservation + structureBlock + strings
    }
}

// MARK: - Layout constants

let ramBase: UInt64 = 0x4000_0000
let ramSize: UInt64 = 0x1000_0000          // 256 MiB
let kernelAddr: UInt64 = 0x4020_0000   // 2 MiB-aligned (arm64 boot protocol)
let gicDistAddr: UInt64 = 0x0800_0000
let gicRedistAddr: UInt64 = 0x080A_0000
let uartAddr: UInt64 = 0x0900_0000
let pl011Size: UInt64 = 0x1000

// MARK: - PL011 (register file, transmit routed to the console)

final class PL011 {
    private var line = ""
    private var registers: [UInt64: UInt32] = [:]

    func read(offset: UInt64) -> UInt32 {
        switch offset {
        case 0x18: return 0x90 // UARTFR: TXFE set, RXFE set, TXFF clear
        default: return registers[offset] ?? 0
        }
    }

    func write(offset: UInt64, value: UInt32) {
        if offset == 0x00 {
            emit(UInt8(value & 0xFF))
        } else {
            registers[offset] = value
        }
    }

    private func emit(_ byte: UInt8) {
        consoleHandle?.write(Data([byte]))
        if byte == 0x0A {
            log("console| \(line)")
            line = ""
        } else if byte >= 0x20 || byte == 0x09 {
            line.append(Character(UnicodeScalar(byte)))
        }
    }
}

// MARK: - Entry

let args = CommandLine.arguments
guard args.count >= 2 else {
    log("usage: vmmboot <kernel-image> [initramfs] [seconds]")
    exit(1)
}
let kernelURL = URL(fileURLWithPath: args[1])
let initrdURL = args.count >= 3 && !args[2].isEmpty ? URL(fileURLWithPath: args[2]) : nil
let seconds = args.count >= 4 ? (Double(args[3]) ?? 20) : 20

guard let kernelData = try? Data(contentsOf: kernelURL) else {
    log("cannot read kernel at \(kernelURL.path)")
    exit(1)
}
let initrdData = initrdURL.flatMap { try? Data(contentsOf: $0) }

log("kernel: \(kernelData.count) bytes")
if let initrdData { log("initramfs: \(initrdData.count) bytes") }

guard Int(hv_vm_create(nil)) == HV_SUCCESS else {
    log("hv_vm_create failed (entitlement missing?)")
    exit(1)
}
let ram = UnsafeMutableRawPointer.allocate(byteCount: Int(ramSize), alignment: 0x4000)
memset(ram, 0, Int(ramSize))
guard Int(hv_vm_map(ram, ramBase, Int(ramSize),
                    hv_memory_flags_t(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC))) == HV_SUCCESS else {
    log("hv_vm_map failed")
    exit(1)
}

// GIC (best effort) — created after the VM and before any vCPU.
var distributorSize = 0x10000
var redistributorRegionSize = 0x20000
let gicConfig = hv_gic_config_create()
_ = hv_gic_get_distributor_size(&distributorSize)
// One redistributor is two 64 KiB frames; describe only what one vCPU needs
// rather than the implementation's whole supported region.
_ = hv_gic_get_redistributor_size(&redistributorRegionSize)
_ = hv_gic_config_set_distributor_base(gicConfig, gicDistAddr)
_ = hv_gic_config_set_redistributor_base(gicConfig, gicRedistAddr)
let gicResult = hv_gic_create(gicConfig)
log("hv_gic_create -> 0x\(String(Int(gicResult), radix: 16)); dist=\(distributorSize) redist=\(redistributorRegionSize)")

// Load the kernel image.
let kernelBase = UnsafeMutableRawPointer(ram).advanced(by: Int(kernelAddr - ramBase))
_ = kernelData.withUnsafeBytes { memcpy(kernelBase, $0.baseAddress!, kernelData.count) }
log("kernel loaded at 0x\(String(kernelAddr, radix: 16))")

// Load the initramfs, 2 MiB aligned, just past the kernel.
var initrdAddr: UInt64 = 0
var initrdEnd: UInt64 = 0
if let initrdData {
    initrdAddr = (kernelAddr + UInt64(kernelData.count) + 0x1F_FFFF) & ~0x1F_FFFF
    initrdEnd = initrdAddr + UInt64(initrdData.count)
    let pointer = UnsafeMutableRawPointer(ram).advanced(by: Int(initrdAddr - ramBase))
    _ = initrdData.withUnsafeBytes { memcpy(pointer, $0.baseAddress!, initrdData.count) }
    log("initramfs at 0x\(String(initrdAddr, radix: 16))–0x\(String(initrdEnd, radix: 16))")
}

// Device tree.
var fdt = FDT()
fdt.beginNode("")
fdt.property("compatible", string: "linux,dummy-virt")
fdt.property("#address-cells", u32s: [2])
fdt.property("#size-cells", u32s: [2])
fdt.property("interrupt-parent", u32s: [1])

fdt.beginNode("chosen")
fdt.property("stdout-path", string: "/pl011@9000000")
fdt.property("bootargs", string: "console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/init loglevel=8 nokaslr")
if initrdData != nil {
    fdt.property("linux,initrd-start", u64s: [initrdAddr])
    fdt.property("linux,initrd-end", u64s: [initrdEnd])
}
fdt.endNode()

fdt.beginNode("memory@40000000")
fdt.property("device_type", string: "memory")
fdt.property("reg", u64s: [ramBase, ramSize])
fdt.endNode()

fdt.beginNode("cpus")
fdt.property("#address-cells", u32s: [1])
fdt.property("#size-cells", u32s: [0])
fdt.beginNode("cpu@0")
fdt.property("device_type", string: "cpu")
fdt.property("compatible", string: "arm,arm-v8")
fdt.property("reg", u32s: [0])
fdt.endNode()
fdt.endNode()

fdt.beginNode("timer")
fdt.property("compatible", string: "arm,armv8-timer")
fdt.propertyEmpty("always-on")
fdt.property("interrupts", u32s: [1, 13, 4, 1, 14, 4, 1, 11, 4, 1, 10, 4])
fdt.endNode()

fdt.beginNode("interrupt-controller@8000000")
fdt.property("compatible", string: "arm,gic-v3")
fdt.property("#interrupt-cells", u32s: [3])
fdt.property("#address-cells", u32s: [0])
fdt.propertyEmpty("interrupt-controller")
fdt.property("phandle", u32s: [1])
fdt.property("#redistributor-regions", u32s: [1])
fdt.property("reg", u64s: [gicDistAddr, UInt64(distributorSize), gicRedistAddr, UInt64(redistributorRegionSize)])
fdt.endNode()

fdt.beginNode("pl011@9000000")
fdt.property("compatible", string: "arm,sbsa-uart")
fdt.property("reg", u64s: [uartAddr, pl011Size])
fdt.property("interrupts", u32s: [0, 1, 4])
fdt.endNode()

fdt.beginNode("psci")
fdt.property("compatible", string: "arm,psci-1.0")
fdt.property("method", string: "hvc")
fdt.endNode()

fdt.endNode()

let dtb = fdt.build()
if let dumpPath = ProcessInfo.processInfo.environment["PEARDROID_DTB_OUT"] {
    try? Data(dtb).write(to: URL(fileURLWithPath: dumpPath))
    log("device tree dumped to \(dumpPath)")
}
let dtbAddr: UInt64 = ramBase + ramSize - 0x10_0000
let dtbPointer = UnsafeMutableRawPointer(ram).advanced(by: Int(dtbAddr - ramBase))
_ = dtb.withUnsafeBytes { memcpy(dtbPointer, $0.baseAddress!, dtb.count) }
log("device tree: \(dtb.count) bytes at 0x\(String(dtbAddr, radix: 16))")

// vCPU.
var vcpu: hv_vcpu_t = 0
var exitInfo: UnsafeMutablePointer<hv_vcpu_exit_t>? = nil
guard Int(hv_vcpu_create(&vcpu, &exitInfo, nil)) == HV_SUCCESS else {
    log("hv_vcpu_create failed")
    exit(1)
}

func getReg(_ reg: hv_reg_t) -> UInt64 {
    var value: UInt64 = 0
    _ = hv_vcpu_get_reg(vcpu, reg, &value)
    return value
}
func setReg(_ reg: hv_reg_t, _ value: UInt64) {
    _ = hv_vcpu_set_reg(vcpu, reg, value)
}
func gpRegister(_ index: UInt64) -> hv_reg_t {
    hv_reg_t(rawValue: HV_REG_X0.rawValue + UInt32(index))
}

setReg(HV_REG_CPSR, 0x3c5)      // EL1h, DAIF masked
// Apple's emulated GICv3 matches redistributors to vCPUs by MPIDR affinity, so
// expose CPU0's affinity explicitly.
var mpidr: UInt64 = 0
_ = hv_vcpu_get_sys_reg(vcpu, HV_SYS_REG_MPIDR_EL1, &mpidr)
log("MPIDR_EL1 default = 0x\(String(mpidr, radix: 16))")
_ = hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_MPIDR_EL1, 0)
// EFI-formatted arm64 images put the DOS/PE header over the arm64 header, so
// code0 (offset 0) is not a branch; code1 (offset 4) is. Allow overriding the
// entry offset to enter past the PE header.
let entryOffset = UInt64(ProcessInfo.processInfo.environment["PEARDROID_ENTRY_OFFSET"] ?? "0") ?? 0
log("entry: kernelBase+0x\(String(entryOffset, radix: 16))")
setReg(HV_REG_PC, kernelAddr + entryOffset)
setReg(gpRegister(0), dtbAddr)   // x0 = device tree

let uart = PL011()
let deadline = Date().addingTimeInterval(seconds)
var exits = 0
var running = true

// Watchdog: periodically force the vCPU to exit so we can sample where the guest
// is executing (hv_vcpu_run() blocks while the guest runs).
let scheduler = DispatchQueue(label: "peardroid.scheduler")
scheduler.async {
    var handle = vcpu
    while true {
        Thread.sleep(forTimeInterval: 3)
        _ = hv_vcpus_exit(&handle, 1)
    }
}

while running && Date() < deadline {
    exits += 1
    if exits > 5_000_000 { log("exit budget exhausted"); break }

    guard Int(hv_vcpu_run(vcpu)) == HV_SUCCESS else {
        log("hv_vcpu_run failed")
        break
    }

    let reason = exitInfo!.pointee.reason
    switch reason {
    case HV_EXIT_REASON_CANCELED:
        log("sample: PC=0x\(String(getReg(HV_REG_PC), radix: 16)) LR=0x\(String(getReg(gpRegister(30)), radix: 16)) x0=0x\(String(getReg(gpRegister(0)), radix: 16)) x1=0x\(String(getReg(gpRegister(1)), radix: 16)) x2=0x\(String(getReg(gpRegister(2)), radix: 16)) cpsr=0x\(String(getReg(HV_REG_CPSR), radix: 16))")

    case HV_EXIT_REASON_EXCEPTION:
        let syndrome = exitInfo!.pointee.exception.syndrome
        let ec = (syndrome >> 26) & 0x3F

        if ec == 0x16 { // HVC — PSCI
            let function = getReg(gpRegister(0))
            switch function {
            case 0x8400_0000: setReg(gpRegister(0), 0x0001_0001)
            case 0x8400_0008, 0x8400_0009:
                log("PSCI: power off")
                running = false
            case 0x8400_0003: setReg(gpRegister(0), 0)
            default: setReg(gpRegister(0), 0xFFFF_FFFF_FFFF_FFFF)
            }
        } else if ec == 0x24 { // data abort — MMIO
            let ipa = exitInfo!.pointee.exception.physical_address
            let isWrite = (syndrome & (1 << 6)) != 0
            let register = (syndrome >> 16) & 0x1F

            if ipa >= uartAddr && ipa < uartAddr + pl011Size {
                let offset = ipa - uartAddr
                if isWrite {
                    uart.write(offset: offset, value: UInt32(truncatingIfNeeded: getReg(gpRegister(register))))
                } else {
                    setReg(gpRegister(register), UInt64(uart.read(offset: offset)))
                }
            } else {
                if isWrite {
                    // dropped
                } else {
                    setReg(gpRegister(register), 0)
                }
                if exits < 30 {
                    log("mmio \(isWrite ? "w" : "r") @ 0x\(String(ipa, radix: 16))")
                }
            }
            setReg(HV_REG_PC, getReg(HV_REG_PC) + 4)
        } else if ec == 0x18 { // trapped MSR/MRS (e.g. debug/trace registers like OSLAR_EL1)
            let isRead = (syndrome & 1) != 0
            let rt = (syndrome >> 16) & 0x1F
            if isRead, rt < 31 { setReg(gpRegister(rt), 0) }
            if exits < 10 { log("trapped sysreg (skipped) PC=0x\(String(getReg(HV_REG_PC), radix: 16))") }
            setReg(HV_REG_PC, getReg(HV_REG_PC) + 4)
        } else {
            log("unhandled exception EC=0x\(String(ec, radix: 16)) PC=0x\(String(getReg(HV_REG_PC), radix: 16)) ESR=0x\(String(syndrome, radix: 16))")
            running = false
        }

    case HV_EXIT_REASON_VTIMER_ACTIVATED:
        // The architected virtual timer fired: make its PPI pending in the GIC and
        // clear the vtimer mask so further timer interrupts are delivered.
        _ = hv_gic_set_redistributor_reg(vcpu, HV_GIC_REDISTRIBUTOR_REG_GICR_ISPENDR0,
                                         UInt64(1) << UInt64(HV_GIC_INT_EL1_VIRTUAL_TIMER.rawValue))
        _ = hv_vcpu_set_vtimer_mask(vcpu, false)

    default:
        log("exit reason \(reason.rawValue)")
        running = false
    }
}

log("exits handled: \(exits); still running: \(running)")
_ = hv_vcpu_destroy(vcpu)
_ = hv_vm_destroy()
_ = munmap(ram, Int(ramSize))
log("vmmboot finished")
exit(0)
