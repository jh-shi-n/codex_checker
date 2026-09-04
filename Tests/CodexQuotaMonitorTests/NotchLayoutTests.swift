import XCTest
@testable import CodexQuotaMonitorKit

@MainActor
final class NotchLayoutTests: XCTestCase {
    func testPrimaryScreenSelectionUsesConfiguredMainDisplayInsteadOfActiveScreenOrder() {
        let displayIDs: [UInt32?] = [200, 100, 300]

        XCTAssertEqual(
            NotchGeometry.primaryScreenIndex(displayIDs: displayIDs, mainDisplayID: 100),
            1
        )
        XCTAssertEqual(
            NotchGeometry.primaryScreenIndex(displayIDs: displayIDs, mainDisplayID: 999),
            0
        )
        XCTAssertNil(NotchGeometry.primaryScreenIndex(displayIDs: [], mainDisplayID: 100))
    }

    func testScreenSelectionPrefersOnlyCandidatesWithBothAuxiliaryAreas() {
        let candidates = [
            NotchScreenCandidate(identifier: "external", auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil),
            NotchScreenCandidate(
                identifier: "partial",
                auxiliaryTopLeftArea: CGRect(x: 0, y: 0, width: 100, height: 24),
                auxiliaryTopRightArea: .zero
            ),
            NotchScreenCandidate(
                identifier: "notch",
                auxiliaryTopLeftArea: CGRect(x: 0, y: 876, width: 620, height: 24),
                auxiliaryTopRightArea: CGRect(x: 820, y: 876, width: 620, height: 24)
            ),
        ]

        XCTAssertEqual(NotchGeometry.selectScreen(from: candidates)?.identifier, "notch")
        XCTAssertNil(NotchGeometry.selectScreen(from: Array(candidates.prefix(2))))
    }

    func testAnchorsAreDerivedFromAuxiliaryTopAreas() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let leftArea = CGRect(x: 0, y: 876, width: 620, height: 24)
        let rightArea = CGRect(x: 820, y: 876, width: 620, height: 24)

        let layout = NotchGeometry.layout(
            screenFrame: screen,
            auxiliaryTopLeftArea: leftArea,
            auxiliaryTopRightArea: rightArea
        )

