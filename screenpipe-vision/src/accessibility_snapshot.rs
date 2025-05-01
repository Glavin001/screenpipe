// Learn more about Tauri commands at https://tauri.app/develop/calling-rust/
use serde::Serialize;
use serde::Deserialize;
use core_foundation::dictionary::{CFDictionary, CFDictionaryRef};
use core_foundation::boolean::CFBoolean;
use core_foundation::base::TCFType;

use std::sync::Arc;
use std::time::Duration;
use rand::Rng;
use rand::rngs::StdRng;
use rand::SeedableRng;
use tauri::Manager;
use tauri::PhysicalPosition;
use tauri::PhysicalSize;
use tauri::{TitleBarStyle, WebviewWindowBuilder};
use tauri_utils::config::WebviewUrl;
use std::collections::HashSet;
use std::sync::Mutex;
use once_cell::sync::Lazy;
use std::sync::atomic::{AtomicBool, Ordering};
use std::ffi::{CString, CStr};
use std::os::raw::{c_char, c_void};
use tauri::webview::Color;

// Add a static set to track context files
static CONTEXT_FILES: Lazy<Mutex<HashSet<String>>> = Lazy::new(|| Mutex::new(HashSet::new()));

// A simple structure for UI element information.
#[derive(Serialize)]
pub struct UIElement {
    pub role: String,
    pub label: String,
    pub value: String,
    pub x: f64,
    pub y: f64,
}

// Track window labels to manage cleanup
static OVERLAY_WINDOW_LABELS: Lazy<Mutex<HashSet<String>>> = Lazy::new(|| Mutex::new(HashSet::new()));
static IS_POLLING: Lazy<AtomicBool> = Lazy::new(|| AtomicBool::new(false));


#[cfg(target_os = "macos")]
mod ffi {
    use std::os::raw::c_char;
    extern "C" {
        pub fn perform_type_action(cElementId: *const c_char, cText: *const c_char) -> *mut c_char;
        #[link_name = "perform_named_action"]
        pub fn named_action(cElementId: *const c_char, cActionName: *const c_char) -> *mut c_char;
        pub fn get_accessibility_hierarchy() -> *mut c_char;
        pub fn get_accessibility_hierarchy_filtered(
            app_name: *const c_char,
            window_title: *const c_char
        ) -> *mut c_char;
    }
}

#[tauri::command]
fn fetch_ui_elements() -> Vec<UIElement> {
    #[cfg(target_os = "macos")]
    {
        return macos_accessibility::get_ui_elements();
    }
    #[cfg(not(target_os = "macos"))]
    {
        // Print a warning if not running on macOS.
        println!("Warning: fetch_ui_elements is only supported on macOS. Returning an empty vector.");
        // If not running on macOS, return an empty vector.
        return vec![];
    }
}

#[cfg(target_os = "macos")]
mod macos_accessibility {
    use super::ffi;
    use super::UIElement;
    use std::os::raw::{c_void, c_char};
    use std::ffi::{CString, CStr};
    use std::ptr;
    use core_foundation::{
        array::CFArray,
        base::{CFRelease, CFTypeRef, TCFType},
        string::{CFString, CFStringRef},
    };
    use core_foundation_sys::array::CFArrayGetValueAtIndex;
    use core_graphics::geometry::CGPoint;
    use core_foundation_sys::base::OSStatus;
    use core_foundation::dictionary::CFDictionaryRef;
    use core_foundation::boolean::CFBoolean;
    use core_foundation::dictionary::CFDictionary;

