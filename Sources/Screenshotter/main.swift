import AppKit

if CommandLine.arguments.contains(TextRecognition.compileArgument) {
    exit(TextRecognition.modelWorks() ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
