// AccessibilitySnapshot.swift
// A lightweight Swift library to snapshot the current macOS accessibility hierarchy.
//
// This code is intended to be compiled as a dynamic library and called from another language (e.g. Rust).
// It exports a single C–callable function that returns a JSON string describing all accessible applications' windows
// and their nested UI elements.
//
// To compile (example):
//   swiftc -emit-library -o libaccessibility.dylib AccessibilitySnapshot.swift
//
// Note: The caller is responsible for freeing the returned C string (using free()).

import Cocoa
import ApplicationServices
import Foundation
import CryptoKit
import CoreSpotlight
import UniformTypeIdentifiers

// MARK: - Helper: Check Accessibility Permissions

func checkAccessibilityPermissions() -> Bool {
    // The key kAXTrustedCheckOptionPrompt (bridged) will prompt the user if needed.
    let promptOption = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptOption: true] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(options)
    return trusted
}

// MARK: - Helper: Get an attribute value

func getAttributeValue(_ element: AXUIElement, attribute: String) -> AnyObject? {
    var value: AnyObject?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    if error == .success {
        return value
    }
    return nil
}

// MARK: - Helper: Get Bounding Rect for Selected Text Range

func getBoundingRectForRange(_ element: AXUIElement, range: CFRange) -> CGRect? {
    // Create an AXValue for the range
    var rangeValue: AXValue?
    var rangeCopy = range
    if let axRange = AXValueCreate(.cfRange, &rangeCopy) {
        rangeValue = axRange
    } else {
        return nil
    }

    // Get the bounds for the range
    var result: AnyObject?
    let error = AXUIElementCopyParameterizedAttributeValue(
        element,
        "AXBoundsForRange" as CFString,
        rangeValue as CFTypeRef,
        &result
    )

    if error == .success && result != nil {
        let rectValue = result as! AXValue
        var rect = CGRect.zero
        if AXValueGetValue(rectValue, .cgRect, &rect) {
            return rect
        }
    }
    return nil
}

// MARK: - Helper: Describe an attribute value

func describeValue(_ value: AnyObject?) -> String {
    guard let value = value else { return "" }
    switch value {
    case let s as String:
        return s.replacingOccurrences(of: "\n", with: "\\n")
    case let n as NSNumber:
        return n.stringValue
    case let posVal as AXValue:
        // Try to interpret as a CGPoint.
        if AXValueGetType(posVal) == .cgPoint {
            var point = CGPoint.zero
            AXValueGetValue(posVal, .cgPoint, &point)
            return "(\(point.x), \(point.y))"
        }
        // Try to interpret as a range
        if AXValueGetType(posVal) == .cfRange {
            var range = CFRange()
            AXValueGetValue(posVal, .cfRange, &range)
            return "loc=\(range.location) len=\(range.length)"
        }
        return "\(posVal)"
    default:
        return "\(value)"
    }
}

// MARK: - Helper: Check Element Visibility

func isElementVisible(_ element: AXUIElement) -> Bool {
    // Check explicit visibility attribute
    if let visible = getAttributeValue(element, attribute: kAXHiddenAttribute as String) as? Bool {
        return !visible
    }

    // Check if element has zero size
    if let sizeAny = getAttributeValue(element, attribute: kAXSizeAttribute as String) {
        let sizeVal = sizeAny as! AXValue
        if AXValueGetType(sizeVal) == .cgSize {
            var size = CGSize.zero
            AXValueGetValue(sizeVal, .cgSize, &size)
            if size.width <= 0 || size.height <= 0 {
                return false
            }
        }
    }

    // Check if element is off-screen
    if let posAny = getAttributeValue(element, attribute: kAXPositionAttribute as String) {
        let posVal = posAny as! AXValue
        if AXValueGetType(posVal) == .cgPoint {
            var point = CGPoint.zero
            AXValueGetValue(posVal, .cgPoint, &point)
            // Basic check if element is way off screen (could be refined based on actual screen bounds)
            if point.x < -10000 || point.y < -10000 {
                return false
            }
        }
    }

    // Additional visibility indicators
    if let shown = getAttributeValue(element, attribute: "AXShownMenu") as? Bool {
        return shown
    }

    // Default to visible if no contrary indicators
    return true
}

// MARK: - New Helper: Generate an ID from a given accessibility path
func generateIdFromPath(_ path: String) -> String {
    let data = Data(path.utf8)
    let hash = SHA256.hash(data: data)
    let shortHash = hash.prefix(4)
    return shortHash.map { String(format: "%02x", $0) }.joined()
}

