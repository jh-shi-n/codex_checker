// 목적: 서버 날짜 그래프의 미제공·0·미래·기간·선 구간 검증
// 이용처: 계정 토큰 잔디·주간 차트 회귀 검증
// 사용방법: swift test --filter AccountUsageCalendarTests
import AppKit
import SwiftUI
import XCTest
@testable import CodexQuotaMonitorKit

final class AccountUsageCalendarTests: XCTestCase {
    /// 실제 0과 누락 날짜 구분 및 168셀 날짜 순서 검증
    func testHeatmapPreservesZeroAndMissingDates() throws {
        let snapshot = try usage([("2026-10-21", 0), ("2026-10-23", 100)])
        let model = AccountUsageCalendar(snapshot: snapshot, now: AccountUsageCalendar.date("2026-10-23")!)
        XCTAssertEqual(model.heatmap.count, 168)
        XCTAssertEqual(model.heatmap.suffix(3).map(\.tokens), [0, nil, 100])
        XCTAssertEqual(AccountUsageCalendar.label(model.heatmap.last!.date), "2026-10-23")
        XCTAssertEqual(Set(model.heatmap.map(\.date)).count, 168)
    }

    /// 누락 날짜와 미래 수치를 선으로 연결하거나 합산하지 않는지 검증
    func testWeekBreaksLinesAcrossGapsAndExcludesFuture() throws {
        let model = AccountUsageCalendar(snapshot: try usage([("2026-10-19", 1), ("2026-10-21", 2), ("2026-10-24", 9)]),
                                         now: AccountUsageCalendar.date("2026-10-23")!)
        let week = model.week(offset: 0)
        XCTAssertEqual(AccountUsageCalendar.label(week[0].date), "2026-10-19")
        XCTAssertEqual(AccountUsageCalendar.label(week[6].date), "2026-10-25")
        XCTAssertNotEqual(week[0].segment, week[2].segment)
        XCTAssertNil(week[5].tokens)
        XCTAssertTrue(week[5].isFuture)
        XCTAssertEqual(week.compactMap(\.tokens).reduce(0, +), 3)
    }

    /// 선택 표시 범위 이전 날짜와 미제공 배열의 0 오인 방지 검증
    func testCutoffAndMissingSnapshot() throws {
        let now = AccountUsageCalendar.date("2026-10-23")!
        let model = AccountUsageCalendar(snapshot: try usage([("2026-07-22", 7), ("2026-07-23", 8)]), now: now, months: 3)
        XCTAssertNil(model.day(at: AccountUsageCalendar.date("2026-07-22")).tokens)
        XCTAssertEqual(model.day(at: AccountUsageCalendar.date("2026-07-23")).tokens, 8)
        XCTAssertTrue(AccountUsageCalendar(snapshot: nil, now: now).heatmap.allSatisfy { $0.tokens == nil })
        XCTAssertEqual(model.week(offset: -1000), model.week(offset: model.minimumWeekOffset))
        XCTAssertEqual(model.week(offset: 10), model.week(offset: 0))
    }

    /// 달력 좌표의 서버 날짜 문자열 왕복 검증
    func testServerDatesNeverShiftWithLocalTimeZone() {
        for key in ["2024-02-29", "2026-01-01", "2026-12-31"] {
            XCTAssertEqual(AccountUsageCalendar.label(AccountUsageCalendar.date(key)!), key)
        }
        XCTAssertEqual(AccountUsageCalendar.calendar.timeZone.secondsFromGMT(), 0)
    }

    /// 실제 잔디·막대·선그래프의 크기와 렌더링 및 선택적 미리보기 검증
    @MainActor
    func testAccountGraphRendersAllConfiguredStyles() async throws {
        let now = Date()
        let calendar = AccountUsageCalendar.calendar
        let values = (0..<168).filter { $0 % 17 != 0 }.map { index in
            let date = calendar.date(byAdding: .day, value: -index, to: now)!
            return (AccountUsageCalendar.label(date), Int64((index * 7919) % 500_000) * 10)
        }
        let snapshot = try usage(values)
        let account = AccountState(id: "C1", status: .normal)
        let store = AccountTokenUsageStore()
        store.loader = { _ in .success(snapshot) }
        await store.refresh(for: account)?.value
        for (name, options) in [
            ("heatmap", TokenUsageOptions()),
            ("bar", TokenUsageOptions(weeklyChartEnabled: true)),
            ("line", TokenUsageOptions(weeklyChartEnabled: true, chartStyle: .line)),
        ] {
            let view = AccountTokenUsageView(account: account, store: store, options: options)
                .padding(16).frame(width: 608).background(Color(red: 0.075, green: 0.085, blue: 0.10))
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, 1216)
            XCTAssertGreaterThan(image.height, 200)
            XCTAssertLessThan(image.height, 1200)
            if ProcessInfo.processInfo.environment["CODEX_GRAPH_PREVIEW"] == "1" {
                let bitmap = NSBitmapImageRep(cgImage: image)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: "/tmp/codex-account-graph-\(name).png"))
            }
        }
    }

    /// 일별 합계만 포함한 서버 응답 구성
    private func usage(_ values: [(String, Int64)]) throws -> AccountTokenUsage {
        try AccountTokenUsage(result: .object(["summary": .object([:]), "dailyUsageBuckets": .array(values.map { date, tokens in
            .object(["startDate": .string(date), "tokens": .number(Double(tokens))])
        })]))
    }
}
