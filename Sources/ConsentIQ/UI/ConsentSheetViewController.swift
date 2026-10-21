#if canImport(UIKit)
import UIKit
import SwiftUI
import Combine

@MainActor
public final class ConsentSheetViewController: UIHostingController<ConsentSheetContent>, UIAdaptivePresentationControllerDelegate {
    private let consentIQ: ConsentIQ
    private var cancellable: AnyCancellable?

    public init(consentIQ: ConsentIQ = .shared) {
        self.consentIQ = consentIQ
        super.init(rootView: ConsentSheetContent(consentIQ: consentIQ))
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presentationController?.delegate = self
    }

    @available(*, unavailable)
    required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("ConsentSheetViewController does not support storyboards")
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        if let palette = SheetPalette(banner: consentIQ.config?.banner) {
            view.backgroundColor = UIColor(palette.background.color)
            overrideUserInterfaceStyle = palette.isDark ? .dark : .light
        }
        cancellable = consentIQ.$isSheetVisible
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                guard let self, !visible, presentingViewController != nil else { return }
                dismiss(animated: true)
            }
    }

    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        consentIQ.dismissSheet()
    }
}

public extension ConsentIQ {
    func presentSheet(from presenter: UIViewController, animated: Bool = true) {
        guard isTcfActive else {
            presentNativeSheet(from: presenter, animated: animated)
            return
        }
        startTcf(reopen: true, presenter: presenter) { [weak self, weak presenter] in
            guard let self, let presenter else { return }
            presentNativeSheet(from: presenter, animated: animated)
        }
    }

    func presentPrivacyChoices(from presenter: UIViewController, animated: Bool = true) {
        presentSheet(from: presenter, animated: animated)
    }

    private func presentNativeSheet(from presenter: UIViewController, animated: Bool) {
        if !isSheetVisible {
            openNativeSheet()
        }
        presenter.present(ConsentSheetViewController(consentIQ: self), animated: animated)
    }
}
#endif
