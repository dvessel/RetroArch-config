#!/usr/bin/env swift

import Foundation
import AppKit

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

func setRefreshRate(displayID: CGDirectDisplayID, displayModes: [CGDisplayMode], rate: Double) -> Bool {
  guard
    let targetMode = displayModes.first(where: { abs($0.refreshRate - rate) < 0.01 })
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
  var allDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
  var count: UInt32 = 0
  CGGetActiveDisplayList(16, &allDisplays, &count)
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
      let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat]
    else {
      return nil
    }
    let bounds = CGRect(
      x: boundsDict["X"] ?? 0,
      y: boundsDict["Y"] ?? 0,
      width: boundsDict["Width"] ?? 0,
      height: boundsDict["Height"] ?? 0
    )
    guard
      bounds.width > 100, bounds.height > 100
    else {
      return nil
    }
    return WindowInfo(appName: appName, bounds: bounds)
  }
}

// MARK: - Main Execution

let argCount = CommandLine.arguments.count
var args = [String]()
var i = 1
var screen: ScreenInfo?

while i < argCount {
  switch CommandLine.arguments[i] {
  case "--all-screens":
    // Return all connected display serial numbers with their id's.
    var allDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetActiveDisplayList(16, &allDisplays, &count)
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
  var found = false
  var i = 0
  while i < args.count {
    let arg = args[i]
    switch arg {
    case "--set-hz":
      i += 1
      if i < args.count, let rate = Double(args[i]) {
        if abs(screen.mode.refreshRate - rate) < 0.01 {
          printOutput("Refresh rate already set to \(rate)Hz.")
          exit(0)
        }
        if setRefreshRate(displayID: screen.id, displayModes: screen.modes, rate: rate) {
          printOutput("Successfully set refresh rate to \(rate)Hz.")
          found = true
          // Refresh rate resets when the script exits, so wait for the app to end.
          while NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID).count > 0 {
            Thread.sleep(forTimeInterval: 0.5)
          }
        } else {
          printError("Failed to set refresh rate to \(rate)Hz. Mode not supported.")
          exit(1)
        }
      } else {
        printError("--set-hz requires a numeric value")
        exit(1)
      }
    case "--serial":     printOutput(String(screen.serial))
    case "--id":         printOutput(String(screen.id))
    case "--resolution": printOutput("\(screen.mode.width)x\(screen.mode.height)")
    case "--hz":         printOutput(String(screen.mode.refreshRate))
    case "--all-hz":     printOutput(screen.modes.map { String($0.refreshRate) }.joined(separator: " "))
    case "--mode":       printOutput(String(screen.mode.ioDisplayModeID))
    case "--all-modes":  printOutput(screen.modes.map { String($0.ioDisplayModeID) }.joined(separator: " "))
    default:
      printError("Unknown argument: \(arg)")
      exit(1)
    }
    found = true
    i += 1
  }
  if !found {
    printError("Valid options: --serial, --id, --resolution, --hz, --all-hz, --set-hz <rate>, --mode, --all-modes, --all-screens")
    printError("When RetroArch is not active, specify a display with --get-screen <serial> <displayID?>")
    exit(1)
  }
} else {
  if args.contains("--set-hz") {
    printError("\(targetAppName) is not active")
  } else {
    printError("Could not determine which screen to query. \(targetAppName) is not active and --get-screen was not provided.")
  }
  exit(1)
}
