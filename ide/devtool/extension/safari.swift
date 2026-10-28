// Safari only loads web extensions from inside an app, so the build compiles this
// file twice: as the container app (SAFARI_APP) and as the extension (SAFARI_EXTENSION).
import SafariServices

#if SAFARI_APP
import AppKit

@main
enum App {
    // Launching the app registers the extension; then jump straight to its settings.
    static func main() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: "dev.ziex.devtools.Extension") { _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        NSApplication.shared.run()
    }
}
#endif

#if SAFARI_EXTENSION
// Required principal class; the extension has no native messaging.
@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: nil)
    }
}
#endif
