import Foundation
import Hypervisor

// A minimal VMM on top of Hypervisor.framework.
//
// This is the device-model core of the PearDroid runtime: it runs guest AArch64
// code, decodes the exceptions the guest raises (data aborts to unmapped MMIO
// and HVC/PSCI calls) and emulates the devices behind them. A Linux boot is
// "just" more device emulation (a device tree, GIC — which the OS provides —
// and virtio) on top of exactly this loop.
//
// The guest program here writes a string to an emulated PL011 UART and then
// powers the machine off via PSCI, which exercises both paths.

// MARK: - Tiny AArch64 instruction encoder (keeps the guest program readable)

func movz(_ rd: UInt32, _ imm: UInt16, shift: UInt32 = 0, is64: Bool = false) -> UInt32 {
    let base: UInt32 = is64 ? 0xD280_0000 : 0x5280_0000
    return base | ((shift / 16) << 21) | (UInt32(imm) << 5) | rd
}

func movk(_ rd: UInt32, _ imm: UInt16, shift: UInt32 = 0, is64: Bool = true) -> UInt32 {
    let base: UInt32 = 0xF280_0000
    return base | ((shift / 16) << 21) | (UInt32(imm) << 5) | rd
}

func strb(_ rt: UInt32, _ rn: UInt32, offset: UInt32 = 0) -> UInt32 {
    0x3900_0000 | ((offset & 0xFFF) << 10) | (rn << 5) | rt
}

func hvc(_ imm: UInt16 = 0) -> UInt32 {
    0xD400_0002 | (UInt32(imm) << 5)
}

// MARK: - Logging

let logURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PEARDROID_LOG"] ?? "/tmp/vmm.log")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logHandle = FileHandle(forWritingAtPath: logURL.path)

func log(_ message: String) {
    let line = Data((message + "\n").utf8)
    FileHandle.standardError.write(line)
    logHandle?.write(line)
}

// MARK: - Constants

let ramSize = 64 * 1024 * 1024
let ramBase: hv_ipa_t = 0x4000_0000
let kernelEntry: hv_ipa_t = ramBase + 0x8_0000
let uartBase: hv_ipa_t = 0x0900_0000

enum PSCI {
    static let version: UInt64 = 0x8400_0000
    static let cpuOn: UInt64 = 0x8400_0003
    static let systemOff: UInt64 = 0x8400_0008
    static let systemReset: UInt64 = 0x8400_0009
    static let notSupported: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
}

enum ESR {
    static let ecShift = 26
    static let hvcAArch64: UInt64 = 0x16
    static let dataAbortLowerEL: UInt64 = 0x24
    static let isv: UInt64 = 1 << 24
    static let sasShift = 22
    static let srtShift = 16
    static let sf: UInt64 = 1 << 15
    static let wnr: UInt64 = 1 << 6
}

// MARK: - Guest program

func buildGuestProgram() -> [UInt32] {
    var code: [UInt32] = []

    // x1 = UART base (0x0900_0000)
    code.append(movz(1, 0x0900, shift: 16, is64: true))

    // Write "PEARDROID VMM OK\n" one byte at a time via strb w0, [x1].
    let message = Array("PearDroid VMM: guest code is running.\n".utf8)
    for byte in message {
        code.append(movz(0, UInt16(byte), is64: false)) // w0 = char
        code.append(strb(0, 1))                        // strb w0, [x1]
    }

    // x0 = PSCI SYSTEM_OFF (0x8400_0008)
    code.append(movz(0, 0x0008, is64: true))
    code.append(movk(0, 0x8400, shift: 16, is64: true))
    code.append(hvc(0))

    // Safety net: infinite loop if PSCI didn't stop us.
    code.append(0x1400_0000) // b .
    return code
}

// MARK: - Emulated PL011 UART (write side only)

final class PL011 {
    private var line = ""
    func write(byte: UInt8) {
        if byte == 0x0A {
            log("uart> \(line)")
            line = ""
        } else if byte >= 0x20 || byte == 0x09 {
            line.append(Character(UnicodeScalar(byte)))
        }
    }
}

// MARK: - Register helpers

func getReg(_ vcpu: hv_vcpu_t, _ reg: hv_reg_t) -> UInt64 {
    var value: UInt64 = 0
    _ = hv_vcpu_get_reg(vcpu, reg, &value)
    return value
}

func setReg(_ vcpu: hv_vcpu_t, _ reg: hv_reg_t, _ value: UInt64) {
    _ = hv_vcpu_set_reg(vcpu, reg, value)
}

