//
//  OutputLimitsTests.swift
//  AudioRouterKitTests
//
//  Prueft OutputLimits-Konstanten, AddDecision und validateOutputCount (NT-S2).
//

import XCTest
@testable import AudioRouterKit

final class OutputLimitsTests: XCTestCase {

    func testCapacityIs256AndConfiguredLimitIs255() {
        XCTAssertEqual(OutputLimits.maxSlots, 256)
        XCTAssertEqual(OutputLimits.maxConfiguredOutputs, 255)
        XCTAssertEqual(OutputLimits.maxConfiguredOutputs, OutputLimits.maxSlots - 1)
    }

    func testAddAllowedBelowLimit() {
        for count in [0, 16, 17, 100, 254] {
            XCTAssertEqual(
                OutputLimits.addDecision(currentCount: count, alreadyConfigured: false),
                .allowed,
                "count \(count) sollte .allowed sein"
            )
        }
    }

    func testAddAtLimitIsRejectedWithMax() {
        XCTAssertEqual(
            OutputLimits.addDecision(currentCount: 255, alreadyConfigured: false),
            .limitReached(max: 255)
        )
        XCTAssertEqual(
            OutputLimits.addDecision(currentCount: 300, alreadyConfigured: false),
            .limitReached(max: 255)
        )
    }

    func testDuplicateWinsOverLimit() {
        XCTAssertEqual(
            OutputLimits.addDecision(currentCount: 255, alreadyConfigured: true),
            .duplicate
        )
    }

    func testNegativeCountIsAllowed() {
        XCTAssertEqual(
            OutputLimits.addDecision(currentCount: -1, alreadyConfigured: false),
            .allowed
        )
    }

    func testValidateOutputCountBoundary() {
        XCTAssertNoThrow(try OutputLimits.validateOutputCount(0))
        XCTAssertNoThrow(try OutputLimits.validateOutputCount(255))
        XCTAssertThrowsError(try OutputLimits.validateOutputCount(256)) { error in
            if case RouterError.tooManyOutputs(let count, let max) = error {
                XCTAssertEqual(count, 256)
                XCTAssertEqual(max, 255)
            } else {
                XCTFail("Falscher Fehlertyp: \(error)")
            }
        }
    }

    func testLimitMessageContainsNumberAndNoDash() {
        let msg = OutputLimits.limitMessage(max: 255)
        XCTAssertTrue(msg.contains("255"), "Meldung muss '255' enthalten")
        // Kein Em-Dash (U+2014) und kein En-Dash (U+2013)
        XCTAssertFalse(msg.contains("\u{2014}"), "Kein Em-Dash in der Meldung")
        XCTAssertFalse(msg.contains("\u{2013}"), "Kein En-Dash in der Meldung")
    }

    func testTooManyOutputsDescription() {
        let desc = RouterError.tooManyOutputs(count: 300, max: 255).errorDescription
        XCTAssertTrue(desc?.contains("300") == true, "Beschreibung muss count '300' enthalten")
        XCTAssertTrue(desc?.contains("255") == true, "Beschreibung muss max '255' enthalten")
    }
}
