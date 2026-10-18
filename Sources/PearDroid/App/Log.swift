import Foundation

/// Minimal unbuffered logger. `print` is block-buffered when stdout is a pipe,
/// which hides output when the app is launched from a terminal and killed, so
/// diagnostics go straight to stderr.
func pdLog(_ message: String) {
    FileHandle.standardError.write(Data(("PearDroid: " + message + "\n").utf8))
}