        XCTAssertEqual(layout.leftAnchor.x, 620)
        XCTAssertEqual(layout.rightAnchor.x, 820)
        XCTAssertEqual(layout.leftAnchor.y, 888)
        XCTAssertEqual(layout.rightAnchor.y, 888)
    }

    func testCenterBridgeUsesTheExactNotchGap() {
        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 876, width: 620, height: 24),
            auxiliaryTopRightArea: CGRect(x: 820, y: 876, width: 620, height: 24)
        )

        XCTAssertEqual(
            layout.centerBridgeFrame,
            CGRect(x: 620, y: 876, width: 200, height: 24)
        )
    }

    func testCenterBridgePanelIsSolidBlackAndDoesNotInterceptMouseEvents() {
        let panel = CenterBridgePanel()

        XCTAssertTrue(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .black)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.level, .statusBar)
    }

    func testCenterBridgeVisibilityRequiresSideContentAndFiniteGeometry() {
        let frame = CGRect(x: 620, y: 876, width: 200, height: 24)

        XCTAssertTrue(NotchPanelVisibility.isCenterBridgeDisplayable(
            leftAccountCount: 2,
            rightAccountCount: 2,
            frame: frame
        ))
        XCTAssertFalse(NotchPanelVisibility.isCenterBridgeDisplayable(
            leftAccountCount: 0,
            rightAccountCount: 0,
            frame: frame
        ))
        XCTAssertFalse(NotchPanelVisibility.isCenterBridgeDisplayable(
            leftAccountCount: 2,
            rightAccountCount: 2,
            frame: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)
        ))
    }

    func testExternalDisplayUsesACompactCenteredBridgeDerivedFromMenuBarHeight() {
        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            menuBarHeight: 24
        )

        XCTAssertEqual(layout.leftAnchor.x, 672)
        XCTAssertEqual(layout.rightAnchor.x, 768)
        XCTAssertEqual(
            layout.centerBridgeFrame,
            CGRect(x: 672, y: 876, width: 96, height: 24)
        )
    }

    func testPanelItemsKeepOuterToInnerOrderingOnBothSides() {
        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 876, width: 620, height: 24),
            auxiliaryTopRightArea: CGRect(x: 820, y: 876, width: 620, height: 24)
        )

        let leftFrames = layout.itemFrames(side: .left, itemCount: 2, diameter: 22, spacing: 5)
        let rightFrames = layout.itemFrames(side: .right, itemCount: 2, diameter: 22, spacing: 5)

        XCTAssertEqual(leftFrames.count, 2)
        XCTAssertEqual(rightFrames.count, 2)
        XCTAssertLessThan(leftFrames[0].midX, leftFrames[1].midX, "C1 must be outer and C2 notch-nearest")
        XCTAssertLessThan(rightFrames[0].midX, rightFrames[1].midX, "C3 must be notch-nearest and C4 outer")
        let diameter = layout.resolvedDiameter(side: .left, itemCount: 2, diameter: 22, spacing: 5)
        let inset = QuotaClusterMetrics.visualInset(forDiameter: diameter)
        let edgeSafety = QuotaClusterMetrics.containmentMargin
        XCTAssertEqual(leftFrames[1].maxX + inset, layout.leftAnchor.x - edgeSafety, accuracy: 0.0001)
        XCTAssertEqual(rightFrames[0].minX - inset, layout.rightAnchor.x + edgeSafety, accuracy: 0.0001)
    }

    func testPanelFramesStayWithinTheirAvailableTopAreas() {
        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 100, y: 0, width: 1_440, height: 900),
            auxiliaryTopLeftArea: CGRect(x: 100, y: 876, width: 620, height: 24),
            auxiliaryTopRightArea: CGRect(x: 920, y: 876, width: 620, height: 24)
        )

        let leftFrame = layout.contentFrame(side: .left, itemCount: 2, diameter: 22, spacing: 5)
        let rightFrame = layout.contentFrame(side: .right, itemCount: 2, diameter: 22, spacing: 5)

        XCTAssertTrue(layout.leftArea.contains(leftFrame))
        XCTAssertTrue(layout.rightArea.contains(rightFrame))
    }

    func testPanelFootprintMatchesClusterContentWithoutHiddenInsets() {
        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 876, width: 620, height: 24),
            auxiliaryTopRightArea: CGRect(x: 820, y: 876, width: 620, height: 24)
        )
        let diameter = layout.resolvedDiameter(side: .left, itemCount: 2, diameter: 22, spacing: 5)
        let expected = QuotaClusterMetrics.footprint(itemCount: 2, diameter: diameter, spacing: 5)
        let content = layout.contentFrame(side: .left, itemCount: 2, diameter: 22, spacing: 5)
        let panel = layout.panelFrame(side: .left, itemCount: 2, diameter: 22, spacing: 5)
        let items = layout.itemFrames(side: .left, itemCount: 2, diameter: 22, spacing: 5)

        let visual = QuotaClusterMetrics.visualFootprint(itemCount: 2, diameter: diameter, spacing: 5)
        let inset = QuotaClusterMetrics.visualInset(forDiameter: diameter)
        XCTAssertEqual(content.width, visual.width, accuracy: 0.0001)
        XCTAssertEqual(panel.width, visual.width + QuotaClusterMetrics.notchBridgeWidth, accuracy: 0.0001)
        XCTAssertEqual(panel.height, layout.leftArea.height, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(panel.height, expected.height + inset * 2)
        XCTAssertTrue(layout.leftArea.contains(content))
        XCTAssertTrue(items.allSatisfy {
            let visualFrame = $0.insetBy(dx: -inset, dy: -inset)
            return content.contains(visualFrame) && layout.leftArea.contains(visualFrame)
        })
    }

    func testNarrowAreasResolveDiameterSoEveryItemRemainsContained() {
        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 300, height: 900),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 876, width: 30, height: 24),
            auxiliaryTopRightArea: CGRect(x: 270, y: 876, width: 30, height: 24)
        )

        for side in [NotchSide.left, .right] {
            let diameter = layout.resolvedDiameter(side: side, itemCount: 2, diameter: 22, spacing: 5)
            let content = layout.contentFrame(side: side, itemCount: 2, diameter: 22, spacing: 5)
            let items = layout.itemFrames(side: side, itemCount: 2, diameter: 22, spacing: 5)
            let area = side == .left ? layout.leftArea : layout.rightArea

            XCTAssertLessThan(diameter, 22)
            let inset = QuotaClusterMetrics.visualInset(forDiameter: diameter)
            XCTAssertTrue(items.allSatisfy {
                let visualFrame = $0.insetBy(dx: -inset, dy: -inset)
                return content.contains(visualFrame) && area.contains(visualFrame)
            })
        }
    }

    func testZeroAndOneItemFramesAreSafeForNarrowAreas() {
        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 200, height: 900),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 876, width: 18, height: 24),
            auxiliaryTopRightArea: CGRect(x: 182, y: 876, width: 18, height: 24)
        )

        XCTAssertTrue(layout.itemFrames(side: .left, itemCount: 0).isEmpty)
        XCTAssertEqual(layout.panelFrame(side: .right, itemCount: 0), .zero)

        let one = layout.itemFrames(side: .right, itemCount: 1, diameter: 22, spacing: 5)
        let oneDiameter = layout.resolvedDiameter(side: .right, itemCount: 1, diameter: 22, spacing: 5)
        let oneInset = QuotaClusterMetrics.visualInset(forDiameter: oneDiameter)
        let oneContent = layout.contentFrame(side: .right, itemCount: 1, diameter: 22, spacing: 5)
        let onePanel = layout.panelFrame(side: .right, itemCount: 1, diameter: 22, spacing: 5)
        XCTAssertEqual(one.count, 1)
        let oneVisualFrame = one[0].insetBy(dx: -oneInset, dy: -oneInset)
        XCTAssertTrue(layout.rightArea.contains(oneVisualFrame))
        XCTAssertTrue(oneContent.contains(oneVisualFrame))
        XCTAssertEqual(onePanel.width, oneContent.width + QuotaClusterMetrics.notchBridgeWidth, accuracy: 0.0001)
        XCTAssertEqual(
            layout.panelFrame(side: .right, itemCount: 1, diameter: 22, spacing: 5, notchBridgeWidth: 0),
            oneContent
        )
    }

    func testClusterOrderingKeepsOuterAndNotchNearestIdsStable() {
        func state(_ id: String) -> AccountState {
            AccountState(id: id, remainingPercent: 80, status: .normal)
        }

        XCTAssertEqual(
            QuotaClusterView.orderedAccounts([state("C2"), state("C1")], for: .left).map(\.id),
            ["C1", "C2"]
        )
        XCTAssertEqual(
            QuotaClusterView.orderedAccounts([state("C4"), state("C3")], for: .right).map(\.id),
            ["C3", "C4"]
        )
    }

    func testShortAuxiliaryAreasUseOneResolvedDiameterForPanelItemsAndContent() {
        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 300, height: 900),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 890, width: 100, height: 10),
            auxiliaryTopRightArea: CGRect(x: 200, y: 890, width: 100, height: 10)
        )

        for side in [NotchSide.left, .right] {
            let area = side == .left ? layout.leftArea : layout.rightArea
            for itemCount in 0...2 {
                let diameter = layout.resolvedDiameter(side: side, itemCount: itemCount, diameter: 22, spacing: 5)
                let content = layout.contentFrame(side: side, itemCount: itemCount, diameter: 22, spacing: 5)
                let panel = layout.panelFrame(side: side, itemCount: itemCount, diameter: 22, spacing: 5)
                let items = layout.itemFrames(side: side, itemCount: itemCount, diameter: 22, spacing: 5)

                XCTAssertTrue(diameter.isFinite)
                XCTAssertGreaterThanOrEqual(diameter, 0)
                if itemCount == 0 {
                    XCTAssertEqual(diameter, 0)
                    XCTAssertEqual(panel, .zero)
                    XCTAssertTrue(items.isEmpty)
                } else {
                    let footprint = QuotaClusterMetrics.footprint(
                        itemCount: itemCount,
                        diameter: diameter,
                        spacing: 5
                    )
                    let visual = QuotaClusterMetrics.visualFootprint(
                        itemCount: itemCount,
                        diameter: diameter,
                        spacing: 5
                    )
                    let inset = QuotaClusterMetrics.visualInset(forDiameter: diameter)
                    XCTAssertEqual(content.width, visual.width, accuracy: 0.0001)
                    XCTAssertEqual(panel.width, visual.width + QuotaClusterMetrics.notchBridgeWidth, accuracy: 0.0001)
                    XCTAssertEqual(panel.height, area.height, accuracy: 0.0001)
                    XCTAssertGreaterThanOrEqual(panel.height, footprint.height + inset * 2)
                    XCTAssertTrue(area.contains(content))
                    XCTAssertTrue(items.allSatisfy {
                        let visualFrame = $0.insetBy(dx: -inset, dy: -inset)
                        return content.contains(visualFrame) && area.contains(visualFrame)
                    })
                }
            }
        }
    }

    func testZeroHeightOrWidthResolvesToHiddenGeometry() {
        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 200, height: 900),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 890, width: 0, height: 0),
            auxiliaryTopRightArea: CGRect(x: 200, y: 890, width: 0, height: 0)
        )

        for side in [NotchSide.left, .right] {
            XCTAssertEqual(layout.resolvedDiameter(side: side, itemCount: 1, diameter: 22, spacing: 5), 0)
            XCTAssertEqual(layout.panelFrame(side: side, itemCount: 1, diameter: 22, spacing: 5), .zero)
            XCTAssertTrue(layout.itemFrames(side: side, itemCount: 1, diameter: 22, spacing: 5).isEmpty)
        }
    }

    func testActivityToastUpdatesKeepOneStableHostingViewPerPanel() {
        let transition = SessionActivityTransition(
            accountID: "C1",
            side: .left,
            sessionID: "stable-host",
            agentLabel: "Worker",
            taskName: "Host identity",
            status: .working
        )
        let toast = SessionActivityToast(content: .transition(transition), durationSeconds: 5)
        let replacement = SessionActivityToast(
            content: .transition(
                SessionActivityTransition(
                    accountID: "C1",
                    side: .left,
                    sessionID: "replacement",
                    agentLabel: "Worker",
                    taskName: "Replacement",
                    status: .completed
                )
            ),
            durationSeconds: 5
        )

        let leftPanel = LeftQuotaPanel()
        let leftHost = leftPanel.contentView
        leftPanel.setActivityToast(toast, width: 72)
        XCTAssertTrue(leftHost === leftPanel.contentView)
        leftPanel.setActivityToast(toast, width: 144)
        XCTAssertTrue(leftHost === leftPanel.contentView)
        leftPanel.setActivityToast(replacement, width: 96)
        XCTAssertTrue(leftHost === leftPanel.contentView)
        leftPanel.setActivityToast(nil)
        XCTAssertTrue(leftHost === leftPanel.contentView)

        let rightPanel = RightQuotaPanel()
        let rightHost = rightPanel.contentView
        rightPanel.setActivityToast(toast, width: 72)
        XCTAssertTrue(rightHost === rightPanel.contentView)
        rightPanel.setActivityToast(toast, width: 144)
        XCTAssertTrue(rightHost === rightPanel.contentView)
        rightPanel.setActivityToast(replacement, width: 96)
        XCTAssertTrue(rightHost === rightPanel.contentView)
        rightPanel.setActivityToast(nil)
        XCTAssertTrue(rightHost === rightPanel.contentView)
    }

    func testPerSideVisibilityDoesNotResurrectZeroOrNonFinitePanels() {
        XCTAssertTrue(NotchPanelVisibility.isDisplayable(accountCount: 2, resolvedDiameter: 22))
        XCTAssertFalse(NotchPanelVisibility.isDisplayable(accountCount: 2, resolvedDiameter: 0))
        XCTAssertFalse(NotchPanelVisibility.isDisplayable(accountCount: 2, resolvedDiameter: .nan))
        XCTAssertFalse(NotchPanelVisibility.isDisplayable(accountCount: 0, resolvedDiameter: 22))

        // Sides remain independent: a valid right side can still display when
        // the left side has collapsed to a zero-size geometry.
        let leftDisplayable = NotchPanelVisibility.isDisplayable(accountCount: 2, resolvedDiameter: 0)
        let rightDisplayable = NotchPanelVisibility.isDisplayable(accountCount: 2, resolvedDiameter: 20)
        XCTAssertFalse(leftDisplayable)
        XCTAssertTrue(rightDisplayable)
    }

    func testAuxiliaryFramePolicyPreservesRequestedMenuBarFrame() {
        let requested = CGRect(x: 120, y: 1_131, width: 49, height: 38)
        let appKitConstrainedBelowMenuBar = CGRect(x: 120, y: 1_093, width: 49, height: 38)

        XCTAssertEqual(
            NotchPanelFramePolicy.frameAfterConstraint(
                requestedFrame: requested,
                constrainedFrame: appKitConstrainedBelowMenuBar
            ),
            requested
        )
        XCTAssertEqual(
            NotchPanelFramePolicy.frameAfterConstraint(
                requestedFrame: requested,
                constrainedFrame: appKitConstrainedBelowMenuBar.offsetBy(dx: 0, dy: -100)
            ),
            requested,
            "A specialized auxiliary panel must keep its requested global frame for every AppKit constraint pass"
        )
    }

    func testBlackPanelAppearanceAndSideSpecificOuterRoundingTokens() {
        XCTAssertEqual(NotchPanelAppearance.black.backgroundHex, "#00000000")
        XCTAssertEqual(NotchPanelAppearance.black.contentBackgroundHex, "#000000")
        XCTAssertFalse(NotchPanelAppearance.black.isOpaque)
        XCTAssertFalse(NotchPanelAppearance.black.hasShadow)
        XCTAssertEqual(NotchPanelAppearance.black.borderWidth, 0)

        let left = NotchClusterCornerRadii.forSide(.left)
        XCTAssertEqual(left.topLeading, 0)
        XCTAssertEqual(left.bottomLeading, 7)
        XCTAssertEqual(left.topTrailing, 0)
        XCTAssertEqual(left.bottomTrailing, 0)

        let right = NotchClusterCornerRadii.forSide(.right)
        XCTAssertEqual(right.topLeading, 0)
        XCTAssertEqual(right.bottomLeading, 0)
        XCTAssertEqual(right.topTrailing, 0)
        XCTAssertEqual(right.bottomTrailing, 7)
    }

    func testPanelConfigurationStaysAtStatusLevelAndAcceptsMouseRouting() {
        let panel = LeftQuotaPanel()

        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertFalse(panel.isFloatingPanel)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.acceptsMouseMovedEvents)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    }

    func testThirtyEightPointAuxiliaryAreaUsesFullHeightAndCentersDonuts() {
        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1_800, height: 1_169),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1_131, width: 850, height: 38),
            auxiliaryTopRightArea: CGRect(x: 950, y: 1_131, width: 850, height: 38)
        )

        for side in [NotchSide.left, .right] {
            let area = side == .left ? layout.leftArea : layout.rightArea
            let diameter = layout.resolvedDiameter(side: side, itemCount: 2, diameter: 22, spacing: 5)
            let content = layout.contentFrame(side: side, itemCount: 2, diameter: 22, spacing: 5)
            let panel = layout.panelFrame(side: side, itemCount: 2, diameter: 22, spacing: 5)
            let items = layout.itemFrames(side: side, itemCount: 2, diameter: 22, spacing: 5)

            XCTAssertEqual(diameter, 22)
            XCTAssertEqual(panel.height, 38)
            XCTAssertEqual(panel.midY, area.midY)
            XCTAssertEqual(
                panel.width,
                QuotaClusterMetrics.visualFootprint(itemCount: 2, diameter: diameter, spacing: 5).width + QuotaClusterMetrics.notchBridgeWidth,
                accuracy: 0.0001
            )
            XCTAssertEqual(panel.height, area.height)
            let inset = QuotaClusterMetrics.visualInset(forDiameter: diameter)
            XCTAssertTrue(area.contains(content))
            XCTAssertTrue(items.allSatisfy {
                let visualFrame = $0.insetBy(dx: -inset, dy: -inset)
                return area.contains(visualFrame) && content.contains(visualFrame)
            })
            XCTAssertTrue(items.allSatisfy { abs($0.midY - area.midY) < 0.0001 })
        }
    }

    func testNotchBridgeExtendsOnlyTowardTheCameraAndLeavesSafeContentUnchanged() {
        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1_800, height: 1_169),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1_131, width: 850, height: 38),
            auxiliaryTopRightArea: CGRect(x: 950, y: 1_131, width: 850, height: 38)
        )
        let bridge = QuotaClusterMetrics.notchBridgeWidth

        XCTAssertEqual(bridge, 8)
        for side in [NotchSide.left, .right] {
            let area = side == .left ? layout.leftArea : layout.rightArea
            let content = layout.contentFrame(side: side, itemCount: 2, diameter: 22, spacing: 5)
            let panel = layout.panelFrame(side: side, itemCount: 2, diameter: 22, spacing: 5)
            let noBridgePanel = layout.panelFrame(
                side: side,
                itemCount: 2,
                diameter: 22,
                spacing: 5,
                notchBridgeWidth: 0
            )

            XCTAssertTrue(area.contains(content))
            XCTAssertEqual(panel.width, content.width + bridge, accuracy: 0.0001)
            XCTAssertEqual(noBridgePanel, content)
            switch side {
            case .left:
                XCTAssertEqual(panel.minX, content.minX, accuracy: 0.0001)
                XCTAssertEqual(panel.maxX, content.maxX + bridge, accuracy: 0.0001)
            case .right:
                XCTAssertEqual(panel.minX, content.minX - bridge, accuracy: 0.0001)
                XCTAssertEqual(panel.maxX, content.maxX, accuracy: 0.0001)
            }

            let noBridgeItems = layout.itemFrames(
                side: side,
                itemCount: 2,
                diameter: 22,
                spacing: 5,
                notchBridgeWidth: 0
            )
            let bridgedItems = layout.itemFrames(side: side, itemCount: 2, diameter: 22, spacing: 5)
            XCTAssertEqual(bridgedItems, noBridgeItems)
            let inset = QuotaClusterMetrics.visualInset(forDiameter: layout.resolvedDiameter(side: side, itemCount: 2, diameter: 22, spacing: 5))
            XCTAssertTrue(bridgedItems.allSatisfy {
                area.contains($0.insetBy(dx: -inset, dy: -inset))
            })
        }
    }

    func testOnlyBottomOuterCornerIsRoundedForEachNotchSide() {
        let left = NotchClusterCornerRadii.forSide(.left)
        XCTAssertEqual(left.topLeading, 0)
        XCTAssertEqual(left.topTrailing, 0)
        XCTAssertEqual(left.bottomLeading, 7)
        XCTAssertEqual(left.bottomTrailing, 0)

        let right = NotchClusterCornerRadii.forSide(.right)
        XCTAssertEqual(right.topLeading, 0)
        XCTAssertEqual(right.topTrailing, 0)
        XCTAssertEqual(right.bottomLeading, 0)
        XCTAssertEqual(right.bottomTrailing, 7)
    }

    func testActivityToastExpandsOnlyTheOuterEdgeAndLeavesDonutFramesAndBridgeUnchanged() {
        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1_800, height: 1_169),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1_131, width: 850, height: 38),
            auxiliaryTopRightArea: CGRect(x: 950, y: 1_131, width: 850, height: 38)
        )
        let requestedToastWidth: CGFloat = 64

        for side in [NotchSide.left, .right] {
            let baselinePanel = layout.panelFrame(side: side, itemCount: 2, diameter: 22)
            let toastPanel = layout.panelFrame(
                side: side,
                itemCount: 2,
                diameter: 22,
                toastWidth: requestedToastWidth
            )
            let baselineItems = layout.itemFrames(side: side, itemCount: 2, diameter: 22)
            let toastItems = layout.itemFrames(
                side: side,
                itemCount: 2,
                diameter: 22,
                toastWidth: requestedToastWidth
            )
            let baseContent = layout.contentFrame(side: side, itemCount: 2, diameter: 22)

            XCTAssertEqual(toastItems, baselineItems)
            XCTAssertEqual(toastPanel.height, baselinePanel.height, accuracy: 0.0001)
            XCTAssertEqual(toastPanel.width - baselinePanel.width, requestedToastWidth, accuracy: 0.0001)

            switch side {
            case .left:
                XCTAssertEqual(toastPanel.maxX, baselinePanel.maxX, accuracy: 0.0001)
                XCTAssertEqual(toastPanel.minX, baselinePanel.minX - requestedToastWidth, accuracy: 0.0001)
                XCTAssertEqual(toastPanel.maxX, baseContent.maxX + QuotaClusterMetrics.notchBridgeWidth, accuracy: 0.0001)
            case .right:
                XCTAssertEqual(toastPanel.minX, baselinePanel.minX, accuracy: 0.0001)
                XCTAssertEqual(toastPanel.maxX, baselinePanel.maxX + requestedToastWidth, accuracy: 0.0001)
                XCTAssertEqual(toastPanel.minX, baseContent.minX - QuotaClusterMetrics.notchBridgeWidth, accuracy: 0.0001)
            }
        }
    }

    func testActivityToastExpansionClampsAtTheOutwardAuxiliaryEdgeOnNarrowAreas() {
        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 240, height: 900),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 876, width: 70, height: 24),
            auxiliaryTopRightArea: CGRect(x: 170, y: 876, width: 70, height: 24)
        )

        for side in [NotchSide.left, .right] {
            let baseline = layout.panelFrame(side: side, itemCount: 1, diameter: 22)
            let expanded = layout.panelFrame(
                side: side,
                itemCount: 1,
                diameter: 22,
                toastWidth: 500
            )
            let area = side == .left ? layout.leftArea : layout.rightArea
            let itemFrames = layout.itemFrames(side: side, itemCount: 1, diameter: 22, toastWidth: 500)

            XCTAssertGreaterThanOrEqual(expanded.width, baseline.width)
            XCTAssertTrue(expanded.minX.isFinite && expanded.maxX.isFinite)
            XCTAssertTrue(itemFrames.allSatisfy { area.contains($0.insetBy(dx: -QuotaClusterMetrics.visualInset(forDiameter: 22), dy: -QuotaClusterMetrics.visualInset(forDiameter: 22))) })
            switch side {
            case .left:
                XCTAssertGreaterThanOrEqual(expanded.minX, area.minX)
                XCTAssertEqual(expanded.maxX, baseline.maxX, accuracy: 0.0001)
            case .right:
                XCTAssertLessThanOrEqual(expanded.maxX, area.maxX)
                XCTAssertEqual(expanded.minX, baseline.minX, accuracy: 0.0001)
            }
        }
    }

    func testZeroActivityToastWidthPreservesTheExistingPanelFrame() {
        let layout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1_800, height: 1_169),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1_131, width: 850, height: 38),
            auxiliaryTopRightArea: CGRect(x: 950, y: 1_131, width: 850, height: 38)
        )

        for side in [NotchSide.left, .right] {
            XCTAssertEqual(
                layout.panelFrame(side: side, itemCount: 2, diameter: 22),
                layout.panelFrame(side: side, itemCount: 2, diameter: 22, toastWidth: 0)
            )
            XCTAssertEqual(
                layout.panelFrame(side: side, itemCount: 2, diameter: 22, toastWidth: -.infinity),
                layout.panelFrame(side: side, itemCount: 2, diameter: 22)
            )
        }
    }
}
