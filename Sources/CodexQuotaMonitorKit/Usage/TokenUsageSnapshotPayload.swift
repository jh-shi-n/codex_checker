import Foundation

/// 목적: 제한된 토큰 집계값의 JSON 직렬화
/// 이용처: 앱 전용 SQLite snapshot BLOB
/// 제외 범위: 세션 내용, 인증 정보, 홈 경로
struct TokenUsageSnapshotPayload: Codable {
    /// 일별 집계 저장 상한
    private static let maximumDailyPoints = TokenUsageSnapshot.historyDayCount

    /// 캐시 토큰 저장 버전; 이전 일별 증가분 집계 버전 2 복원 지원
    private static let currentAggregationVersion = 3
    private let aggregationVersion: Int
    private let generatedAt: Double
    private let dailyPoints: [DailyPoint]
    private let today: Totals
    private let last7Days: Totals
    private let last30Days: Totals
    private let totalSessions: Int64
    private let averageTokensPerSession: Double
    private let availability: TokenUsageAvailability
    private let error: TokenUsageSnapshotError?

    /// 제한된 일별 집계와 요약값으로 직렬화 모델 구성
    init(snapshot: TokenUsageSnapshot) {
        aggregationVersion = Self.currentAggregationVersion
        generatedAt = snapshot.generatedAt.timeIntervalSince1970
        dailyPoints = snapshot.dailyPoints
            .suffix(Self.maximumDailyPoints)
            .map(DailyPoint.init)
        today = Totals(snapshot.today)
        last7Days = Totals(snapshot.last7Days)
        last30Days = Totals(snapshot.last30Days)
        totalSessions = snapshot.totalSessions
        averageTokensPerSession = snapshot.averageTokensPerSession
        availability = snapshot.availability
        error = snapshot.error
    }

    /// 제한된 aggregate JSON 직렬화
    func encode() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// 직렬화 모델에서 불변 snapshot 복원
    static func decode(_ data: Data) throws -> TokenUsageSnapshot {
        let payload = try JSONDecoder().decode(Self.self, from: data)
        guard [2, currentAggregationVersion].contains(payload.aggregationVersion),
              payload.dailyPoints.count <= maximumDailyPoints else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "집계 버전 불일치 또는 일별 집계 한도 초과"
            ))
        }
        return TokenUsageSnapshot(
            generatedAt: Date(timeIntervalSince1970: payload.generatedAt),
            dailyPoints: payload.dailyPoints.map { $0.restore },
            today: payload.today.restore,
            last7Days: payload.last7Days.restore,
            last30Days: payload.last30Days.restore,
            totalSessions: payload.totalSessions,
            averageTokensPerSession: payload.averageTokensPerSession,
            availability: payload.availability,
            error: payload.error
        )
    }

    /// 입력·출력과 선택적 캐시 토큰의 직렬화 집계
    private struct Totals: Codable {
        let inputTokens: Int64
        let outputTokens: Int64
        let cachedInputTokens: Int64?

        /// 음수 정규화가 적용된 요약값 구성
        init(_ totals: TokenUsageTotals) {
            inputTokens = totals.inputTokens
            outputTokens = totals.outputTokens
            cachedInputTokens = totals.cachedInputTokens
        }

        /// 직렬화 요약값 복원
        var restore: TokenUsageTotals {
            TokenUsageTotals(inputTokens: inputTokens, outputTokens: outputTokens, cachedInputTokens: cachedInputTokens)
        }
    }

    /// 저장되는 한 날짜별 사용량 행
    private struct DailyPoint: Codable {
        let date: Double
        let inputTokens: Int64
        let outputTokens: Int64
        let cachedInputTokens: Int64?
        let sessionCount: Int64

        /// 일별 집계 한 행 구성
        init(_ point: TokenUsageDailyPoint) {
            date = point.date.timeIntervalSince1970
            inputTokens = point.inputTokens
            outputTokens = point.outputTokens
            cachedInputTokens = point.cachedInputTokens
            sessionCount = point.sessionCount
        }

        /// 저장된 일별 집계 한 행 복원
        /// 직렬화 일별 행 복원
        var restore: TokenUsageDailyPoint {
            TokenUsageDailyPoint(
                date: Date(timeIntervalSince1970: date),
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cachedInputTokens: cachedInputTokens,
                sessionCount: sessionCount
            )
        }
    }
}
