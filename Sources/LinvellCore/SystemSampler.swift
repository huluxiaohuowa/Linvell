import Foundation
import Darwin
import IOKit

public struct SystemSnapshot {
    public let cpuLoads: [Double]?
    public let activeMemory: UInt64
    public let wiredMemory: UInt64
    public let compressedMemory: UInt64
    public let freeMemory: UInt64
    public let networkIn: Double?
    public let networkOut: Double?
    public let diskRead: Double?
    public let diskWrite: Double?
}

public final class SystemSampler {
    private struct Reading { let time: TimeInterval; let cpu: [[UInt32]]; let input: UInt64?; let output: UInt64?; let read: UInt64?; let written: UInt64? }
    private var previous: Reading?
    private let lock = NSLock()
    public init() {}
    public func sample() throws -> SystemSnapshot {
        lock.lock(); defer { lock.unlock() }
        let cpu = try cpuTicks(),network = networkBytes(),disk = diskBytes(),memory = try memoryPages()
        let now = Reading(time:ProcessInfo.processInfo.systemUptime,cpu:cpu,input:network?.0,output:network?.1,read:disk?.0,written:disk?.1)
        defer { previous = now }
        let elapsed = previous.map { now.time-$0.time } ?? 0
        let loads: [Double]? = previous.flatMap { old in
            guard old.cpu.count == cpu.count,elapsed > 0 else { return nil }
            return zip(cpu,old.cpu).map { current,before in
                let differences = zip(current,before).map { UInt64($0 &- $1) }
                let total = differences.reduce(0,+),idle = differences[Int(CPU_STATE_IDLE)]
                return total == 0 ? 0 : min(1,Double(total-idle)/Double(total))
            }
        }
        func rate(_ current: UInt64?,_ old: UInt64?) -> Double? {
            guard let current,let old,elapsed > 0,current >= old else { return nil }
            return Double(current-old)/elapsed
        }
        return SystemSnapshot(cpuLoads:loads,activeMemory:memory.0,wiredMemory:memory.1,compressedMemory:memory.2,freeMemory:memory.3,
                              networkIn:rate(now.input,previous?.input),networkOut:rate(now.output,previous?.output),diskRead:rate(now.read,previous?.read),diskWrite:rate(now.written,previous?.written))
    }
    private func cpuTicks() throws -> [[UInt32]] {
        var count: natural_t = 0,info: processor_info_array_t?,length: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(),PROCESSOR_CPU_LOAD_INFO,&count,&info,&length)
        guard result == KERN_SUCCESS,let info else { throw NSError(domain:NSMachErrorDomain,code:Int(result)) }
        defer { vm_deallocate(mach_task_self_,vm_address_t(UInt(bitPattern:info)),vm_size_t(length)*vm_size_t(MemoryLayout<integer_t>.stride)) }
        return (0..<Int(count)).map { core in (0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern:info[core*Int(CPU_STATE_MAX)+$0]) } }
    }
    private func memoryPages() throws -> (UInt64,UInt64,UInt64,UInt64) {
        var value = vm_statistics64_data_t(),count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size/MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to:&value) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { host_statistics64(mach_host_self(),HOST_VM_INFO64,$0,&count) }
        }
        guard result == KERN_SUCCESS else { throw NSError(domain:NSMachErrorDomain,code:Int(result)) }
        var page: vm_size_t = 0; host_page_size(mach_host_self(),&page)
        return (UInt64(value.active_count)*UInt64(page),UInt64(value.wire_count)*UInt64(page),UInt64(value.compressor_page_count)*UInt64(page),UInt64(value.free_count)*UInt64(page))
    }
    private func networkBytes() -> (UInt64,UInt64)? {
        // NET_RT_IFLIST2 exposes 64-bit counters; only physical en* interfaces are counted.
        var names: [Int32] = [CTL_NET,PF_ROUTE,0,AF_UNSPEC,NET_RT_IFLIST2,0],size = 0
        guard sysctl(&names,u_int(names.count),nil,&size,nil,0) == 0,size > 0 else { return nil }
        var data = Data(count:size)
        let result = data.withUnsafeMutableBytes { sysctl(&names,u_int(names.count),$0.baseAddress,&size,nil,0) }
        guard result == 0 else { return nil }
        return data.withUnsafeBytes { raw -> (UInt64,UInt64)? in
            var offset = 0,input: UInt64 = 0,output: UInt64 = 0,found = false
            while offset+MemoryLayout<if_msghdr2>.size <= size {
                let header = raw.loadUnaligned(fromByteOffset:offset,as:if_msghdr2.self),length = Int(header.ifm_msglen)
                guard length > 0,offset+length <= size else { break }
                if header.ifm_type == RTM_IFINFO2 {
                    var name = [CChar](repeating:0,count:Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(header.ifm_index),&name) != nil,String(cString:name).hasPrefix("en") {
                        found = true
                        input += header.ifm_data.ifi_ibytes; output += header.ifm_data.ifi_obytes
                    }
                }
                offset += length
            }
            return found ? (input,output) : nil
        }
    }
    private func diskBytes() -> (UInt64,UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOBlockStorageDriver"),&iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0,written: UInt64 = 0,found = false
        while true {
            let service = IOIteratorNext(iterator); if service == 0 { break }
            defer { IOObjectRelease(service) }
            if let statistics = IORegistryEntryCreateCFProperty(service,"Statistics" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? [String:Any],
               let reads = statistics["Bytes (Read)"] as? NSNumber,let writes = statistics["Bytes (Write)"] as? NSNumber {
                found = true
                read += reads.uint64Value; written += writes.uint64Value
            }
        }
        return found ? (read,written) : nil
    }
}
