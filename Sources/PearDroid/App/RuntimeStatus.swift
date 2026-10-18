import Foundation
import Hypervisor

/// Reports whether the runtime layer can use **Hypervisor.framework** — the raw
/// `hv_*` API (the same approach OrbStack uses to run a custom Linux).
///
/// Unlike `Virtualization.framework`, Hypervisor.framework only needs the
/// `com.apple.security.hypervisor` entitlement, which *is* honoured for an
/// ad-hoc signed build. So this is the path PearDroid takes for its guest.
@MainActor
final class RuntimeStatus: ObservableObject {
    enum State {
        case ready
        case denied
    }

    @Published private(set) var state: State
    @Published private(set) var summary: String
    @Published private(set) var detail: String

    init() {
        if RuntimeStatus.hypervisorAvailable() {
            state = .ready
            summary = "hypervisor ready"
            detail = "Hypervisor.framework is available: guest code can execute."
        } else {
            state = .denied
            summary = "hypervisor denied"
            detail = "hv_vm_create was denied. The build must be signed with "
                + "com.apple.security.hypervisor (see docs/RUNTIME.md)."
        }
    }

    /// Attempts to create and immediately destroy a VM. `hv_vm_create` is the
    /// authoritative check: it returns `HV_SUCCESS` only when the entitlement is
    /// present and the hardware supports virtualization.
    static func hypervisorAvailable() -> Bool {
        let result = hv_vm_create(nil)
        guard Int(result) == HV_SUCCESS else { return false }
        _ = hv_vm_destroy()
        return true
    }
}