// MARK: - New Helper: Recursively find an element with a matching computed id
func findElementWithId(_ element: AXUIElement, targetId: String, path: String = "") -> AXUIElement? {
    guard let _ = getAttributeValue(element, attribute: "AXRole") as? String else {
        return nil
    }

    let attributesInPath = [
        "AXRole",
        "AXRoleDescription",
        "AXLabel",
        "AXTitle",
        "AXDescription",
        "AXHelp",
        "AXSubrole"
    ]
    let currentAttributesPath = attributesInPath.compactMap { attr -> String? in
        if let rawVal = getAttributeValue(element, attribute: attr) {
            let s = describeValue(rawVal)
            return s.isEmpty ? nil : s
        }
        return nil
    }.joined(separator: " -> ")
    let currentPath = path.isEmpty ? currentAttributesPath : "\(path) -> \(currentAttributesPath)"

    let computedId = generateIdFromPath(currentPath)
    if computedId == targetId {
        return element
    }

    if let children = getAttributeValue(element, attribute: kAXChildrenAttribute as String) as? [AXUIElement] {
        for child in children {
            if let found = findElementWithId(child, targetId: targetId, path: currentPath) {
                return found
            }
        }
    }
    return nil
}

/// Recursively traverses an AXUIElement and returns a dictionary in the "compact" format.
/// - Parameters:
///   - element: The accessibility element to traverse.
///   - depth: The current depth in the tree.
///   - path: The "path" of parent element roles (used for debugging or identifying the element).
/// - Returns: A dictionary representing the element (or nil if no useful data was found).
func traverseElement(_ element: AXUIElement, depth: Int, path: String = "") -> [String: Any]? {
    // Check visibility first - skip invisible elements
    if !isElementVisible(element) {
        return nil
    }

    // Get the element's role.
    guard let role = getAttributeValue(element, attribute: "AXRole") as? String else {
        return nil
    }

    // Build an updated path using attribute values in order, omitting any empty values.
    let attributesInPath = [
        "AXRole",
        "AXRoleDescription",
        "AXLabel",
        "AXTitle",
        "AXDescription",
        "AXHelp",
        "AXSubrole"
    ]
    let currentAttributesPath = attributesInPath.compactMap { attr -> String? in
        if let rawVal = getAttributeValue(element, attribute: attr) {
            let s = describeValue(rawVal)
            return s.isEmpty ? nil : s
        }
        return nil
    }.joined(separator: " -> ")
    let currentPath = path.isEmpty ? currentAttributesPath : "\(path) -> \(currentAttributesPath)"

    // Compute the unique id from the path.
    let computedId = generateIdFromPath(currentPath)

    // Create the element dictionary.
    var dict: [String: Any] = [:]
    dict["id"] = computedId         // Unique identifier
    dict["e"] = role                // Element type (role)
    dict["p"] = currentPath         // Unique path / identifier
    dict["d"] = depth               // Depth (an integer)

    // Get frame information: position and size.
    var frame: [CGFloat] = [0, 0, 0, 0]

    if let posAny = getAttributeValue(element, attribute: kAXPositionAttribute as String) {
        let posVal = posAny as! AXValue
        if AXValueGetType(posVal) == .cgPoint {
            var point = CGPoint.zero
            AXValueGetValue(posVal, .cgPoint, &point)
            frame[0] = point.x
            frame[1] = point.y
        }
    }

    if let sizeAny = getAttributeValue(element, attribute: kAXSizeAttribute as String) {
        let sizeVal = sizeAny as! AXValue
        if AXValueGetType(sizeVal) == .cgSize {
            var size = CGSize.zero
            AXValueGetValue(sizeVal, .cgSize, &size)
            frame[2] = size.width
            frame[3] = size.height
        }
    }
    dict["f"] = frame

    // Capture a few useful attributes.
    var attributes: [String: String] = [:]
    let attributesToCheck = [
        "AXRole",
        "AXRoleDescription",
        "AXValue",
        "AXLabel",
        "AXTitle",
        "AXDescription",
        "AXHelp",
        "AXSelected",
        "AXEnabled",
        "AXFocused",
        "AXSubrole"
    ]
    for attr in attributesToCheck {
        if let raw = getAttributeValue(element, attribute: attr) {
            let s = describeValue(raw)
            if !s.isEmpty {
                attributes[attr] = s
            }
        }
    }

    // Add text-specific attributes for text elements
    if role == "AXTextArea" || role == "AXTextField" {
        // Get selected text range
        if let selectedRange = getAttributeValue(element, attribute: "AXSelectedTextRange") {
            let axValue = selectedRange as! AXValue
            if AXValueGetType(axValue) == .cfRange {
                var range = CFRange()
                AXValueGetValue(axValue, .cfRange, &range)
                attributes["AXSelectedTextRange"] = describeValue(selectedRange)

                // Get bounding rect for selected text if there is a selection
                if range.length > 0 {
                    if let rect = getBoundingRectForRange(element, range: range) {
                        attributes["AXSelectedTextBounds"] = String(format: "%.1f,%.1f,%.1f,%.1f",
                            rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
                    }
                }
            }
        }

        // Get selected text
        if let selectedText = getAttributeValue(element, attribute: "AXSelectedText") {
            attributes["AXSelectedText"] = describeValue(selectedText)
        }

        // Get marked text range
        if let markedRange = getAttributeValue(element, attribute: "AXMarkedTextRange") {
            attributes["AXMarkedTextRange"] = describeValue(markedRange)
        }

        // Get number of characters
        if let numberOfCharacters = getAttributeValue(element, attribute: "AXNumberOfCharacters") {
            attributes["AXNumberOfCharacters"] = describeValue(numberOfCharacters)
        }

        // Get placeholder value
        if let placeholder = getAttributeValue(element, attribute: "AXPlaceholderValue") {
            attributes["AXPlaceholderValue"] = describeValue(placeholder)
        }
    }

    if !attributes.isEmpty {
        dict["a"] = attributes
    }

    // Capture available actions (methods) on the element.
    var actions: [String] = []
    var actionNames: CFArray?
    if AXUIElementCopyActionNames(element, &actionNames) == .success,
       let actionArray = actionNames as? [String] {
        actions = actionArray
    }
    if !actions.isEmpty {
        dict["m"] = actions
    }

    // Recurse into the children.
    var childrenArray: [[String: Any]] = []
    if let children = getAttributeValue(element, attribute: kAXChildrenAttribute as String) as? [AXUIElement] {
        for child in children {
            if let childDict = traverseElement(child, depth: depth + 1, path: currentPath) {
                childrenArray.append(childDict)
            }
        }
    }
    if !childrenArray.isEmpty {
        dict["c"] = childrenArray
    }

    return dict
}

// MARK: - Main Snapshot Function

// Add these new types at the top of the file
struct SnapshotFilter {
    let appName: String?
    let windowTitle: String?
}

/// Gathers the current accessibility hierarchy, optionally filtered by app and window
/// - Parameters:
///   - filter: Optional filter criteria for app name and window title
/// - Returns: A JSON string with the snapshot, or an error JSON if permissions are missing.
func snapshotAccessibilityHierarchy(filter: SnapshotFilter? = nil) -> String {
    guard checkAccessibilityPermissions() else {
        return "{\"error\": \"Accessibility permissions not granted\"}"
    }

    // The final JSON structure.
    var result: [String: Any] = [:]
    result["ts"] = ISO8601DateFormatter().string(from: Date())

    // This will contain the UI elements (each representing a window)
    var elements: [[String: Any]] = []

    // Get all running (regular) applications
    let runningApps = NSWorkspace.shared.runningApplications.filter { app in
        guard app.activationPolicy == .regular else { return false }

        // If we have a filter, check the app name
        if let filter = filter, let filterAppName = filter.appName {
            guard let appName = app.localizedName else { return false }
            return appName.lowercased() == filterAppName.lowercased()
        }

        // If no filter or app name doesn't match filter, check if app is active
        return app.isActive
    }

    for app in runningApps {
        guard let appName = app.localizedName else { continue }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Check if the application is active (frontmost)
        let isAppActive = app.isActive

        if let windows = getAttributeValue(axApp, attribute: kAXWindowsAttribute as String) as? [AXUIElement] {
            for window in windows {
                // Check window title against filter if provided
                if let filter = filter, let filterWindowTitle = filter.windowTitle {
                    guard let windowTitle = getAttributeValue(window, attribute: kAXTitleAttribute as String) as? String,
                          windowTitle.lowercased() == filterWindowTitle.lowercased() else {
                        continue
                    }
                }

                // Check if this window is the main window
                if let main = getAttributeValue(window, attribute: kAXMainAttribute as String) as? Bool, main {
                    // Traverse the window's UI tree.
                    if var windowDict = traverseElement(window, depth: 0) {
                        windowDict["main"] = main

                        // Optionally include the application name.
                        windowDict["app"] = appName
                        // Include whether the application is active
                        windowDict["appActive"] = isAppActive

                        // Check if this window is focused
                        // if let focused = getAttributeValue(window, attribute: kAXFocusedAttribute as String) as? Bool {
                        //     windowDict["focused"] = focused
                        // }
                        elements.append(windowDict)
                    }
                }
            }
        }
    }

    result["e"] = elements

    // Serialize the result to JSON.
    if let data = try? JSONSerialization.data(withJSONObject: result, options: []),
       let jsonString = String(data: data, encoding: .utf8) {
        return jsonString
    }

    return "{}"
}

/// C-callable function to get the accessibility hierarchy with optional filtering
@_cdecl("get_accessibility_hierarchy_filtered")
public func get_accessibility_hierarchy_filtered(
    appName: UnsafePointer<CChar>?,
    windowTitle: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    let filter: SnapshotFilter?

    if let appName = appName, let windowTitle = windowTitle {
        filter = SnapshotFilter(
            appName: String(cString: appName),
            windowTitle: String(cString: windowTitle)
        )
    } else if let appName = appName {
        filter = SnapshotFilter(
            appName: String(cString: appName),
            windowTitle: nil
        )
    } else if let windowTitle = windowTitle {
        filter = SnapshotFilter(
            appName: nil,
            windowTitle: String(cString: windowTitle)
        )
    } else {
        filter = nil
    }

    let jsonString = snapshotAccessibilityHierarchy(filter: filter)
    return strdup(jsonString)
}

// Keep the original unfiltered function for backward compatibility
@_cdecl("get_accessibility_hierarchy")
public func get_accessibility_hierarchy() -> UnsafeMutablePointer<CChar>? {
    let jsonString = snapshotAccessibilityHierarchy(filter: nil)
    return strdup(jsonString)
}

// New helper: Recursively find an element with specific role and title
func findElementWithRoleAndTitle(_ element: AXUIElement, role: String, title: String) -> AXUIElement? {
    if let elementRole = getAttributeValue(element, attribute: "AXRole") as? String,
       elementRole == role {
        if let elementTitle = getAttributeValue(element, attribute: "AXTitle") as? String,
           elementTitle == title {
            return element
        }
        if let elementLabel = getAttributeValue(element, attribute: "AXLabel") as? String,
           elementLabel == title {
            return element
        }
        if let elementDescription = getAttributeValue(element, attribute: "AXDescription") as? String,
           elementDescription == title {
            return element
        }
    }
    if let children = getAttributeValue(element, attribute: kAXChildrenAttribute as String) as? [AXUIElement] {
        for child in children {
            if let found = findElementWithRoleAndTitle(child, role: role, title: title) {
                return found
            }
        }
    }
    return nil
}

@_cdecl("perform_type_action")
public func perform_type_action(cElementId: UnsafePointer<CChar>, cText: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let windowTitle = "Skip - Google Chrome" // TODO: Implement dynamic window searching later
    let elementId = String(cString: cElementId)
    let newText = String(cString: cText)

    print("perform_type_action received elementId: \(elementId), newText: \(newText)")
    guard checkAccessibilityPermissions() else {
        print("Accessibility permissions not granted")
        return strdup("Accessibility permissions not granted")
    }
    let window: AXUIElement?
    if let foundWindow = findWindowWithTitle(windowTitle) {
        window = foundWindow
        print("Found window with title: \(windowTitle)")
    } else {
        window = getFrontmostWindow()
        print("Using frontmost window as fallback")
    }
    if let window = window {
        if let textField = findElementWithId(window, targetId: elementId) {
            print("Found text field with id: \(elementId)")

            // Check if element has AXPress action
            var actionNames: CFArray?
            if AXUIElementCopyActionNames(textField, &actionNames) == .success,
               let actionArray = actionNames as? [String],
               actionArray.contains("AXPress") {
                // Perform AXPress action
                print("Found AXPress action, performing it first")
                let pressError = AXUIElementPerformAction(textField, "AXPress" as CFString)
                if pressError == .success {
                    print("Successfully performed AXPress action")
                } else {
                    print("Failed to perform AXPress action: \(pressError)")
                }
                // Wait 20 milliseconds
                usleep(20_000)
            }

            // Read the initial value (before) from the text field
            var currentValueBefore: AnyObject?
            let readErrorBefore = AXUIElementCopyAttributeValue(textField, kAXValueAttribute as CFString, &currentValueBefore)
            var beforeText = ""
            if readErrorBefore == .success, let valueBefore = currentValueBefore {
                let valueCF = valueBefore as! CFString
                beforeText = valueCF as String
            } else {
                beforeText = "Error reading initial value"
            }

            // Set the new text
            let cfText = newText as CFString
            let error = AXUIElementSetAttributeValue(textField, kAXValueAttribute as CFString, cfText)
            if error == .success {
                print("Successfully set text for element with id \(elementId)")
            } else {
                print("Failed to set text, error: \(error)")
            }
            // Wait 0.1 second
            usleep(100_000)
            // Read back the updated (after) value
            var currentValue: AnyObject?
            let readError = AXUIElementCopyAttributeValue(textField, kAXValueAttribute as CFString, &currentValue)
            var afterText = ""
            if readError == .success, let value = currentValue {
                let valueCF = value as! CFString
                afterText = valueCF as String
                print("Read latest text from element \(elementId): \(afterText)")
            } else {
                afterText = "Error reading latest value"
                print("Failed to read latest value for element \(elementId), error: \(readError)")
            }
            // Return a JSON string with both before and after values
            let resultDict = ["before": beforeText, "after": afterText]
            if let jsonData = try? JSONSerialization.data(withJSONObject: resultDict, options: []),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return strdup(jsonString)
            }
            return strdup("{\"before\": \"\", \"after\": \"\"}")
        } else {
            print("No element with id \(elementId) found in window")
            return strdup("Error: Element not found in window")
        }
    } else {
        print("No window found")
        return strdup("Error: Window not found")
    }
    // Fallback
    print("No element with id \(elementId) found in any window")
    return strdup("Error: Element not found in any window")
}