    // An opaque pointer type representing an AXUIElement.
    pub type AXUIElementRef = *mut c_void;
    pub type AXValueRef = *mut c_void;
    pub type AXValueType = u32;
    pub const K_AXVALUE_CGPOINT_TYPE: AXValueType = 2; // Typically, 2 represents a CGPoint type.

    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        pub fn AXUIElementCreateSystemWide() -> AXUIElementRef;
        pub fn AXUIElementCopyAttributeValue(
            element: AXUIElementRef,
            attribute: CFStringRef,
            value: *mut CFTypeRef,
        ) -> OSStatus;
        pub fn AXValueGetValue(
            value: AXValueRef,
            theType: AXValueType,
            valuePtr: *mut c_void,
        ) -> i32;
        pub fn AXIsProcessTrustedWithOptions(options: CFDictionaryRef) -> bool;
        fn get_accessibility_hierarchy() -> *mut c_char;
    }

    /// Safely fetch an accessibility attribute as a Rust String.
    pub unsafe fn get_attribute_string(element: AXUIElementRef, attribute: &str) -> Option<String> {
        println!("Fetching attribute string for: {}", attribute);
        let attr = CFString::new(attribute);
        let mut value: CFTypeRef = ptr::null();
        let result = AXUIElementCopyAttributeValue(element, attr.as_concrete_TypeRef(), &mut value);
        println!("Result of AXUIElementCopyAttributeValue: {}", result);
        if result != 0 || value.is_null() {
            println!("Failed to get attribute string for: {}", attribute);
            return None;
        }
        // Assume the returned value is a CFString.
        let cf_str = CFString::wrap_under_create_rule(value as *mut _);
        let string = cf_str.to_string();
        CFRelease(value);
        Some(string)
    }

    /// Fetch an accessibility attribute expected to be a CGPoint (using "AXPosition").
    pub unsafe fn get_attribute_position(element: AXUIElementRef, attribute: &str) -> Option<(f64, f64)> {
        println!("Fetching attribute position for: {}", attribute);
        let attr = CFString::new(attribute);
        let mut value: CFTypeRef = ptr::null();
        let result = AXUIElementCopyAttributeValue(element, attr.as_concrete_TypeRef(), &mut value);
        println!("Result of AXUIElementCopyAttributeValue: {}", result);
        if result != 0 || value.is_null() {
            println!("Failed to get attribute position for: {}", attribute);
            return None;
        }
        let ax_value = value as AXValueRef;
        let mut point = CGPoint { x: 0.0, y: 0.0 };
        let success = AXValueGetValue(ax_value, K_AXVALUE_CGPOINT_TYPE, &mut point as *mut _ as *mut c_void);
        if success == 0 {
            CFRelease(value);
            return None;
        }
        CFRelease(value);
        Some((point.x as f64, point.y as f64))
    }

    /// Retrieve the children (AXChildren) of an accessibility element.
    pub unsafe fn get_attribute_children(element: AXUIElementRef) -> Option<CFArray<*mut c_void>> {
        println!("Fetching children for element");
        let attr = CFString::new("AXChildren");
        let mut value: CFTypeRef = ptr::null();
        let result = AXUIElementCopyAttributeValue(element, attr.as_concrete_TypeRef(), &mut value);
        println!("Result of AXUIElementCopyAttributeValue: {}", result);
        if result != 0 || value.is_null() {
            println!("Failed to get children for element");
            return None;
        }
        Some(CFArray::wrap_under_create_rule(value as *mut _))
    }

    /// Recursively traverse the UI element hierarchy and collect those with interactive roles.
    pub unsafe fn traverse_ui_elements(element: AXUIElementRef, elements: &mut Vec<UIElement>) {
        println!("Traversing UI elements");
        // Try to obtain the role, title (or label), value, and position.
        let role = get_attribute_string(element, "AXRole");
        let title = get_attribute_string(element, "AXTitle")
            .or_else(|| get_attribute_string(element, "AXLabel"));
        let value_attr = get_attribute_string(element, "AXValue");
        let position = get_attribute_position(element, "AXPosition");

        if let Some(pos) = position {
            if let Some(role_str) = role {
                println!("Found element with role: {}", role_str);
                // For this demo, treat only a few common roles as interactive.
                let interactive_roles = ["AXButton", "AXSlider", "AXTextField", "AXCheckBox"];
                if interactive_roles.contains(&role_str.as_str()) {
                    let label = title.unwrap_or_default();
                    let value_str = value_attr.unwrap_or_default();
                    elements.push(UIElement {
                        role: role_str,
                        label,
                        value: value_str,
                        x: pos.0,
                        y: pos.1,
                    });
                }
            }
        }

        // Traverse children if available.
        if let Some(children_array) = get_attribute_children(element) {
            let count = children_array.len();
            for i in 0..count {
                let child_ptr = CFArrayGetValueAtIndex(children_array.as_concrete_TypeRef(), i) as AXUIElementRef;
                if !child_ptr.is_null() {
                    traverse_ui_elements(child_ptr, elements);
                }
            }
        }
    }

    /// Returns a vector of UIElement structures, obtained by starting at the focused window.
    pub fn get_ui_elements() -> Vec<UIElement> {
        println!("================================================");
        println!("Getting UI elements");
        let mut elements: Vec<UIElement> = Vec::new();
        unsafe {

            // Check if accessibility permissions have been granted.
            let check_attr = CFString::new("AXTrustedCheckOptionPrompt");
            let options: CFDictionaryRef = CFDictionary::from_CFType_pairs(&[
                (check_attr.as_CFType(), CFBoolean::true_value().as_CFType())
            ]).as_concrete_TypeRef();

            let accessibility_enabled = {
                let result = AXIsProcessTrustedWithOptions(options);
                result
            };

            if accessibility_enabled {
                println!("Accessibility permissions have been granted.");
            } else {
                println!("Error: Accessibility permissions have not been granted.");
                return elements;
            }

            // Create a system-wide accessibility element.
            let system_wide = AXUIElementCreateSystemWide();
            // Attempt to get the currently focused window.
            let focused_attr = CFString::new("AXFocusedWindow");
            let mut focused_window_ptr: CFTypeRef = ptr::null();
            let result = AXUIElementCopyAttributeValue(
                system_wide,
                focused_attr.as_concrete_TypeRef(),
                &mut focused_window_ptr,
            );

            if result != 0 {
                println!("Error: Failed to get focused window attribute. Result code: {}", result);
            }

            if focused_window_ptr.is_null() {
                println!("Warning: Focused window pointer is null. Using system-wide element.");
            }

            let focused_window = if result == 0 && !focused_window_ptr.is_null() {
                focused_window_ptr as AXUIElementRef
            } else {
                // If no focused window is available, fallback to the system‑wide element.
                system_wide
            };

            // Recursively scan the element tree.
            traverse_ui_elements(focused_window, &mut elements);

            if !focused_window_ptr.is_null() {
                CFRelease(focused_window_ptr);
            }
        }
        println!("Total UI elements found: {}", elements.len());
        println!("================================================");
        elements
    }

    pub async fn get_accessibility_snapshot(
        target_app: Option<String>,
        target_window: Option<String>
    ) -> String {
        tokio::task::spawn_blocking(move || {
            unsafe {
                // println!("Getting accessibility snapshot");
                // if let Some(app_name) = &target_app {
                //     println!("Filtering for app: {}", app_name);
                // }
                // if let Some(window_name) = &target_window {
                //     println!("Filtering for window: {}", window_name);
                // }

                let start = std::time::Instant::now();

                let c_str = match (target_app, target_window) {
                    (Some(app), Some(window)) => {
                        let c_app = CString::new(app).unwrap();
                        let c_window = CString::new(window).unwrap();
                        ffi::get_accessibility_hierarchy_filtered(
                            c_app.as_ptr(),
                            c_window.as_ptr()
                        )
                    },
                    (Some(app), None) => {
                        let c_app = CString::new(app).unwrap();
                        ffi::get_accessibility_hierarchy_filtered(
                            c_app.as_ptr(),
                            std::ptr::null()
                        )
                    },
                    (None, Some(window)) => {
                        let c_window = CString::new(window).unwrap();
                        ffi::get_accessibility_hierarchy_filtered(
                            std::ptr::null(),
                            c_window.as_ptr()
                        )
                    },
                    (None, None) => ffi::get_accessibility_hierarchy()
                };

                let duration = start.elapsed();
                // println!("get_accessibility_hierarchy took {:?}", duration);

                if c_str.is_null() {
                    return String::from("{\"error\": \"Failed to get accessibility hierarchy\"}");
                }
                let result = CStr::from_ptr(c_str)
                    .to_string_lossy()
                    .into_owned();
                // Free the string allocated by strdup in Swift
                libc::free(c_str as *mut c_void);
                result
            }
        })
        .await
        .unwrap_or_else(|_| String::from("{\"error\": \"Failed to execute task\"}"))
    }
}

