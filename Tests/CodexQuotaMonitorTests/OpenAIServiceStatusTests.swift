// 목적: 공용 서비스 상태의 응답 해석·중복 조회·실패 보존·할당량 연동 검증
// 이용처: 실제 네트워크와 인증 없이 수행하는 Swift 회귀 테스트
// 사용방법: swift test
import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

/// 격리된 상태 응답으로 네 계정 공용 조회와 경고 표시 조건 검증
@MainActor
final class OpenAIServiceStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let normal = OpenAIServiceComponent(id: "responses", name: "Responses", status: "operational")
    private let affected = OpenAIServiceComponent(id: "cli", name: "CLI", status: "degraded_performance")

    /// 정상·이상 SVG 자산의 실제 로드와 서로 다른 표정 렌더링 검증
    func testBundledSmileAndSadSVGsRenderDifferentIcons() throws {
        let smile = try XCTUnwrap(OpenAIServiceStatusIcon.image(hasIssues: false))
        let sad = try XCTUnwrap(OpenAIServiceStatusIcon.image(hasIssues: true))
        XCTAssertEqual(smile.size.width, 24)
        XCTAssertEqual(smile.size.height, 24)
        let smilePixels = try XCTUnwrap(smile.tiffRepresentation)
        let sadPixels = try XCTUnwrap(sad.tiffRepresentation)
        XCTAssertNotEqual(smilePixels, sadPixels)
    }

    /// 정상 응답 미표시와 기능별 부분 장애·점검·새 상태의 보존 검증
    func testComponentResponseDistinguishesNormalAndAffectedFeatures() throws {
        let data = Data(#"{"components":[{"id":"responses","name":"Responses","status":"operational"},{"id":"cli","name":"CLI","status":"degraded_performance"},{"id":"files","name":"Files","status":"under_maintenance"},{"id":"other","name":"Other","status":"new_status"}]}"#.utf8)
        let components = try OpenAIServiceStatusClient.decode(data)
        let snapshot = OpenAIServiceStatusSnapshot(checkedAt: now, components: components)
        XCTAssertEqual(snapshot.affectedComponents.map(\.name), ["CLI", "Files", "Other"])
        XCTAssertEqual(snapshot.affectedComponents.map(\.statusText), ["성능 저하", "점검 중", "상태 확인 필요 (new_status)"])
        XCTAssertTrue(OpenAIServiceStatusSnapshot(checkedAt: now, components: [normal]).affectedComponents.isEmpty)
        XCTAssertEqual(OpenAIServiceComponent(id: "x", name: "X", status: "partial_outage").statusText, "부분 장애")
        XCTAssertEqual(OpenAIServiceComponent(id: "x", name: "X", status: "major_outage").statusText, "서비스 장애")
    }

    /// 제품 순서·동명 Login 구분·섹션 내 알림 우선·새 기능 보존 검증
    func testServiceSectionsPreserveComponentsAndDisambiguateLogin() {
        let components = [
            OpenAIServiceComponent(id: "web", name: "Codex Web", status: "operational"),
            normal, affected,
            OpenAIServiceComponent(id: "01JSM5RTJWHRWDTS6Q604VEW3B", name: "Login", status: "operational"),
            OpenAIServiceComponent(id: "01JMXBNJXG1S2D9V65P1ZZTD94", name: "Login", status: "partial_outage"),
            OpenAIServiceComponent(id: "new", name: "New Feature", status: "new_status"),
            OpenAIServiceComponent(id: "fed", name: "FedRAMP", status: "operational"),
            OpenAIServiceComponent(id: "ads", name: "Ads API", status: "operational"),
        ]
        let sections = OpenAIServiceSection.grouped(components)
        XCTAssertEqual(sections.map(\.title), ["APIs", "ChatGPT", "Codex", "FedRAMP", "Ads Platform", "기타"])
        XCTAssertEqual(sections[0].components.map(\.id), ["responses", "01JSM5RTJWHRWDTS6Q604VEW3B"])
        XCTAssertEqual(sections[1].components.map(\.id), ["01JMXBNJXG1S2D9V65P1ZZTD94"])
        XCTAssertEqual(sections[2].components.map(\.id), ["cli", "web"])
        XCTAssertEqual(sections[2].affectedCount, 1)
        XCTAssertEqual(Set(sections.flatMap(\.components).map(\.id)), Set(components.map(\.id)))
        XCTAssertEqual(sections.flatMap(\.components).count, components.count)
        XCTAssertTrue(OpenAIServiceSection.grouped([]).isEmpty)
    }

    /// 빈 목록·잘못된 형식·중복 식별자의 전체 정상 오인 방지 검증
    func testInvalidResponsesCannotBecomeHealthySnapshots() {
        for json in [#"{"components":[]}"#, #"{}"#, #"{"components":[{"id":"","name":"CLI","status":"operational"}]}"#,
                     #"{"components":[{"id":"x","name":"CLI","status":"operational"},{"id":"x","name":"Files","status":"operational"}]}"#,
                     "<html>unavailable</html>"] {
            XCTAssertThrowsError(try OpenAIServiceStatusClient.decode(Data(json.utf8)))
        }
    }

    /// 네 계정의 동시 갱신 요청을 단일 공개 조회로 합치는지 검증
    func testFourConcurrentRequestsShareOneFetchAndCheckedTime() async {
        let source = ServiceStatusTestSource(results: [[affected]])
        let date = now
        let store = OpenAIServiceStatusStore(fetch: { try await source.fetch() }, now: { date })
        let requests = (0..<4).map { _ in store.refresh() }
        for request in requests { await request.value }
        let count = await source.callCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.snapshot?.checkedAt, now)
        XCTAssertEqual(store.snapshot?.affectedComponents, [affected])
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.refreshFailed)
    }

    /// 실패 시 이전 장애·확인 시각 유지 및 다음 정상 조회 시 경고 해제 검증
    func testFailurePreservesLastResultAndRecoveryClearsWarning() async {
        let source = ServiceStatusTestSource(results: [[affected], nil, [normal]])
        let store = OpenAIServiceStatusStore(fetch: { try await source.fetch() })
        await store.refresh().value
        let previous = store.snapshot
        await store.refresh().value
        XCTAssertEqual(store.snapshot, previous)
        XCTAssertTrue(store.refreshFailed)
        await store.refresh().value
        XCTAssertTrue(store.snapshot?.affectedComponents.isEmpty == true)
        XCTAssertFalse(store.refreshFailed)
    }

    /// 최초 조회 실패를 전체 서비스 장애로 꾸미지 않는지 검증
    func testInitialFailureDoesNotInventAnOutage() async {
        let source = ServiceStatusTestSource(results: [nil])
        let store = OpenAIServiceStatusStore(fetch: { try await source.fetch() })
        await store.refresh().value
        XCTAssertNil(store.snapshot)
        XCTAssertTrue(store.refreshFailed)
        XCTAssertFalse(store.isLoading)
    }

    /// 취소된 요청의 늦은 실패가 마지막 정상 스냅샷을 변경하지 않는지 검증
    func testCancellationPreservesSnapshot() async {
        let snapshot = OpenAIServiceStatusSnapshot(checkedAt: now, components: [normal])
        let store = OpenAIServiceStatusStore(snapshot: snapshot, fetch: {
            try await Task.sleep(for: .seconds(60))
            return []
        })
        let request = store.refresh()
        store.cancel()
        await request.value
        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertFalse(store.refreshFailed)
        XCTAssertFalse(store.isLoading)
    }

    /// 전체 조회당 1회와 수동 조회당 1회의 공용 갱신 연결 검증
    func testQuotaRefreshHookRunsOncePerBatchAndManualRefresh() async {
        let suite = "ServiceStatus.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AccountStore(
            configs: AccountConfig.accounts(for: (1...4).map { "/tmp/service-status-\($0)" }),
            preferencesStore: PreferencesStore(userDefaults: defaults),
            stateLoader: { AccountState(id: $0.id, status: .normal) }
        )
        var refreshes = 0
        store.onQuotaRefreshStarted = { refreshes += 1 }
        await store.refreshAll()
        XCTAssertEqual(refreshes, 1)
        XCTAssertTrue(store.states.allSatisfy { $0.status == .normal })
        await store.refresh(accountID: "C1")
        XCTAssertEqual(refreshes, 2)
        await store.refresh(accountID: "unknown")
        store.reconfigure(pathStrings: ["", "", "", ""])
        await store.refreshAll()
        await store.refresh(accountID: "C1")
        XCTAssertEqual(refreshes, 2)
    }
}

/// 정상·실패 응답을 지정 순서대로 반환하는 격리 제공자
private actor ServiceStatusTestSource {
    private var results: [[OpenAIServiceComponent]?]
    private(set) var callCount = 0

    /// 조회 결과와 실패 순서 지정
    init(results: [[OpenAIServiceComponent]?]) { self.results = results }

    /// 지정된 결과 반환 및 호출 횟수 기록
    func fetch() throws -> [OpenAIServiceComponent] {
        callCount += 1
        guard !results.isEmpty, let result = results.removeFirst() else { throw URLError(.notConnectedToInternet) }
        return result
    }
}
