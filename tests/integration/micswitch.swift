// Switches the default input device away and back, the way AirPods do when a call app takes the
// mic, so a running recorder sees a real configuration change. The other device is a temporary
// aggregate made of the current input only (same mic, nothing else), removed afterwards, and the
// original default input is always put back.
// With "vanish" the temporary device stays the default input and its input disappears and comes
// back instead (its member swaps between the mic and the default output, which has no input), as
// AirPods' input does for a moment while they switch into call mode.
// usage: micswitch <switches> <seconds between switches> [vanish]
//        micswitch restore    (only puts a default input back if an earlier run was interrupted)
import CoreAudio
import Foundation

let system = AudioObjectID(kAudioObjectSystemObject)
let name = "grandma-test-mic"

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func defaultInput() -> AudioDeviceID {
    var a = address(kAudioHardwarePropertyDefaultInputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id)
    return id
}

func setDefaultInput(_ id: AudioDeviceID) {
    var a = address(kAudioHardwarePropertyDefaultInputDevice)
    var v = id
    AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &v)
}

func uid(_ id: AudioDeviceID) -> String {
    var a = address(kAudioDevicePropertyDeviceUID)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value)
    return value?.takeRetainedValue() as String? ?? ""
}

func devices() -> [AudioDeviceID] {
    var a = address(kAudioHardwarePropertyDevices)
    var size = UInt32(0)
    AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids)
    return ids
}

/// Leftover test aggregates from an interrupted run.
func leftovers() -> [AudioDeviceID] { devices().filter { uid($0).hasPrefix(name) } }

func waitForDefault(_ id: AudioDeviceID) {
    for _ in 0..<40 where defaultInput() != id { Thread.sleep(forTimeInterval: 0.05) }
}

let args = CommandLine.arguments
let stateFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).original")

if args.count > 1 && args[1] == "restore" {
    if let saved = try? String(contentsOf: stateFile, encoding: .utf8),
       let original = devices().first(where: { uid($0) == saved }), leftovers().contains(defaultInput()) {
        setDefaultInput(original)
        waitForDefault(original)
    }
    for id in leftovers() { AudioHardwareDestroyAggregateDevice(id) }
    try? FileManager.default.removeItem(at: stateFile)
    print("{\"restored\": true}")
    exit(0)
}

let began = Date()
let switches = args.count > 1 ? Int(args[1]) ?? 4 : 4
let gap = args.count > 2 ? Double(args[2]) ?? 0.5 : 0.5
let original = defaultInput()
let originalUID = uid(original)
let vanish = args.count > 3 && args[3] == "vanish"

func defaultOutput() -> AudioDeviceID {
    var a = address(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id)
    return id
}

func setMembers(_ device: AudioDeviceID, _ uids: [String]) {
    var a = address(kAudioAggregateDevicePropertyFullSubDeviceList)
    var list = uids as CFArray
    AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<CFArray>.size), &list)
}

func inputChannels(_ device: AudioDeviceID) -> Int {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                       mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { list.deallocate() }
    guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, list) == noErr else { return 0 }
    let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
}
try? originalUID.write(to: stateFile, atomically: true, encoding: .utf8)

let description: [String: Any] = [
    kAudioAggregateDeviceNameKey: name,
    kAudioAggregateDeviceUIDKey: "\(name)-\(UUID().uuidString)",
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: originalUID]],
    kAudioAggregateDeviceMainSubDeviceKey: originalUID,
]
var aggregate = AudioDeviceID(0)
let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
guard status == noErr else {
    print("{\"error\": \"could not create the test device (\(status))\"}")
    exit(1)
}
Thread.sleep(forTimeInterval: 0.5) // a new device takes a moment to appear
var reached = 0
if vanish {
    setDefaultInput(aggregate)
    waitForDefault(aggregate)
    Thread.sleep(forTimeInterval: gap)
    let output = uid(defaultOutput())
    for i in 0..<switches {
        let empty = i % 2 == 0
        setMembers(aggregate, [empty ? output : originalUID])
        for _ in 0..<40 where (inputChannels(aggregate) == 0) != empty { Thread.sleep(forTimeInterval: 0.05) }
        if (inputChannels(aggregate) == 0) == empty { reached += 1 }
        Thread.sleep(forTimeInterval: gap)
    }
    setMembers(aggregate, [originalUID])
} else {
    for i in 0..<switches {
        let target = i % 2 == 0 ? aggregate : original
        setDefaultInput(target)
        waitForDefault(target)
        if defaultInput() == target { reached += 1 }
        Thread.sleep(forTimeInterval: gap)
    }
}
setDefaultInput(original)
waitForDefault(original)
AudioHardwareDestroyAggregateDevice(aggregate)
try? FileManager.default.removeItem(at: stateFile)
print(String(format: "{\"switches\": %d, \"reached\": %d, \"vanish\": %@, \"restored\": %@, \"seconds\": %.2f}",
             switches, reached, vanish ? "true" : "false", defaultInput() == original ? "true" : "false",
             Date().timeIntervalSince(began)))
