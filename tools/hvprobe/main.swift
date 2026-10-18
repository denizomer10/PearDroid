import Foundation
import Hypervisor

// Probes whether Hypervisor.framework is usable in the current process.
//
// Unlike Virtualization.framework, Hypervisor.framework gives us raw access to
// the CPU's virtualization extensions (the "OrbStack approach"): we would build
// our own small VMM and boot a minimal Linux guest on top of it. The question
// this probe answers is whether hv_vm_create / hv_vcpu_create are permitted.

func name(for result: hv_return_t) -> String {
    switch Int(result) {
    case HV_SUCCESS: return "HV_SUCCESS"
    case HV_ERROR: return "HV_ERROR"
    case HV_BUSY: return "HV_BUSY"
    case HV_BAD_ARGUMENT: return "HV_BAD_ARGUMENT"
    case HV_NO_RESOURCES: return "HV_NO_RESOURCES"
    case HV_NO_DEVICE: return "HV_NO_DEVICE"
    case HV_DENIED: return "HV_DENIED"
    case HV_UNSUPPORTED: return "HV_UNSUPPORTED"
    default: return "unknown(\(result))"
    }
}

var failed = false
func check(_ label: String, _ result: hv_return_t) -> Bool {
    let ok = result == HV_SUCCESS
    print("  \(label): \(name(for: result))")
    if !ok { failed = true }
    return ok
}

print("PearDroid: Hypervisor probe")
print("Host: \(ProcessInfo.processInfo.operatingSystemVersionString)")

print("hv_vm_create …")
guard check("hv_vm_create", hv_vm_create(nil)) else {
    print("RESULT: hypervisor NOT available")
    exit(1)
}

print("hv_vcpu_create …")
var vcpu: hv_vcpu_t = 0
var exitInfo: UnsafeMutablePointer<hv_vcpu_exit_t>? = nil
guard check("hv_vcpu_create", hv_vcpu_create(&vcpu, &exitInfo, nil)) else {
    _ = hv_vm_destroy()
    print("RESULT: hypervisor NOT available")
    exit(2)
}
print("  vcpu handle: \(vcpu)")

// Execute a tiny hand-written AArch64 program to prove the vCPU actually runs:
//   movz x0, #0x2a   ; x0 = 42
//   hvc  #0          ; trap back to the host
let code: [UInt32] = [
    0xD2800540, // movz x0, #0x2a
    0xD4000002, // hvc #0
]
let pageSize = 0x4000
let memory = UnsafeMutableRawPointer.allocate(byteCount: pageSize, alignment: pageSize)
memset(memory, 0, pageSize)
memory.copyMemory(from: code, byteCount: code.count * MemoryLayout<UInt32>.size)

var guestAddress: hv_ipa_t = 0x1000_0000
let mapFlags = hv_memory_flags_t(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)
let mapResult = hv_vm_map(memory, guestAddress, Int(pageSize), mapFlags)
_ = check("hv_vm_map", mapResult)

_ = check("hv_vcpu_set_reg(PC)", hv_vcpu_set_reg(vcpu, HV_REG_PC, guestAddress))
_ = check("hv_vcpu_set_reg(CPSR)", hv_vcpu_set_reg(vcpu, HV_REG_CPSR, 0x3c4)) // EL1h, DAIF masked

if !failed {
    print("hv_vcpu_run …")
    let runResult = hv_vcpu_run(vcpu)
    _ = check("hv_vcpu_run", runResult)

    var exitReason: UInt64 = 0
    _ = hv_vcpu_get_reg(vcpu, HV_REG_X0, &exitReason)
    print("  exit reason: \(exitInfo?.pointee.reason.rawValue ?? 0)")
    print("  x0 after run: \(exitReason) (expected 42)")
}

_ = hv_vcpu_destroy(vcpu)
_ = hv_vm_destroy()

print(failed ? "RESULT: hypervisor NOT available" : "RESULT: hypervisor AVAILABLE and executing guest code")
exit(failed ? 3 : 0)
