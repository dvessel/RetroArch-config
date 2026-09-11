#!/usr/bin/env swift

import Foundation
import AppKit

// Tuning knobs (mirrors the old screenhz-match script).
// MAX_DEVIATION_PP10k = max allowed relative deviation in parts-per-10,000
//    10 -> 0.0001% (very strict) | 500 -> 0.005%
// HARMONICS = sub-multiples of each fixed rate to also check (rate / N).
// Both are overridable on the command line via --tolerance / --no-harmonics.
let MAX_DEVIATION_PP10k = 500 // 0.005%
let HARMONICS: [Int] = [2, 3, 4]
// Scale a Hz value to a fixed-point integer to avoid floating-point drift
// (e.g. 59.94 -> 59940000). Integer arithmetic keeps the comparison exact.
let SCALE = 1_000_000

// Cap on the display buffer we request from CoreGraphics.
let MAX_DISPLAYS = 16
// Minimum window dimensions to consider a window "real" (filters panels, etc.)
let MIN_WINDOW_WIDTH = 100
let MIN_WINDOW_HEIGHT = 100

struct WindowInfo {
  let appName: String
  let bounds: CGRect
}

struct ScreenInfo {
  let serial: UInt32
  let id: CGDirectDisplayID
  let mode: CGDisplayMode
  let modes: [CGDisplayMode]
}

func printError(_ message: String) {
  FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}
func printOutput(_ message: String) {
  FileHandle.standardOutput.write((message + "\n").data(using: .utf8)!)
}

func decimalToScaled(_ raw: Double) -> Int {
  // Guard against overflow for extreme values
  guard raw.isFinite, raw > 0, raw < 100000 else { return 0 }
  return Int((raw * Double(SCALE)).rounded())
}
// For each supported fixed rate, the display can also produce its integer
// sub-multiples (a 60 Hz panel emulates 30, 20, 15 Hz, ...). We score each
// fixed rate by how close any of its sub-multiples is to `requested`, then
// pick the best. Ties are broken toward the lower fixed rate, so a real
// 60 Hz mode beats the 120 Hz mode's 120/2 harmonic.
func matchRefreshRate(
  requested: Double,
  rates: [Double],
  maxDeviation: Int = MAX_DEVIATION_PP10k,
  harmonics: [Int] = HARMONICS
) -> Double? {
  let target = decimalToScaled(requested)
  guard target > 0 else { return nil }

  var best = (rate: 0, deviation: maxDeviation)

  for rate in rates {
    let srate = decimalToScaled(rate)
    guard srate > 0 else { continue }

    // The set of effective refresh rates this fixed mode can produce.
    var effective = [srate]
    for n in harmonics where srate / n > 0 {
      effective.append(srate / n)
    }
    // Best (closest) sub-multiple for this fixed rate.
    guard let closest = effective.min(by: {
      abs(target - $0) * 10000 / $0 < abs(target - $1) * 10000 / $1
    }) else { continue }
    let pp = abs(target - closest) * 10000 / closest

    // Keep the best; break ties by lower fixed rate.
    if pp < best.deviation || (pp == best.deviation && srate < best.rate) {
      best = (rate: srate, deviation: pp)
    }
  }

  guard best.rate > 0 else { return nil }
  return Double(best.rate) / Double(SCALE)
}

// Resolve an arbitrary requested rate to a concrete rate to apply: the
// closest supported fixed rate, or the VRR max (fallback) if none is
// within tolerance.
func resolveRate(
  requested: Double,
  rates: [Double],
  vrrFallback: Double,
  maxDeviation: Int = MAX_DEVIATION_PP10k,
  harmonics: [Int] = HARMONICS
) -> Double {
  return matchRefreshRate(
    requested: requested,
    rates: rates,
    maxDeviation: maxDeviation,
    harmonics: harmonics
  ) ?? vrrFallback
}

func setRefreshRate(displayID: CGDirectDisplayID, displayModes: [CGDisplayMode], rate: Double) -> Bool {
  let target = decimalToScaled(rate)
  guard
    let targetMode = displayModes.first(where: { decimalToScaled($0.refreshRate) == target })
  else {
    return false
  }
  return CGDisplaySetDisplayMode(displayID, targetMode, nil) == .success
}

func getScreenInfo(displayID: CGDirectDisplayID) -> ScreenInfo? {
  guard let activeMode = CGDisplayCopyDisplayMode(displayID) else {
    return nil
  }
  // Filter out non-matching resolutions, all we care about are the modes with
  // variations in refresh rates.
  let filteredModes = (CGDisplayCopyAllDisplayModes(
    displayID,
    // HiDPI modes (Retina) ignored without this:
    [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!] as CFDictionary
  ) as? [CGDisplayMode] ?? []).filter { mode in
    mode.width  == CGDisplayPixelsWide(displayID) &&
    mode.height == CGDisplayPixelsHigh(displayID)
  }
  return ScreenInfo(
    serial: CGDisplaySerialNumber(displayID),
    id: displayID,
    mode: activeMode,
    modes: filteredModes
  )
}

