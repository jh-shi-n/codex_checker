// 목적: 리셋권 통합 잔여 개수·개별 소멸일 및 사용 추정 관리
// 이용처: 계정 이메일 옆 표시와 조기 리셋 알림 필터
// 사용방법: account/rateLimits/read의 rateLimitResetCredits 파싱
import Foundation

/// 상세 목록이 일부만 제공되어도 서버의 통합 개수를 우선하는 리셋권 정보
public struct RateLimitResetCredits: Codable, Equatable, Sendable {
    public let availableCount: Int
    public let credits: [Credit]?

    /// 서버가 제공한 개별 리셋권의 식별자·상태·소멸일
    public struct Credit: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let status: String
        public let expiresAt: Date?

        /// 소멸일 미제공과 무기한 여부를 구분할 수 없는 원본 정보 보관
        public init(id: String, status: String = "available", expiresAt: Date? = nil) {
            self.id = id
            self.status = status
            self.expiresAt = expiresAt
        }
    }

    /// 조회 사이의 사용 증거 구분; 사용 사유를 직접 제공하는 이벤트와 별개
    public enum UsageEvidence: Equatable, Sendable {
        case used
        case notObserved
        case unknown
    }

    /// 잔여 개수와 선택적 상세 목록 보관
    public init(availableCount: Int, credits: [Credit]? = nil) {
        self.availableCount = max(0, availableCount)
        self.credits = credits
    }

    public var availableCredits: [Credit]? {
        credits.map { $0.filter { $0.status == "available" } }
    }

    public var hasCompleteDetails: Bool {
        guard let availableCredits else { return availableCount == 0 }
        return Set(availableCredits.map(\.id)).count == availableCount
    }

    /// 누락·null·유효하지 않은 통합 개수를 조회 불가로 취급하는 응답 파싱
    static func parse(_ value: CodexJSONValue?) -> RateLimitResetCredits? {
        guard let object = value?.objectValue,
              let number = object["availableCount"]?.numberValue,
              let count = Int(exactly: number), count >= 0
        else { return nil }
        let credits = object["credits"]?.arrayValue.map { rows in
            rows.compactMap { row -> Credit? in
                guard let fields = row.objectValue,
                      let id = fields["id"]?.stringValue, !id.isEmpty,
                      let status = fields["status"]?.stringValue
                else { return nil }
                let expiration = fields["expiresAt"]?.numberValue.flatMap {
                    $0.isFinite ? Date(timeIntervalSince1970: $0) : nil
                }
                return Credit(id: id, status: status, expiresAt: expiration)
            }
        }
        return RateLimitResetCredits(availableCount: count, credits: credits)
    }

    /// 미소멸 ID 소실은 사용 추정, 소멸 시각 전후의 소실은 원인 불명 처리
    public func usageEvidence(comparedTo previous: RateLimitResetCredits?, now: Date) -> UsageEvidence {
        guard let previous else { return .unknown }
        if previous.availableCount == 0, availableCount == 0 { return .notObserved }
        guard previous.hasCompleteDetails, hasCompleteDetails else { return .unknown }
        let currentIDs = Set((availableCredits ?? []).map(\.id))
        var hasAmbiguousRemoval = false
        for credit in previous.availableCredits ?? [] {
            guard !currentIDs.contains(credit.id) else { continue }
            guard let expiresAt = credit.expiresAt, expiresAt > now else {
                hasAmbiguousRemoval = true
                continue
            }
            return .used
        }
        return hasAmbiguousRemoval ? .unknown : .notObserved
    }
}
