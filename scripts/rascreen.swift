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

func setRefreshRate(displayID: CGDirectDisplayID, displayModes: [CGDisplayMode], rate: Double) -> Bool {
  guard
    let targetMode = displayModes.first(where: { abs($0.refreshRate - rate) < 0.1 })
  else {
    return false
  }
  return CGDisplaySetDisplayMode(displayID, targetMode, nil) == .success
}

func getScreenForAppWindow(window: WindowInfo) -> ScreenInfo? {
  // Get a single display containing the app window.
  var displayIDs = [CGDirectDisplayID](repeating: 0, count: 1)
  CGGetDisplaysWithRect(window.bounds, 1, &displayIDs, nil)
  guard
    let displayID  = displayIDs.first,
    let activeMode = CGDisplayCopyDisplayMode(displayID)
  else {
    return nil
  }
  // Filter out non-matching resolutions, all we care about are the modes with
  // variations in refresh rates.
  let filteredModes = (CGDisplayCopyAllDisplayModes(
    displayID,
    // HiDPI modes (Retina) ignored without this:
    [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!] as CFDictionary
  ) as? [CGDisplayMode] ?? []).filter { mode in
    // Match activeMode being in HiDPI or not.
    mode.width == activeMode.width &&
    mode.pixelHeight == activeMode.pixelHeight
  }
  return ScreenInfo(
    serial: CGDisplaySerialNumber(displayID),
    id: displayID,
    mode: activeMode,
    modes: filteredModes
  )
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

let targetAppName = "RetroArch"
let targetBundleID = "com.libretro.dist.RetroArch"

guard
  let targetWindow = getAppWindows(appName: targetAppName).first
else {
  printError("\(targetAppName) is not active")
  exit(1)
}

if let screen = getScreenForAppWindow(window: targetWindow) {
  var found = false
  var i = 1
  while i < CommandLine.arguments.count {
    let arg = CommandLine.arguments[i]
    switch arg {
    case "--set-hz":
      i += 1
      if i < CommandLine.arguments.count, let rate = Double(CommandLine.arguments[i]) {
        if setRefreshRate(displayID: screen.id, displayModes: screen.modes, rate: rate) {
          print("Successfully set refresh rate to \(rate)Hz.")
          found = true
          // Refresh rate resets when the script exits, so wait for the app to end.
          while NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID).count > 0 {
            Thread.sleep(forTimeInterval: 1.0)
          }
        } else {
          printError("Failed to set refresh rate to \(rate)Hz. Mode not supported.")
          exit(1)
        }
      } else {
        printError("--set-hz requires a numeric value")
        exit(1)
      }
    case "--serial":    print(screen.serial)
    case "--id":        print(screen.id)
    case "--resolution":print("\(screen.mode.width)x\(screen.mode.height)")
    case "--hz":        print(screen.mode.refreshRate)
    case "--all-hz":    print(screen.modes.map { String($0.refreshRate) }.joined(separator: " "))
    case "--mode":      print(screen.mode.ioDisplayModeID)
    case "--all-modes": print(screen.modes.map { String($0.ioDisplayModeID )}.joined(separator: " "))
    default:
      printError("Unknown argument: \(arg)")
      exit(1)
    }
    found = true
    i += 1
  }
  if !found {
    printError("Valid options: --serial, --id, --resolution, --hz, --all-hz, --set-hz <rate> --mode --all-modes")
    exit(1)
  }
} else {
  printError("Could not determine which screen \(targetAppName) is in")
  exit(1)
}