func getScreenForAppWindow(window: WindowInfo) -> ScreenInfo? {
  var displayIDs = [CGDirectDisplayID](repeating: 0, count: 1)
  CGGetDisplaysWithRect(window.bounds, 1, &displayIDs, nil)
  guard let displayID = displayIDs.first else {
    return nil
  }
  return getScreenInfo(displayID: displayID)
}

func getScreenForSerialNumber(serial: UInt32, displayID: UInt32?) -> ScreenInfo? {
  var allDisplays = [CGDirectDisplayID](repeating: 0, count: MAX_DISPLAYS)
  var count: UInt32 = 0
  CGGetActiveDisplayList(UInt32(MAX_DISPLAYS), &allDisplays, &count)
  allDisplays = Array(allDisplays.prefix(Int(count)))

  for display in allDisplays where CGDisplaySerialNumber(display) == serial {
    if let displayID = displayID, display != displayID {
      continue
    }
    return getScreenInfo(displayID: display)
  }
  return nil
}

func getAppWindows(appName: String) -> [WindowInfo] {
  guard
    let windowList = CGWindowListCopyWindowInfo(.excludeDesktopElements, kCGNullWindowID) as? [[String: Any]]
  else {
    return []
  }
  return windowList.compactMap { window in
    guard
      let ownerName = window[kCGWindowOwnerName as String] as? String,
      ownerName == appName,
      let boundsDict = window[kCGWindowBounds as String] as? [String: Any]
    else {
      return nil
    }
    // Use CGFloat conversion more safely
    let x = boundsDict["X"] as? CGFloat ?? 0
    let y = boundsDict["Y"] as? CGFloat ?? 0
    let width = boundsDict["Width"] as? CGFloat ?? 0
    let height = boundsDict["Height"] as? CGFloat ?? 0
    guard width > CGFloat(MIN_WINDOW_WIDTH), height > CGFloat(MIN_WINDOW_HEIGHT) else {
      return nil
    }
    return WindowInfo(
      appName: appName,
      bounds: CGRect(x: x, y: y, width: width, height: height)
    )
  }
}

// MARK: - Main Execution

let argCount = CommandLine.arguments.count
var args = [String]()
var i = 1
var screen: ScreenInfo?

// Tuning knobs, overridable on the command line.
var maxDeviation = MAX_DEVIATION_PP10k
var harmonics = HARMONICS

while i < argCount {
  switch CommandLine.arguments[i] {
  case "-h","--help":
    printOutput("""
    Usage: rascreen [options] <command>

    Commands:
      --set-hz <rate>          Set refresh rate (waits for RetroArch to close)
      --match-hz <rate>        Print the closest supported rate to <rate>
      --serial                 Print the display serial number
      --id                     Print the display ID
      --resolution             Print current resolution
      --hz                     Print current refresh rate
      --all-hz                 Print all available refresh rates
      --mode                   Print current display mode ID
      --all-modes              Print all available display mode IDs
      --all-screens            List all displays with serial and ID
      --get-screen <serial> [displayID]  Specify a display by serial number
      --tolerance <pp10k>      Set max deviation (default: \(MAX_DEVIATION_PP10k))
      --no-harmonics           Disable harmonic matching

    When RetroArch is not active, use --get-screen to specify a display.
    """)
    exit(0)
  case "--all-screens":
    // Return all connected display serial numbers with their id's.
    var allDisplays = [CGDirectDisplayID](repeating: 0, count: MAX_DISPLAYS)
    var count: UInt32 = 0
    CGGetActiveDisplayList(UInt32(MAX_DISPLAYS), &allDisplays, &count)
    allDisplays = Array(allDisplays.prefix(Int(count)))
    for displayID in allDisplays {
      printOutput("\(CGDisplaySerialNumber(displayID)) \(displayID)")
    }
    exit(0)
  case "--get-screen":
    i += 1
    guard i < argCount, let serial = UInt32(CommandLine.arguments[i]) else {
      printError("--get-screen requires a numeric serial id. <UInt32>")
      exit(1)
    }
    // displayID is optional; read it if a second argument is present.
    var displayID: UInt32?
    if i + 1 < argCount, let parsed = UInt32(CommandLine.arguments[i + 1]) {
      displayID = parsed
      i += 1
    }
    if let foundScreen = getScreenForSerialNumber(serial: serial, displayID: displayID) {
      screen = foundScreen
    } else {
      let idMsg = displayID.map { " and display id '\($0)'" } ?? ""
      printError("display with serial id '\(serial)'\(idMsg) not found.")
      exit(1)
    }
    i += 1
    continue
  case "--tolerance":
    i += 1
    guard i < argCount, let value = Int(CommandLine.arguments[i]), value > 0 else {
      printError("--tolerance requires a positive integer value (parts-per-10,000)")
      exit(1)
    }
    maxDeviation = value
    i += 1
    continue
  case "--no-harmonics":
    harmonics = []
    i += 1
    continue
  default:
    args.append(CommandLine.arguments[i])
    i += 1
  }
}

