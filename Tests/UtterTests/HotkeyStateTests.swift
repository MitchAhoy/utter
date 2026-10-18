import XCTest
@testable import Utter

final class HotkeyStateTests: XCTestCase {
    func testRightOptionPressAndRelease() {
        var state = HotkeyState()
        XCTAssertEqual(state.update(keyCode: 61, pressed: true, choice: .rightOption), .down)
        XCTAssertEqual(state.update(keyCode: 61, pressed: false, choice: .rightOption), .up)
    }
    func testLeftOptionDoesNotTrigger() {
        var state = HotkeyState()
        XCTAssertNil(state.update(keyCode: 58, pressed: true, choice: .rightOption))
        XCTAssertFalse(state.isDown)
    }
    func testOtherModifierCannotReleaseRightOption() {
        var state = HotkeyState()
        _ = state.update(keyCode: 61, pressed: true, choice: .rightOption)
        XCTAssertNil(state.update(keyCode: 58, pressed: false, choice: .rightOption))
        XCTAssertTrue(state.isDown)
    }
    func testRepeatedDownIsIgnored() {
        var state = HotkeyState()
        XCTAssertEqual(state.transition(pressed: true), .down)
        XCTAssertNil(state.transition(pressed: true))
    }
    func testOrphanReleaseIsIgnored() {
        var state = HotkeyState()
        XCTAssertNil(state.transition(pressed: false))
    }
    func testRightCommandCode() {
        var state = HotkeyState()
        XCTAssertNil(state.update(keyCode: 55, pressed: true, choice: .rightCommand))
        XCTAssertEqual(state.update(keyCode: 54, pressed: true, choice: .rightCommand), .down)
        XCTAssertEqual(state.update(keyCode: 54, pressed: false, choice: .rightCommand), .up)
    }
    func testFnCode() {
        var state = HotkeyState()
        XCTAssertEqual(state.update(keyCode: 63, pressed: true, choice: .fn), .down)
        XCTAssertEqual(state.update(keyCode: 63, pressed: false, choice: .fn), .up)
    }
    func testResetAllowsFreshPress() {
        var state = HotkeyState()
        _ = state.transition(pressed: true)
        state.reset()
        XCTAssertEqual(state.transition(pressed: true), .down)
    }
    func testRapidPressesProduceBalancedEdges() {
        var state = HotkeyState()
        for _ in 0..<1000 {
            XCTAssertEqual(state.transition(pressed: true), .down)
            XCTAssertEqual(state.transition(pressed: false), .up)
        }
    }
}