func gpRegister(_ index: UInt64) -> hv_reg_t {
    // HV_REG_X0..X30 are contiguous starting at HV_REG_X0.
    hv_reg_t(rawValue: HV_REG_X0.rawValue + UInt32(index))
}

// MARK: - Main

log("PearDroid VMM starting")

guard Int(hv_vm_create(nil)) == HV_SUCCESS else {
    log("hv_vm_create failed — missing com.apple.security.hypervisor entitlement?")
    exit(1)
}

let ram = UnsafeMutableRawPointer.allocate(byteCount: ramSize, alignment: 0x4000)
memset(ram, 0, ramSize)
guard Int(hv_vm_map(ram, ramBase, ramSize,
                    hv_memory_flags_t(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC))) == HV_SUCCESS else {
    log("hv_vm_map failed")
    exit(1)
}

let program = buildGuestProgram()
_ = memcpy(UnsafeMutableRawPointer(ram).advanced(by: Int(kernelEntry - ramBase)),
           program, program.count * MemoryLayout<UInt32>.size)
log("loaded \(program.count) guest instructions at 0x\(String(kernelEntry, radix: 16))")

var vcpu: hv_vcpu_t = 0
var exitInfo: UnsafeMutablePointer<hv_vcpu_exit_t>? = nil
guard Int(hv_vcpu_create(&vcpu, &exitInfo, nil)) == HV_SUCCESS else {
    log("hv_vcpu_create failed")
    exit(1)
}

// Guest runs at EL1h with interrupts masked.
setReg(vcpu, HV_REG_CPSR, 0x3c4)
setReg(vcpu, HV_REG_PC, kernelEntry)

let uart = PL011()
var running = true
var iterations = 0

while running {
    iterations += 1
    if iterations > 100_000 {
        log("too many exits — stopping")
        break
    }

    let runResult = hv_vcpu_run(vcpu)
    guard Int(runResult) == HV_SUCCESS else {
        log("hv_vcpu_run failed: \(runResult)")
        break
    }

    let reason = exitInfo!.pointee.reason
    switch reason {
    case HV_EXIT_REASON_EXCEPTION:
        let syndrome = exitInfo!.pointee.exception.syndrome
        let ec = (syndrome >> ESR.ecShift) & 0x3F

        if ec == ESR.hvcAArch64 {
            let function = getReg(vcpu, gpRegister(0))
            switch function {
            case PSCI.version:
                setReg(vcpu, gpRegister(0), 0x0001_0001)
            case PSCI.systemOff, PSCI.systemReset:
                log("PSCI: power off requested")
                running = false
            case PSCI.cpuOn:
                setReg(vcpu, gpRegister(0), 0) // pretend the CPU came up
            default:
                setReg(vcpu, gpRegister(0), PSCI.notSupported)
            }
        } else if ec == ESR.dataAbortLowerEL {
            let ipa = exitInfo!.pointee.exception.physical_address
            let isWrite = (syndrome & ESR.wnr) != 0
            let size = (syndrome >> ESR.sasShift) & 0x3
            let register = (syndrome >> ESR.srtShift) & 0x1F
            _ = size

            if ipa >= uartBase && ipa < uartBase + 0x1000 {
                if isWrite {
                    let value = getReg(vcpu, gpRegister(register))
                    uart.write(byte: UInt8(value & 0xFF))
                } else {
                    setReg(vcpu, gpRegister(register), 0)
                }
                // The faulting instruction did not execute — skip it.
                setReg(vcpu, HV_REG_PC, getReg(vcpu, HV_REG_PC) + 4)
            } else {
                log("unhandled MMIO \(isWrite ? "write" : "read") size=\(size) @ 0x\(String(ipa, radix: 16))")
                running = false
            }
        } else {
            log("unhandled exception EC=0x\(String(ec, radix: 16)) at PC=0x\(String(getReg(vcpu, HV_REG_PC), radix: 16))")
            running = false
        }

    case HV_EXIT_REASON_VTIMER_ACTIVATED:
        // Later: turn this into a guest interrupt via the GIC.
        _ = hv_vcpu_set_vtimer_mask(vcpu, false)

    case HV_EXIT_REASON_CANCELED:
        running = false

    default:
        log("exit reason \(reason.rawValue) — stopping")
        running = false
    }
}

log("guest exits handled: \(iterations)")
_ = hv_vcpu_destroy(vcpu)
_ = hv_vm_destroy()
_ = munmap(ram, ramSize)
log("PearDroid VMM finished")
exit(0)