func getFrontmostWindow() -> AXUIElement? {
    // Get the frontmost application
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
        print("No frontmost application found")
        return nil
    }

    // Create an AXUIElement for the frontmost application
    let axApp = AXUIElementCreateApplication(frontmostApp.processIdentifier)

    // Try to get the frontmost window for this app
    if let windows = getAttributeValue(axApp, attribute: kAXWindowsAttribute as String) as? [AXUIElement] {
        for window in windows {
            if let isMainWindow = getAttributeValue(window, attribute: kAXMainAttribute as String) as? Bool, isMainWindow {
                return window
            }
        }
    }

    print("No frontmost window found for application \(frontmostApp.localizedName ?? "Unknown")")
    return nil
}


func findWindowWithTitle(_ title: String) -> AXUIElement? {
    print("findWindowWithTitle: \(title)")

    // Get all running (regular) applications.
    let runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    for app in runningApps {
        // Check that localizedName exists; we don't need the value here
        if app.localizedName == nil { continue }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Try to get the windows for this app.
        if let windows = getAttributeValue(axApp, attribute: kAXWindowsAttribute as String) as? [AXUIElement] {
            for window in windows {
                if let windowTitle = getAttributeValue(window, attribute: kAXTitleAttribute as String) as? String {
                    print("Window title: \"\(windowTitle)\"")
                    if windowTitle.contains(title) {
                        return window
                    }
                }
            }
        }
    }
    return nil
}