#[cfg(target_os = "macos")]
fn prompt_for_accessibility_permissions() {
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::CFString;
    use core_foundation::boolean::CFBoolean;
    use core_foundation::base::TCFType;
    use core_foundation_sys::dictionary::CFDictionaryRef;
    use std::os::raw::c_void;

    // kAXTrustedCheckOptionPrompt is used to show the prompt if required.
    let key = CFString::new("AXTrustedCheckOptionPrompt");
    let value = CFBoolean::true_value();

    // Create a dictionary via a slice of (key, value) pairs.
    // This returns a CFDictionary<CFString, CFBoolean>
    let options_dict = CFDictionary::from_CFType_pairs(&[(key, value)]);
    // Cast the dictionary to the raw type that is expected (CFDictionaryRef)
    let options_dict_ref: CFDictionaryRef = options_dict.as_concrete_TypeRef();

    // Call the external function to check for trust and to prompt if necessary.
    unsafe {
        let trusted = macos_accessibility::AXIsProcessTrustedWithOptions(options_dict_ref);
        if !trusted {
            println!("Accessibility permissions are not granted. Please enable them in System Preferences.");
        }
    }
}

#[tauri::command]
async fn get_accessibility_snapshot(
  target_app: Option<String>,
  target_window: Option<String>
) -> String {
    #[cfg(target_os = "macos")]
    {
        macos_accessibility::get_accessibility_snapshot(
          target_app,
          target_window
        ).await
    }
    #[cfg(not(target_os = "macos"))]
    {
        String::from("{\"error\": \"This feature is only available on macOS\"}")
    }
}

