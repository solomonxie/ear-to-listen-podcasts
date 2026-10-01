#if DEBUG
import SwiftUI

/// Testing only, compiled out of Release: shows the app as the China storefront would,
/// on a phone signed into any Apple ID.
struct StorefrontOverrideRow: View {
    var onChange: () -> Void

    @AppStorage(AppStorefront.overrideKey) private var override = ""

    var body: some View {
        Picker("Storefront (testing)", selection: $override) {
            Text("As installed").tag("")
            Text("Force China").tag(AppStorefront.chinaCode)
            Text("Force non-China").tag("USA")
        }
        .pickerStyle(.menu)
        .font(.footnote)
        .onChange(of: override) { _, _ in onChange() }
    }
}
#endif
