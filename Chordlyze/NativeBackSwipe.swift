import SwiftUI

private struct NativeBackSwipeEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Active capture screens can keep their explicit exit button while
    /// preventing an accidental interactive departure.
    var nativeBackSwipeEnabled: Bool {
        get { self[NativeBackSwipeEnabledKey.self] }
        set { self[NativeBackSwipeEnabledKey.self] = newValue }
    }
}

extension View {
    /// Restores the system's edge-driven, cancellable back transition for a
    /// custom back control. It does not add a competing drag gesture.
    @ViewBuilder
    func nativeBackSwipe(isEnabled: Bool = true) -> some View {
        #if canImport(UIKit)
        background(NativeBackSwipeProbe(isEnabled: isEnabled).allowsHitTesting(false))
        #else
        self
        #endif
    }
}

#if canImport(UIKit)
import UIKit
import ObjectiveC

private struct NativeBackSwipeProbe: UIViewControllerRepresentable {
    var isEnabled: Bool

    func makeUIViewController(context: Context) -> NativeBackSwipeController {
        NativeBackSwipeController(isEnabled: isEnabled)
    }

    func updateUIViewController(_ controller: NativeBackSwipeController, context: Context) {
        controller.isSwipeEnabled = isEnabled
        controller.connect()
    }

    static func dismantleUIViewController(_ controller: NativeBackSwipeController, coordinator: ()) {
        controller.disconnect()
    }
}

/// A probe belongs to its containing navigation entry, rather than whichever
/// navigation controller happens to be visible in the application's window.
@MainActor
private final class NativeBackSwipeController: UIViewController {
    var isSwipeEnabled: Bool
    private var owner: NativeBackSwipeOwner?

    init(isEnabled: Bool) {
        isSwipeEnabled = isEnabled
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        self.view = view
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil { disconnect() } else { connect() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // SwiftUI can configure the navigation item's gesture after mounting
        // children, so take ownership again once its appearance is complete.
        connect()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        owner?.updateOwnership()
    }

    func connect() {
        guard let navigation = navigationController else { return }
        if owner?.navigation !== navigation {
            disconnect()
            owner = NativeBackSwipeOwner.owner(for: navigation)
        }
        owner?.register(self)
    }

    func disconnect() {
        owner?.unregister(self)
        owner = nil
    }

    func belongs(to entry: UIViewController) -> Bool {
        var ancestor: UIViewController? = self
        while let candidate = ancestor {
            if candidate === entry { return true }
            ancestor = candidate.parent
        }
        return false
    }
}

/// One owner per navigation controller means nested/custom back controls do
/// not replace each other's delegates. Registrations are weak and are scoped
/// to the current top entry when deciding whether a gesture may begin.
@MainActor
private final class NativeBackSwipeOwner: NSObject, UIGestureRecognizerDelegate {
    private static var associationKey: UInt8 = 0

    private struct Registration {
        weak var controller: NativeBackSwipeController?
    }

    weak var navigation: UINavigationController?
    private var registrations: [ObjectIdentifier: Registration] = [:]
    private weak var recognizer: UIGestureRecognizer?
    private weak var originalDelegate: (any UIGestureRecognizerDelegate)?
    private weak var originalEntry: UIViewController?
    private var originalEnabled = false

    static func owner(for navigation: UINavigationController) -> NativeBackSwipeOwner {
        if let owner = objc_getAssociatedObject(navigation, &associationKey) as? NativeBackSwipeOwner {
            return owner
        }
        let owner = NativeBackSwipeOwner(navigation: navigation)
        objc_setAssociatedObject(navigation, &associationKey, owner, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return owner
    }

    private init(navigation: UINavigationController) {
        self.navigation = navigation
        super.init()
    }

    func register(_ controller: NativeBackSwipeController) {
        registrations = registrations.filter { $0.value.controller != nil }
        registrations[ObjectIdentifier(controller)] = Registration(controller: controller)
        updateOwnership()
    }

    func unregister(_ controller: NativeBackSwipeController) {
        registrations.removeValue(forKey: ObjectIdentifier(controller))
        registrations = registrations.filter { $0.value.controller != nil }
        guard registrations.isEmpty else {
            updateOwnership()
            return
        }
        restoreOwnership()
        if let navigation,
           objc_getAssociatedObject(navigation, &Self.associationKey) as? NativeBackSwipeOwner === self {
            objc_setAssociatedObject(navigation, &Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    private var currentControls: [NativeBackSwipeController] {
        guard let entry = navigation?.topViewController else { return [] }
        return registrations.values.compactMap(\.controller).filter { $0.belongs(to: entry) }
    }

    func updateOwnership() {
        guard let navigation, !currentControls.isEmpty, navigation.isNavigationBarHidden,
              let gesture = navigation.interactivePopGestureRecognizer else {
            restoreOwnership()
            return
        }
        if recognizer !== gesture {
            restoreOwnership()
            recognizer = gesture
        }
        if gesture.delegate !== self {
            // Adopt a newly installed system delegate rather than restoring a
            // stale one after SwiftUI has reconfigured navigation.
            originalDelegate = gesture.delegate
            originalEntry = navigation.topViewController
            originalEnabled = gesture.isEnabled
            gesture.delegate = self
        }
        gesture.isEnabled = true
    }

    private func restoreOwnership() {
        // Another owner may have deliberately replaced us. Never undo it.
        if let recognizer, recognizer.delegate === self {
            recognizer.delegate = originalDelegate
            // A different entry may have already configured its own enabled
            // state. Restore the snapshot only on the entry it came from.
            if navigation?.topViewController === originalEntry {
                recognizer.isEnabled = originalEnabled
            }
        }
        recognizer = nil
        originalDelegate = nil
        originalEntry = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === recognizer, let navigation,
              navigation.viewControllers.count > 1,
              navigation.viewIfLoaded?.window != nil,
              navigation.transitionCoordinator == nil,
              !navigation.isBeingDismissed, !navigation.isBeingPresented,
              navigation.presentedViewController == nil,
              let top = navigation.topViewController,
              top.presentedViewController == nil else { return false }
        let controls = currentControls
        let systemAllows = originalDelegate?.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true
        guard !controls.isEmpty else { return systemAllows }
        guard controls.allSatisfy(\.isSwipeEnabled) else { return false }
        // A hidden system bar rejects the normal edge pop even though the
        // custom back button can leave. Public transition/presentation guards
        // above keep that override scoped to a stable, pushed screen.
        return systemAllows || navigation.isNavigationBarHidden
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        originalDelegate?.gestureRecognizer?(gestureRecognizer, shouldReceive: touch) ?? true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        originalDelegate?.gestureRecognizer?(gestureRecognizer, shouldReceive: event) ?? true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        originalDelegate?.gestureRecognizer?(gestureRecognizer, shouldReceive: press) ?? true
    }

    // Forward only the documented delegate contract. Forwarding every selector
    // would also inherit UIKit's internal hidden-navigation-bar vetoes.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        originalDelegate?.gestureRecognizer?(gestureRecognizer,
                                            shouldRecognizeSimultaneouslyWith: otherGestureRecognizer) ?? false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        originalDelegate?.gestureRecognizer?(gestureRecognizer,
                                            shouldRequireFailureOf: otherGestureRecognizer) ?? false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        originalDelegate?.gestureRecognizer?(gestureRecognizer,
                                            shouldBeRequiredToFailBy: otherGestureRecognizer) ?? false
    }
}
#endif
