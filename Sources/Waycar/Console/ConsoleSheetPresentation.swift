import SwiftUI

/// Resolve against the presenting view, since a form may itself be compact.
enum ConsoleSheetPresentation: Equatable {
    case form
    case inheritedSheet

    init(horizontalSizeClass: UserInterfaceSizeClass?) {
        self = horizontalSizeClass == .regular ? .form : .inheritedSheet
    }
}

struct ConsoleSheetPresentationModifier: ViewModifier {
    let presentation: ConsoleSheetPresentation
    /// Takes a page's height instead of a form's, keeping the form's width,
    /// for a sheet that lists everything it has at once.
    var isTall = false

    func body(content: Content) -> some View {
        Group {
            switch presentation {
            case .form:
                if isTall {
                    content.presentationSizing(TallFormPresentationSizing())
                } else {
                    content.presentationSizing(.form)
                }
            case .inheritedSheet:
                // Keep each destination's existing detents (including Rename's medium sheet).
                content
            }
        }
        .modifier(SampleContextModifier())
    }
}

/// A form's width with a page's height.
private struct TallFormPresentationSizing: PresentationSizing {
    func proposedSize(
        for root: PresentationSizingRoot, context: PresentationSizingContext
    ) -> ProposedViewSize {
        let form = FormPresentationSizing.form.proposedSize(for: root, context: context)
        let page = PagePresentationSizing.page.proposedSize(for: root, context: context)
        return ProposedViewSize(width: form.width, height: page.height)
    }
}
