//
// blescan -- hear BLE advertisers from a radio that is not the board's.
//
//	swift tools/bt/blescan.swift [seconds]
//
// This exists because "advertise on" read back from /net/bt/0/state is
// the board agreeing with itself.  Whether anything is actually on the
// air is a question only another radio can answer, and the answer has
// to be falsifiable: turn the board's advertising off and its name must
// stop appearing here.  It did -- "inferno" at -62dBm with advertising
// on, absent from fifteen advertisers heard with it off.
//
// macOS only, and it needs Bluetooth permission for the terminal the
// first time; a run that hears nothing at all and prints state 5 is
// usually that permission and not a quiet room.
//
import CoreBluetooth

// Scan for BLE advertisers and print what is heard.  Used to check, from
// a radio that is not the Pi's, that the Pi is really on the air -- a
// readback of "advertise on" from the board's own controller is the
// board agreeing with itself.
final class Scanner: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!
    var seen = [String: Int]()
    func start() { central = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        FileHandle.standardError.write("state \(c.state.rawValue)\n".data(using: .utf8)!)
        if c.state == .poweredOn { c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]) }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData d: [String: Any], rssi: NSNumber) {
        let name = p.name ?? (d[CBAdvertisementDataLocalNameKey] as? String) ?? "-"
        let key = "\(p.identifier) \(name)"
        if seen[key] == nil { seen[key] = rssi.intValue
            print("\(p.identifier)  rssi \(rssi)  name \(name)  \(d.keys.sorted().joined(separator: ","))") }
    }
}
let s = Scanner(); s.start()
RunLoop.main.run(until: Date().addingTimeInterval(20))
print("--- \(s.seen.count) advertisers heard")
