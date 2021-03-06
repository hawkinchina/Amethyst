//
//  ScreenManager.swift
//  Amethyst
//
//  Created by Ian Ynda-Hummel on 12/23/15.
//  Copyright © 2015 Ian Ynda-Hummel. All rights reserved.
//

import Foundation
import Silica

protocol ScreenManagerDelegate: class {
    associatedtype Window: WindowType
    func activeWindowSet(forScreenManager screenManager: ScreenManager<Self>) -> WindowSet<Window>
}

final class ScreenManager<Delegate: ScreenManagerDelegate>: NSObject {
    typealias Window = Delegate.Window
    typealias Screen = Window.Screen

    private(set) var screen: Screen
    private(set) var space: Space?

    /// The last window that has been focused on the screen. This value is updated by the notification observations in
    /// `ObserveApplicationNotifications`.
    private(set) var lastFocusedWindow: Window?
    private weak var delegate: Delegate?
    private let userConfiguration: UserConfiguration
    var onReflowInitiation: (() -> Void)?
    var onReflowCompletion: (() -> Void)?

    private var reflowOperation: Operation?

    private var layouts: [Layout<Window>] = []
    private var currentLayoutIndexBySpaceUUID: [String: Int] = [:]
    private var layoutsBySpaceUUID: [String: [Layout<Window>]] = [:]
    private var currentLayoutIndex: Int = 0
    var currentLayout: Layout<Window>? {
        guard !layouts.isEmpty else {
            return nil
        }
        return layouts[currentLayoutIndex]
    }

    private let layoutNameWindowController: LayoutNameWindowController

    init(screen: Screen, delegate: Delegate, userConfiguration: UserConfiguration) {
        self.screen = screen
        self.delegate = delegate
        self.userConfiguration = userConfiguration

        layoutNameWindowController = LayoutNameWindowController(windowNibName: "LayoutNameWindow")

        super.init()

        layouts = LayoutManager.layoutsWithConfiguration(userConfiguration)
    }

    deinit {
        self.onReflowInitiation = nil
        self.onReflowCompletion = nil
    }

    func updateScreen(to screen: Screen) {
        self.screen = screen
    }

    func updateSpace(to space: Space) {
        if let currentSpace = self.space {
            currentLayoutIndexBySpaceUUID[currentSpace.uuid] = currentLayoutIndex
        }

        defer {
            setNeedsReflow(withWindowChange: .spaceChange)
        }

        self.space = space

        setCurrentLayoutIndex(currentLayoutIndexBySpaceUUID[space.uuid] ?? 0, changingSpace: true)

        if let layouts = layoutsBySpaceUUID[space.uuid] {
            self.layouts = layouts
        } else {
            self.layouts = LayoutManager.layoutsWithConfiguration(userConfiguration)
            layoutsBySpaceUUID[space.uuid] = layouts
        }
    }

    func setNeedsReflow(withWindowChange windowChange: Change<Window>) {
        switch windowChange {
        case let .add(window: window):
            lastFocusedWindow = window
        case let .focusChanged(window):
            lastFocusedWindow = window
        case let .remove(window):
            if lastFocusedWindow == window {
                lastFocusedWindow = nil
            }
        case .windowSwap:
            break
        case .spaceChange:
            break
        case .unknown:
            break
        }

        reflowOperation?.cancel()

        log.debug("Screen: \(screen.screenID() ?? "unknown") -- Window Change: \(windowChange)")

        if let statefulLayout = currentLayout as? StatefulLayout {
            statefulLayout.updateWithChange(windowChange)
        }

        DispatchQueue.main.async {
            self.reflow(windowChange)
        }
    }

    private func reflow(_ event: Change<Window>) {
        guard userConfiguration.tilingEnabled, space?.type == CGSSpaceTypeUser else {
            return
        }

        guard let windows = delegate?.activeWindowSet(forScreenManager: self) else {
            return
        }

        guard let layout = currentLayout else {
            return
        }

        let reflowOperation = ReflowOperation(screen: screen, windowSet: windows, layout: layout)
        reflowOperation.completionBlock = { [weak self, weak reflowOperation] in
            guard let isCancelled = reflowOperation?.isCancelled, !isCancelled else {
                return
            }

            self?.onReflowCompletion?()
        }
        onReflowInitiation?()
        OperationQueue.main.addOperation(reflowOperation)
    }