#[derive(serde::Deserialize, serde::Serialize)]
struct UIFrameData {
    e: Vec<UIFrameElement>,
}

#[derive(serde::Deserialize, serde::Serialize, Clone, Debug)]
struct UIFrameElement {
    id: Option<String>,  // unique identifier
    e: String,  // element type
    p: Option<String>,  // path
    d: Option<u32>,  // depth
    f: Option<Vec<f64>>,  // frame [x, y, width, height]
    a: Option<std::collections::HashMap<String, String>>,  // attributes
    m: Option<Vec<String>>,  // methods (actions)
    c: Option<Vec<UIFrameElement>>,  // children
    app: Option<String>,  // app
    focused: Option<bool>,  // focused

    #[serde(skip)]
    selected_text_bounds: Option<(f64, f64, f64, f64)>  // (x, y, width, height) of selected text if any
}

impl UIFrameElement {
    // Helper method to parse and get selected text bounds
    fn get_selected_text_bounds(&self) -> Option<(f64, f64, f64, f64)> {
        if let Some(attrs) = &self.a {
            if let Some(bounds_str) = attrs.get("AXSelectedTextBounds") {
                let parts: Vec<f64> = bounds_str
                    .split(',')
                    .filter_map(|s| s.parse().ok())
                    .collect();

                if parts.len() == 4 {
                    return Some((parts[0], parts[1], parts[2], parts[3]));
                }
            }
        }
        None
    }

    // Helper method to check if this element represents our own app
    fn is_self_app(&self) -> bool {
        if let Some(app_name) = &self.app {
            app_name.to_lowercase().contains("alvea")
        } else {
            false
        }
    }
}

// Recursively collect input elements from the UI hierarchy
fn collect_input_elements(element: &UIFrameElement, elements: &mut Vec<UIFrameElement>) {
    // Check if current element is an input type
    if is_input_element(&element.e) {
        elements.push(element.clone());
    }

    // Recursively process children
    if let Some(children) = &element.c {
        for child in children {
            collect_input_elements(child, elements);
        }
    }
}

#[derive(Clone, Debug)]
struct LastSelectionContext {
    app_element: UIFrameElement,
    // window_element: UIFrameElement,
    // selection_element: UIFrameElement,
}

static LAST_SELECTION_CONTEXT: Lazy<Mutex<Option<LastSelectionContext>>> = Lazy::new(|| Mutex::new(None));