@_cdecl("perform_named_action")
public func perform_named_action(cElementId: UnsafePointer<CChar>, cActionName: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let windowTitle = "Skip - Google Chrome" // TODO: Implement dynamic window searching later
    let elementId = String(cString: cElementId)
    let actionName = String(cString: cActionName)

    print("perform_named_action received elementId: \(elementId), actionName: \(actionName)")

    guard checkAccessibilityPermissions() else {
        print("Accessibility permissions not granted")
        return strdup("Accessibility permissions not granted")
    }

    let window: AXUIElement?
    if let foundWindow = findWindowWithTitle(windowTitle) {
        window = foundWindow
        print("Found window with title: \(windowTitle)")
    } else {
        window = getFrontmostWindow()
        print("Using frontmost window as fallback")
    }

    if let window = window {
        if let element = findElementWithId(window, targetId: elementId) {
            print("Found element with id: \(elementId)")

            let error = AXUIElementPerformAction(element, actionName as CFString)
            if error == .success {
                print("Successfully performed action \(actionName) on element \(elementId)")
                return strdup("{\"result\": \"success\"}")
            } else {
                print("Failed to perform action: \(error)")
                return strdup("Error: Failed to perform action")
            }
        } else {
            print("No element with id \(elementId) found in window")
            return strdup("Error: Element not found in window")
        }
    } else {
        print("No window found")
        return strdup("Error: Window not found")
    }

    print("No element with id \(elementId) found in any window")
    return strdup("Error: Element not found in any window")
}
