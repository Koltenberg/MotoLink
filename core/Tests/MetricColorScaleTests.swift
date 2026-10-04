import Foundation
import XCTest
@testable import MotoLinkCore

final class MetricColorScaleTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "MotoLink.MetricColorScaleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testExactSpeed128HasInclusiveBoundariesWithoutRoundingToTen() {
        let scale = MetricColorScale(orangeStart: 128, redStart: 160, maximum: 210)
        XCTAssertTrue(scale.errors(for: .speed).isEmpty)
        XCTAssertEqual(scale.zone(at: 127.999), .green)
        XCTAssertEqual(scale.zone(at: 128), .orange)
        XCTAssertEqual(scale.zone(at: 159.999), .orange)
        XCTAssertEqual(scale.zone(at: 160), .red)
        XCTAssertEqual(scale.zone(at: 511), .red)
    }

    func testTemperatureCanTurnRedAtTwoDegreesAndAcceptNegativeThresholds() {
        let scale = MetricColorScale(orangeStart: -2, redStart: 2, maximum: 120)
        for kind in [MetricColorKind.coolantTemperature, .inletTemperature] {
            XCTAssertTrue(scale.errors(for: kind).isEmpty)
            XCTAssertEqual(scale.zone(at: -40), .green)
            XCTAssertEqual(scale.zone(at: -2), .orange)
            XCTAssertEqual(scale.zone(at: 2), .red)
        }
    }

    func testEqualBoundariesRemoveOrangeAndRedWinsEvenAtSensorMinimum() {
        for kind in MetricColorKind.allCases {
            let minimum = kind.settingRange.lowerBound
            let scale = MetricColorScale(orangeStart: minimum, redStart: minimum,
                                         maximum: kind.settingRange.upperBound)
            XCTAssertTrue(scale.errors(for: kind).isEmpty, kind.rawValue)
            XCTAssertEqual(scale.zone(at: Double(minimum)), .red, kind.rawValue)
            XCTAssertEqual(scale.zone(at: Double(minimum) + 1), .red, kind.rawValue)
        }
    }

    func testSettingsCoverTheWholeDecodedIntegerRange() {
        XCTAssertEqual(MetricColorKind.speed.settingRange, 0...511)
        XCTAssertEqual(MetricColorKind.engineSpeed.settingRange, 0...32767)
        XCTAssertEqual(MetricColorKind.coolantTemperature.settingRange, -40...214)
        XCTAssertEqual(MetricColorKind.inletTemperature.settingRange, -40...214)
        XCTAssertEqual(MetricColorKind.throttle.settingRange, 0...100)
        XCTAssertEqual(MetricColorKind.gear.settingRange, 0...6)
        XCTAssertEqual(MetricColorKind.voltage.settingRange, 0...20)
        for kind in MetricColorKind.allCases {
            let range = kind.settingRange
            let scale = MetricColorScale(orangeStart: range.lowerBound, redStart: range.upperBound,
                                         maximum: range.upperBound)
            XCTAssertTrue(scale.errors(for: kind).isEmpty, kind.rawValue)
            var tooLow = scale; tooLow.orangeStart -= 1
            XCTAssertNotNil(tooLow.errors(for: kind)[.orangeStart], kind.rawValue)
            var tooHigh = scale; tooHigh.redStart += 1
            XCTAssertNotNil(tooHigh.errors(for: kind)[.redStart], kind.rawValue)
            tooHigh = scale; tooHigh.maximum += 1
            XCTAssertNotNil(tooHigh.errors(for: kind)[.maximum], kind.rawValue)
        }
    }

    func testOrderingAndEmptyScaleAreRejectedAtTheRelevantField() {
        XCTAssertNotNil(MetricColorScale(orangeStart: 160, redStart: 128, maximum: 210)
            .errors(for: .speed)[.redStart])
        XCTAssertNotNil(MetricColorScale(orangeStart: 128, redStart: 160, maximum: 159)
            .errors(for: .speed)[.maximum])
        XCTAssertNotNil(MetricColorScale(orangeStart: -40, redStart: -40, maximum: -40)
            .errors(for: .coolantTemperature)[.maximum])
    }

    func testChosenMaximumControlsGaugeExtentAndProgressClampsAtEnds() {
        let speed = MetricColorScale(orangeStart: 128, redStart: 160, maximum: 210)
        XCTAssertEqual(speed.progress(at: 105, for: .speed)!, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(speed.progress(at: -1, for: .speed), 0)
        XCTAssertEqual(speed.progress(at: 211, for: .speed), 1)
        let temperature = MetricColorScale(orangeStart: 0, redStart: 2, maximum: 60)
        XCTAssertEqual(temperature.progress(at: 10, for: .coolantTemperature)!, 0.5, accuracy: 0.000_001)
        let rpm = MetricColorScale(orangeStart: 9875, redStart: 9876, maximum: 10000)
        XCTAssertEqual(rpm.progress(at: 5000, for: .engineSpeed)!, 0.5, accuracy: 0.000_001)
    }

    func testMissingNonFiniteValuesNeverAcquireAColorOrGaugeProgress() {
        let scale = MetricColorKind.speed.defaultScale
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(scale.zone(at: value))
            XCTAssertNil(scale.progress(at: value, for: .speed))
        }
        XCTAssertNil(MetricColorScale(orangeStart: 1, redStart: 2, maximum: 0)
            .progress(at: 1, for: .speed))
    }

    func testDraftKeepsExactIntegersAndUnicodeMinus() {
        var draft = MetricColorDraft(MetricColorKind.speed.defaultScale)
        draft[.orangeStart] = " 128 "
        draft[.redStart] = "160"
        XCTAssertEqual(draft.validation(for: .speed).scale?.orangeStart, 128)
        draft[.orangeStart] = "127"
        XCTAssertEqual(draft.validation(for: .speed).scale?.orangeStart, 127)
        XCTAssertEqual(draft.validation(for: .speed).scale?.redStart, 160)
        draft = MetricColorDraft(MetricColorKind.inletTemperature.defaultScale)
        draft[.orangeStart] = "−2"
        draft[.redStart] = "2"
        XCTAssertEqual(draft.validation(for: .inletTemperature).scale?.orangeStart, -2)
    }

    func testIncompleteDecimalAndOverflowDraftsCannotReplaceSavedSettings() {
        for text in ["", "-", "128.5", "1e2", "999999999999999999999999999999999"] {
            var draft = MetricColorDraft(MetricColorKind.speed.defaultScale)
            draft[.orangeStart] = text
            let result = draft.validation(for: .speed)
            XCTAssertNil(result.scale, text)
            XCTAssertNotNil(result.errors[.orangeStart], text)
            XCTAssertNil(result.errors[.redStart], text)
        }
    }

    func testLegacyExactValuesMigrateOnceAndNewSettingsWinOnRestart() throws {
        try withDefaults { defaults in
            defaults.set(128, forKey: "MotoLink.visual.speedWarm")
            defaults.set(189, forKey: "MotoLink.visual.speedHot")
            defaults.set(9876, forKey: "MotoLink.visual.rpmRedline")
            let migrated = MetricColorPreferences.load(from: defaults)
            XCTAssertEqual(migrated[.speed], MetricColorScale(orangeStart: 128, redStart: 189, maximum: 209))
            XCTAssertEqual(migrated[.engineSpeed].redStart, 9876)
            XCTAssertNotNil(defaults.data(forKey: MetricColorPreferences.storageKey))
            defaults.set(250, forKey: "MotoLink.visual.speedWarm")
            defaults.set(16000, forKey: "MotoLink.visual.rpmRedline")
            XCTAssertEqual(MetricColorPreferences.load(from: defaults), migrated)
        }
    }

    func testOutOfRangeLegacyValuesNormalizeToValidPhysicalBounds() throws {
        try withDefaults { defaults in
            defaults.set(600, forKey: "MotoLink.visual.speedWarm")
            defaults.set(-1, forKey: "MotoLink.visual.speedHot")
            defaults.set(0, forKey: "MotoLink.visual.rpmRedline")
            let migrated = MetricColorPreferences.load(from: defaults)
            XCTAssertEqual(migrated[.speed], MetricColorScale(orangeStart: 511, redStart: 511, maximum: 511))
            XCTAssertEqual(migrated[.engineSpeed], MetricColorScale(orangeStart: 0, redStart: 0, maximum: 1))
            for kind in MetricColorKind.allCases { XCTAssertTrue(migrated[kind].errors(for: kind).isEmpty) }
        }
    }

    func testReadOnlyLoadAndEmptyAppStorageDefaultDoNotLoseMigration() throws {
        try withDefaults { defaults in
            defaults.set(128, forKey: "MotoLink.visual.speedWarm")
            _ = MetricColorPreferences.load(from: defaults, persistMigration: false)
            XCTAssertNil(defaults.data(forKey: MetricColorPreferences.storageKey))
            defaults.register(defaults: [MetricColorPreferences.storageKey: Data()])
            XCTAssertEqual(MetricColorPreferences.load(from: defaults)[.speed].orangeStart, 128)
            let persisted = try XCTUnwrap(defaults.data(forKey: MetricColorPreferences.storageKey))
            XCTAssertFalse(persisted.isEmpty)
            XCTAssertEqual(MetricColorPreferences.decoded(persisted)?[.speed].orangeStart, 128)
        }
    }

    func testCorruptNonemptyPayloadSurvivesUntilExplicitSave() throws {
        try withDefaults { defaults in
            let damaged = Data("not-json".utf8)
            defaults.set(damaged, forKey: MetricColorPreferences.storageKey)
            let fallback = MetricColorPreferences.load(from: defaults)
            XCTAssertEqual(defaults.data(forKey: MetricColorPreferences.storageKey), damaged)
            XCTAssertEqual(fallback[.speed], MetricColorKind.speed.defaultScale)
            try fallback.save(to: defaults)
            XCTAssertEqual(MetricColorPreferences.load(from: defaults), fallback)
        }
    }

    func testIndependentTemperatureSettingsAndSharedSpeedIdentity() throws {
        try withDefaults { defaults in
            var preferences = MetricColorPreferences()
            preferences[.coolantTemperature] = MetricColorScale(orangeStart: 0, redStart: 2, maximum: 120)
            preferences[.inletTemperature] = MetricColorScale(orangeStart: -2, redStart: 1, maximum: 60)
            preferences[.speed] = MetricColorScale(orangeStart: 128, redStart: 160, maximum: 210)
            try preferences.save(to: defaults)
            let reloaded = MetricColorPreferences.load(from: defaults)
            XCTAssertEqual(reloaded, preferences)
            XCTAssertEqual(reloaded[.coolantTemperature].redStart, 2)
            XCTAssertEqual(reloaded[.inletTemperature].redStart, 1)
            XCTAssertEqual(MetricColorKind.forMetric("gps_speed"), .speed)
            XCTAssertEqual(MetricColorKind.forMetric("wheel_speed"), .speed)
            XCTAssertEqual(MetricColorKind.forMetric("engine_water_temperature"), .coolantTemperature)
            XCTAssertEqual(MetricColorKind.forMetric("inlet_air_temperature"), .inletTemperature)
            XCTAssertNil(MetricColorKind.forMetric("fuel_injection_raw"))
        }
    }

    func testInvalidSavePreservesEveryPreviouslySavedMetric() throws {
        try withDefaults { defaults in
            var preferences = MetricColorPreferences()
            preferences[.coolantTemperature] = MetricColorScale(orangeStart: 0, redStart: 2, maximum: 120)
            try preferences.save(to: defaults)
            let before = try XCTUnwrap(defaults.data(forKey: MetricColorPreferences.storageKey))
            preferences[.speed] = MetricColorScale(orangeStart: 160, redStart: 128, maximum: 210)
            XCTAssertThrowsError(try preferences.save(to: defaults))
            XCTAssertEqual(defaults.data(forKey: MetricColorPreferences.storageKey), before)
            XCTAssertEqual(MetricColorPreferences.load(from: defaults)[.coolantTemperature].redStart, 2)
        }
    }

    func testInvalidDecodedSettingFallsBackForDisplayAndCannotBeSilentlySaved() throws {
        let payload = Data(#"{"scales":{"speed":{"orangeStart":160,"redStart":128,"maximum":210},"coolantTemperature":{"orangeStart":0,"redStart":2,"maximum":120}}}"#.utf8)
        let preferences = try XCTUnwrap(MetricColorPreferences.decoded(payload))
        XCTAssertEqual(preferences[.speed], MetricColorKind.speed.defaultScale)
        XCTAssertEqual(preferences[.coolantTemperature].redStart, 2)
        try withDefaults { defaults in
            defaults.set(payload, forKey: MetricColorPreferences.storageKey)
            XCTAssertThrowsError(try preferences.save(to: defaults))
            XCTAssertEqual(defaults.data(forKey: MetricColorPreferences.storageKey), payload)
        }
    }

    func testEveryDefaultScaleIsValid() {
        for kind in MetricColorKind.allCases { XCTAssertTrue(kind.defaultScale.errors(for: kind).isEmpty, kind.rawValue) }
    }
}