let targetAppName = "RetroArch"
let targetBundleID = "com.libretro.dist.RetroArch"

if screen != nil, args.contains("--set-hz") {
  // --set-hz only meant for running RetroArch.
  printError("cannot set refresh rate with --get-screen.")
  exit(1)
} else if
    screen == nil,
    let targetWindow = getAppWindows(appName: targetAppName).first,
    let foundScreen = getScreenForAppWindow(window: targetWindow) {
  screen = foundScreen
}

if let screen = screen {
  // VRR fallback is the highest available rate (VRR max).
  let rates = screen.modes.map({ $0.refreshRate })
  guard let vrrFallback = rates.max() else {
    printError("No refresh rates available for display serial '\(screen.serial)'.")
    exit(1)
  }
  var i = 0
  while i < args.count {
    let arg = args[i]
    switch arg {
    case "--set-hz":
      i += 1
      guard i < args.count, let requested = Double(args[i]) else {
        printError("--set-hz requires a numeric value")
        exit(1)
      }
      // Resolve the arbitrary request to the closest supported fixed rate.
      // Fall back to the VRR max rate if nothing is within tolerance.
      let targetRate = resolveRate(
        requested: requested,
        rates: rates,
        vrrFallback: vrrFallback,
        maxDeviation: maxDeviation,
        harmonics: harmonics
      )
      if decimalToScaled(screen.mode.refreshRate) == decimalToScaled(targetRate) {
        printOutput("Refresh rate already set to \(targetRate)Hz.")
        exit(0)
      }
      if setRefreshRate(displayID: screen.id, displayModes: screen.modes, rate: targetRate) {
        printOutput("Successfully set refresh rate to \(targetRate)Hz (requested \(requested)Hz).")
        // Refresh rate resets when the script exits, so wait for the app to end.
        // Handle SIGINT/SIGTERM to restore gracefully
        let sigint = signal(SIGINT) { _ in
          printOutput("\nInterrupted. Restoring display...")
          exit(0)
        }
        while NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID).count > 0 {
          Thread.sleep(forTimeInterval: 0.5)
        }
        signal(SIGINT, sigint)
      } else {
        printError(
          "Failed to set display to \(targetRate)Hz (requested \(requested)Hz) " +
          "on serial '\(screen.serial)'. CGDisplaySetDisplayMode failed."
        )
        exit(1)
      }
    case "--match-hz":
      // Query: print the supported fixed rate closest to the argument,
      // or the VRR fallback if the deviation is too far.
      i += 1
      guard i < args.count, let requested = Double(args[i]) else {
        printError("--match-hz requires a numeric value")
        exit(1)
      }
      let result = resolveRate(
        requested: requested,
        rates: rates,
        vrrFallback: vrrFallback,
        maxDeviation: maxDeviation,
        harmonics: harmonics
      )
      // Always print 6 decimal places so callers get a stable, fixed-width
      // numeric format (e.g. "59.940000", "60.000000").
      printOutput(String(format: "%.6f", result))
    case "--serial":     printOutput(String(screen.serial))
    case "--id":         printOutput(String(screen.id))
    case "--resolution": printOutput("\(screen.mode.width)x\(screen.mode.height)")
    case "--hz":         printOutput(String(format: "%.6f", screen.mode.refreshRate))
    case "--all-hz":     printOutput(rates.map { String(format: "%.6f", $0) }.joined(separator: " "))
    case "--mode":       printOutput(String(screen.mode.ioDisplayModeID))
    case "--all-modes":  printOutput(screen.modes.map({ String($0.ioDisplayModeID) }).joined(separator: " "))
    default:
      printError("Unknown argument: \(arg)")
      exit(1)
    }
    i += 1
  }
  if args.isEmpty {
    printError("Valid options: --serial, --id, --resolution, --hz, --all-hz, --set-hz <rate>, --match-hz <rate>, --mode, --all-modes, --all-screens, --tolerance <pp10k>, --no-harmonics")
    printError("When RetroArch is not active, specify a display with --get-screen <serial> <displayID?>")
    printError("Run with --help for usage information.")
    exit(1)
  }
} else {
  if args.contains("--set-hz") {
    printError("\(targetAppName) is not active")
  } else {
    printError("Could not determine which screen to query. \(targetAppName) is not active and --get-screen was not provided.")
    printError("Run with --help for usage information.")
  }
  exit(1)
}
