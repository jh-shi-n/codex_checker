// 목적: OpenAI 공개 서비스 상태의 조회 및 계정 간 공유
// 이용처: 할당량 조회에 동반되는 공용 상태 갱신과 장애 표시
// 사용방법: 앱에서 저장소 하나 생성 후 일반 할당량 조회마다 refresh 호출
import Combine
import Foundation

/// 공개 상태 응답의 서비스별 식별자·이름·운영 상태
public struct OpenAIServiceComponent: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let status: String

    /// 예시·테스트 및 외부 제공자의 상태 항목 구성
    public init(id: String, name: String, status: String) {
        self.id = id
        self.name = name
        self.status = status
    }

    public var isAffected: Bool { status != "operational" }

    /// 알려진 운영 상태의 한글 표시 및 새 상태의 원문 보존
    public var statusText: String {
        switch status {
        case "operational": return "정상"
        case "degraded_performance": return "성능 저하"
        case "partial_outage": return "부분 장애"
        case "major_outage": return "서비스 장애"
        case "under_maintenance": return "점검 중"
        default: return "상태 확인 필요 (\(status))"
        }
    }
}

/// 마지막 성공 조회 시각과 계정에 독립적인 공용 서비스 상태
public struct OpenAIServiceStatusSnapshot: Equatable, Sendable {
    public let checkedAt: Date
    public let components: [OpenAIServiceComponent]
    public var affectedComponents: [OpenAIServiceComponent] { components.filter(\.isAffected) }

    /// 성공적으로 수신한 서비스 목록과 클라이언트 확인 시각 결합
    public init(checkedAt: Date, components: [OpenAIServiceComponent]) {
        self.checkedAt = checkedAt
        self.components = components
    }
}

public typealias OpenAIServiceStatusFetch = @Sendable () async throws -> [OpenAIServiceComponent]

/// 인증·계정 경로·모델 요청 없이 공개 상태 JSON만 조회하는 클라이언트
public enum OpenAIServiceStatusClient {
    public static let endpoint = URL(string: "https://status.openai.com/api/v2/components.json")!

    /// 캐시 재사용 없는 제한 시간 10초의 공개 서비스 목록 조회
    public static func fetch() async throws -> [OpenAIServiceComponent] {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              data.count <= 2_000_000 else { throw URLError(.badServerResponse) }
        return try decode(data)
    }

    /// 비정상·빈 응답을 전체 정상 상태로 오인하지 않는 목록 검증
    static func decode(_ data: Data) throws -> [OpenAIServiceComponent] {
        let components = try JSONDecoder().decode(Payload.self, from: data).components
        guard !components.isEmpty,
              components.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && !$0.status.isEmpty }),
              Set(components.map(\.id)).count == components.count else { throw URLError(.cannotParseResponse) }
        return components
    }

    /// 공개 응답에서 필요한 서비스 목록만 복원하는 직렬화 경계
    private struct Payload: Decodable {
        let components: [OpenAIServiceComponent]
    }
}

/// 네 계정의 화면에 동일 결과를 전달하고 중복 조회를 합치는 저장소
@MainActor
public final class OpenAIServiceStatusStore: ObservableObject {
    @Published public private(set) var snapshot: OpenAIServiceStatusSnapshot?
    @Published public private(set) var isLoading = false
    @Published public private(set) var refreshFailed = false

    private let fetch: OpenAIServiceStatusFetch
    private let now: @Sendable () -> Date
    private var inFlight: Task<Void, Never>?

    /// 공개 클라이언트 또는 격리된 테스트 제공자·시계 연결
    public init(
        snapshot: OpenAIServiceStatusSnapshot? = nil,
        fetch: @escaping OpenAIServiceStatusFetch = OpenAIServiceStatusClient.fetch,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.snapshot = snapshot
        self.fetch = fetch
        self.now = now
    }

    /// 할당량 조회에 동반되는 공용 갱신; 진행 중 요청 공유 및 실패 시 이전 성공 결과 보존
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        if let inFlight { return inFlight }
        isLoading = true
        let task = Task { [weak self, fetch, now] in
            do {
                let components = try await fetch()
                guard !Task.isCancelled else { return }
                self?.snapshot = OpenAIServiceStatusSnapshot(checkedAt: now(), components: components)
                self?.refreshFailed = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.refreshFailed = true
            }
            self?.isLoading = false
            self?.inFlight = nil
        }
        inFlight = task
        return task
    }

    /// 앱 종료 시 공용 요청 취소 및 늦은 결과 반영 방지
    public func cancel() {
        inFlight?.cancel()
        inFlight = nil
        isLoading = false
    }
}