#[tauri::command]
async fn start_accessibility_polling(app_handle: tauri::AppHandle) {
    println!("Starting accessibility polling");
    IS_POLLING.store(true, Ordering::SeqCst);
    let app_handle_clone = app_handle.clone();

    tauri::async_runtime::spawn(async move {
        while IS_POLLING.load(Ordering::SeqCst) {
            // Get the last known context for targeted snapshot
            let last_context = LAST_SELECTION_CONTEXT.lock().unwrap().clone();
            // println!("Last context: {:?}", last_context);

            let (target_app) = if let Some(ctx) = &last_context {
                println!("Using last context - App: {:?}",
                    ctx.app_element.app);

                (ctx.app_element.app.clone())
            } else {
                (None)
            };

            println!("Getting accessibility snapshot");
            println!("Target app: {:?}", target_app);
            let target_window = None;
            println!("Target window: {:?}", target_window);

            if let Ok(snapshot) = serde_json::from_str::<UIFrameData>(
                &get_accessibility_snapshot(target_app, target_window).await
            ) {
                println!("Got accessibility snapshot with {} root elements", snapshot.e.len());

                let mut current_app_is_self = false;
                let mut found_text_selection = false;
                let mut input_elements = Vec::new();

                for root_element in &snapshot.e {
                    // Check if current app is self (Alvea) at root level
                    // if let Some(app_name) = &root_element.app {
                    //     println!("Root element app: {}", app_name);
                    // }
                    if root_element.is_self_app() {
                        current_app_is_self = true;
                        // println!("Current app is Alvea (self)");
                        break;
                    } else {
                        // Store the current selection context if it's not from our app
                        let mut last_context = LAST_SELECTION_CONTEXT.lock().unwrap();
                        *last_context = Some(LastSelectionContext {
                          app_element: root_element.clone(),
                          // window_element,
                          // selection_element: element.clone(),
                        });
                    }
                    collect_input_elements(root_element, &mut input_elements);
                }
                println!("Collected {} input elements", input_elements.len());

                {
                    // Manage overlay window labels.
                    let mut window_labels = OVERLAY_WINDOW_LABELS.lock().unwrap();
                    let mut current_labels = HashSet::new();

                    for (idx, element) in input_elements.iter().enumerate() {
                        // Check for text selection
                        if let Some(bounds) = element.get_selected_text_bounds() {
                            found_text_selection = true;
                            println!("Found text selection in element");

                            let label = format!("overlay_{}_selection", idx);
                            current_labels.insert(label.clone());
                            // println!("Showing overlay window: {}", label);

                            println!("Text selection bounds: x={}, y={}, width={}, height={}", 
                                bounds.0, bounds.1, bounds.2, bounds.3);

                        }
                    }

                    // Log the window labels before cleanup
                    println!("Current labels: {:?}", current_labels);
                    println!("Existing window labels: {:?}", window_labels);

                }
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }

    });
}

#[tauri::command]
async fn stop_accessibility_polling() {
    IS_POLLING.store(false, Ordering::SeqCst);
}

fn is_input_element(role: &str) -> bool {
    let input_types = [
        "AXTextField",
        "AXTextArea",
        "AXButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXSlider",
        "AXComboBox",
        "AXPopUpButton",
    ];
    input_types.iter().any(|&t| role.ends_with(t))
}

#[tauri::command]
fn perform_typing_action(element_id: String, text: String) -> Result<String, String> {
    #[cfg(target_os = "macos")]
    {
         println!("Performing typing action on element: {} with text: {}", element_id, text);
         let c_element_id = CString::new(element_id).map_err(|e| e.to_string())?;
         let c_text = CString::new(text).map_err(|e| e.to_string())?;
         unsafe {
             let result = ffi::perform_type_action(c_element_id.as_ptr(), c_text.as_ptr());
             if result.is_null() {
                 return Err("Failed to perform typing action".into());
             }
             let result_str = CStr::from_ptr(result).to_string_lossy().into_owned();
             libc::free(result as *mut libc::c_void);
             Ok(result_str)
         }
    }
    #[cfg(not(target_os = "macos"))]
    {
         Err("This feature is only available on macOS".into())
    }
}

#[tauri::command]
fn perform_named_action(element_id: String, action_name: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
         println!("Performing named action on element: {} with action: {}", element_id, action_name);
         let c_element_id = CString::new(element_id).map_err(|e| e.to_string())?;
         let c_action_name = CString::new(action_name).map_err(|e| e.to_string())?;
         unsafe {
             let result = ffi::named_action(c_element_id.as_ptr(), c_action_name.as_ptr());
             if result.is_null() {
                 return Err("Failed to perform named action".into());
             }
             let result_str = CStr::from_ptr(result).to_string_lossy().into_owned();
             libc::free(result as *mut libc::c_void);
             if result_str.contains("success") {
                 Ok(())
             } else {
                 Err(result_str)
             }
         }
    }
    #[cfg(not(target_os = "macos"))]
    {
         Err("This feature is only available on macOS".into())
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            fetch_ui_elements,
            get_accessibility_snapshot,
            start_accessibility_polling,
            stop_accessibility_polling,
            perform_typing_action,
            perform_named_action,
        ])
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_macos_permissions::init())
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