    func updateCurrentLayout(_ updater: (Layout<Window>) -> Void) {
        guard let layout = currentLayout else {
            return
        }
        updater(layout)
        setNeedsReflow(withWindowChange: .unknown)
    }

    func cycleLayoutForward() {
        setCurrentLayoutIndex((currentLayoutIndex + 1) % layouts.count)
        setNeedsReflow(withWindowChange: .unknown)
    }

    func cycleLayoutBackward() {
        setCurrentLayoutIndex((currentLayoutIndex == 0 ? layouts.count : currentLayoutIndex) - 1)
        setNeedsReflow(withWindowChange: .unknown)
    }

    func selectLayout(_ layoutString: String) {
        guard let layoutIndex = layouts.index(where: { type(of: $0).layoutKey == layoutString }) else {
            return
        }

        setCurrentLayoutIndex(layoutIndex)
        setNeedsReflow(withWindowChange: .unknown)
    }

    private func setCurrentLayoutIndex(_ index: Int, changingSpace: Bool = false) {
        guard (0..<layouts.count).contains(index) else {
            return
        }

        currentLayoutIndex = index

        guard !changingSpace || userConfiguration.enablesLayoutHUDOnSpaceChange() else {
            return
        }

        displayLayoutHUD()
    }

    func shrinkMainPane() {
        guard let panedLayout = currentLayout as? PanedLayout else {
            return
        }
        panedLayout.shrinkMainPane()
    }

    func expandMainPane() {
        guard let panedLayout = currentLayout as? PanedLayout else {
            return
        }
        panedLayout.expandMainPane()
    }

    func nextWindowIDCounterClockwise() -> Window.WindowID? {
        guard let layout = currentLayout as? StatefulLayout else {
            return nil
        }

        return layout.nextWindowIDCounterClockwise()
    }

    func nextWindowIDClockwise() -> Window.WindowID? {
        guard let statefulLayout = currentLayout as? StatefulLayout else {
            return nil
        }

        return statefulLayout.nextWindowIDClockwise()
    }

    func displayLayoutHUD() {
        guard userConfiguration.enablesLayoutHUD(), space?.type == CGSSpaceTypeUser else {
            return
        }

        defer {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideLayoutHUD(_:)), object: nil)
            perform(#selector(hideLayoutHUD(_:)), with: nil, afterDelay: 0.6)
        }

        guard let layoutNameWindow = layoutNameWindowController.window as? LayoutNameWindow else {
            return
        }

        let screenFrame = screen.frameIncludingDockAndMenu()
        let screenCenter = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
        let windowOrigin = CGPoint(
            x: screenCenter.x - layoutNameWindow.frame.width / 2.0,
            y: screenCenter.y - layoutNameWindow.frame.height / 2.0
        )

        layoutNameWindow.layoutNameField?.stringValue = currentLayout.flatMap({ type(of: $0).layoutName }) ?? "None"
        layoutNameWindow.layoutDescriptionLabel?.stringValue = currentLayout?.layoutDescription ?? ""
        layoutNameWindow.setFrameOrigin(NSPointFromCGPoint(windowOrigin))

        layoutNameWindowController.showWindow(self)
    }

    @objc func hideLayoutHUD(_ sender: AnyObject) {
        layoutNameWindowController.close()
    }
}

extension ScreenManager: Comparable {
    static func < (lhs: ScreenManager<Delegate>, rhs: ScreenManager<Delegate>) -> Bool {
        let originX1 = lhs.screen.frameWithoutDockOrMenu().origin.x
        let originX2 = rhs.screen.frameWithoutDockOrMenu().origin.x

        return originX1 < originX2
    }
}

extension WindowManager: ScreenManagerDelegate {
    func activeWindowSet(forScreenManager screenManager: ScreenManager<WindowManager<Application>>) -> WindowSet<Window> {
        return windows.windowSet(forActiveWindowsOnScreen: screenManager.screen)
    }
}
