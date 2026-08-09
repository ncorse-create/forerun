// Spike B probe. Read-only. Run with:  swift scripts/eventkit-probe.swift
// Prints the calendar inventory this Mac's account exposes to EventKit, which is the same
// account surface the iPhone app sees. Grants nothing, writes nothing.
import Foundation
import EventKit
import AppKit

func hsbFamily(_ cg: CGColor) -> String {
    guard let rgb = cg.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 intent: .defaultIntent, options: nil),
          let c = rgb.components, c.count >= 3 else { return "unknown" }
    let ns = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    if s < 0.15 { return "gray" }
    let deg = h * 360
    switch deg {
    case 345...360, 0..<16: return "red"
    case 16..<46:  return "orange"
    case 46..<66:  return "yellow"
    case 66..<166: return "green"
    case 166..<256: return "blue"
    case 256..<291: return "purple"
    default: return "pink"
    }
}

let store = EKEventStore()
let sem = DispatchSemaphore(value: 0)
var granted = false
store.requestFullAccessToEvents { ok, err in
    granted = ok
    if let err { print("auth error: \(err)") }
    sem.signal()
}
_ = sem.wait(timeout: .now() + 45)
print("granted: \(granted)  status: \(EKEventStore.authorizationStatus(for: .event).rawValue)")
guard granted else { print("DENIED — grant Calendar access to your terminal in System Settings > Privacy"); exit(1) }

let cals = store.calendars(for: .event)
print("\ncalendars: \(cals.count)")
print(String(format: "%-34@ %-14@ %-10@ %-8@ %@", "TITLE" as NSString, "SOURCE" as NSString,
             "TYPE" as NSString, "MUTABLE" as NSString, "COLORFAMILY"))
for c in cals.sorted(by: { $0.title < $1.title }) {
    let type: String
    switch c.type {
    case .local: type = "local"
    case .calDAV: type = "calDAV"
    case .exchange: type = "exchange"
    case .subscription: type = "subscribed"
    case .birthday: type = "birthday"
    @unknown default: type = "other"
    }
    let fam = c.cgColor.map(hsbFamily) ?? "NIL_CGCOLOR"
    print(String(format: "%-34@ %-14@ %-10@ %-8@ %@",
                 c.title as NSString, c.source.title as NSString, type as NSString,
                 (c.allowsContentModifications ? "yes" : "no") as NSString, fam as NSString))
}

let now = Date()
let end = Calendar.current.date(byAdding: .day, value: 60, to: now)!
let pred = store.predicateForEvents(withStart: now, end: end, calendars: nil)
let events = store.events(matching: pred)
print("\nevents in next 60d: \(events.count)")
var recurringSeen: [String: Int] = [:]
for e in events { if e.hasRecurrenceRules { recurringSeen[e.eventIdentifier ?? "?", default: 0] += 1 } }
let dupes = recurringSeen.filter { $0.value > 1 }
print("recurring series sharing one eventIdentifier across occurrences: \(dupes.count)")
if let sample = dupes.first {
    print("  e.g. identifier \(sample.key.prefix(24))… appears \(sample.value)× → composite sourceID is REQUIRED")
}
let allDay = events.filter(\.isAllDay).count
print("all-day events: \(allDay)")
print("events with nil eventIdentifier: \(events.filter { $0.eventIdentifier == nil }.count)")
