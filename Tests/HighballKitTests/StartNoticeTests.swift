import XCTest
@testable import HighballKit

/// A game whose own loading outlasts Highball's start sheet (Microsoft Flight Simulator 2024 on
/// the arm64 engine prepares its shaders for minutes behind a still window) says so under
/// "is running", in its row's words, for a while.
final class StartNoticeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheRowsNoticeShowsForItsMinutes() throws {
        let json = #"{"id":"microsoft-flight-simulator-2024","title":"Microsoft Flight Simulator 2024","steam_appid":2537590,"status":"community","startNotice":"Each start takes 10 to 15 minutes.","startNoticeMinutes":20}"#
        let row = try JSONDecoder().decode(GameDBEntry.self, from: Data(json.utf8))
        let s = GameSession(title: row.title, bottleName: "b", appid: row.steam_appid, markers: [], started: t0,
                            startNotice: row.startNotice, startNoticeMinutes: row.startNoticeMinutes)
        XCTAssertEqual(s.notice(at: t0), "Each start takes 10 to 15 minutes.")
        XCTAssertEqual(s.notice(at: t0 + 19 * 60), "Each start takes 10 to 15 minutes.")
        XCTAssertNil(s.notice(at: t0 + 20 * 60), "gone once its time is over")
    }

    func testFifteenMinutesWhenTheRowDoesNotSayAndNothingWithoutANotice() throws {
        let s = GameSession(title: "g", bottleName: "b", appid: nil, markers: [], started: t0, startNotice: "Slow first start.")
        XCTAssertNotNil(s.notice(at: t0 + 14 * 60))
        XCTAssertNil(s.notice(at: t0 + 15 * 60))
        XCTAssertNil(GameSession(title: "g", bottleName: "b", appid: nil, markers: [], started: t0).notice(at: t0))
        XCTAssertNil(GameSession(title: "g", bottleName: "b", appid: nil, markers: [], started: t0, startNotice: "  ").notice(at: t0), "a blank notice is none")
        let plain = try JSONDecoder().decode(GameDBEntry.self, from: Data(#"{"id":"x","title":"X","status":"community"}"#.utf8))
        XCTAssertNil(plain.startNotice, "rows without one decode as before")
    }
}
