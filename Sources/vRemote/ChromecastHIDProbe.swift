import Foundation
import IOKit.hid
enum ChromecastHIDProbe {
 static func run() {
func log(_ s: String) { Swift.print(s); fflush(stdout) }
log("ACCESS=\(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue)")
let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x18D1, kIOHIDProductIDKey: 0x9450] as CFDictionary)
IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, result, _, device in
    log("MATCH result=\(result) product=\(String(describing: IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString)))")
}, nil)
IOHIDManagerRegisterInputReportCallback(manager, { _, result, _, _, id, ptr, count in
    log("REPORT result=\(result) id=\(id) bytes=\(Data(bytes:ptr,count:count).map { String(format:"%02X",$0) }.joined(separator:" "))")
}, nil)
IOHIDManagerRegisterInputValueCallback(manager, { _, result, _, value in
    let e = IOHIDValueGetElement(value)
    log("VALUE result=\(result) page=\(IOHIDElementGetUsagePage(e)) usage=\(IOHIDElementGetUsage(e)) value=\(IOHIDValueGetIntegerValue(value))")
}, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
log("OPEN=\(String(format:"0x%08X",UInt32(bitPattern:status))) uid=\(getuid())")
CFRunLoopRunInMode(.defaultMode, 30, false)
IOHIDManagerClose(manager,0)
log("DONE")
 }
}
