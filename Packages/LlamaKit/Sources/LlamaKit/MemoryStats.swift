import Foundation
import os

/// What the OS counts against the app (phys_footprint) and, on iOS, how much more it will allow
/// before jetsam kills the app.
public enum MemoryStats {
    public static var footprintBytes: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return rc == KERN_SUCCESS ? info.phys_footprint : 0
    }

    public static var availableBytes: UInt64? {
        #if os(iOS)
        UInt64(os_proc_available_memory())
        #else
        nil
        #endif
    }

    public static var deviceBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }

    public static func gb(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
}
