import JUDAS
import SwiftUI

enum JudasLinks {
    static func open(_ url: URL, offGrid: Bool = false) -> OpenURLAction.Result {
        Judas.shared.authorizePreview(url, offGrid: offGrid) ? .systemAction : .discarded
    }
}

extension View {
    func judasLinks(offGrid: Bool = false) -> some View {
        environment(\.openURL, OpenURLAction { JudasLinks.open($0, offGrid: offGrid) })
    }
}
