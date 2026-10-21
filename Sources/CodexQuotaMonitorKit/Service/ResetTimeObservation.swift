// 목적: 정상 조회 이력에 따른 초기화 시각의 안정·이동 관측
// 이용처: 계정별·한도별 초기화 예정 시각 표시
// 사용방법: 새 정상 조회마다 observe 호출; 실패·계정 변경 시 이력 폐기
import Foundation

/// 서버 상태 확정과 구분되는 초기화 시각 관측 결과
public enum ResetTimeObservation: String, Equatable, Sendable {
    case checking
    case stableObserved
    case movingObserved
}

/// 최소 1분 간격의 최근 3회 정상 관측 비교; 메모리 내 이력만 유지
struct ResetTimeTracker: Sendable {
    /// 서버 초기화 시각과 벽시계·단조 시계의 관측 기준
    private struct Sample: Sendable {
        let resetAt: Date
        let observedAt: Date
        let uptime: TimeInterval
    }

    private var samples: [Sample] = []
    private(set) var observation: ResetTimeObservation = .checking
    private let tolerance: TimeInterval = 2

    /// 만료·시계 변경·긴 공백 제외 후 고정 시각 또는 경과 시간에 비례한 이동 판별
    mutating func observe(
        resetAt: Date?, observedAt: Date, uptime: TimeInterval,
        maximumGap: TimeInterval = 900
    ) -> ResetTimeObservation {
        guard let resetAt,
              resetAt.timeIntervalSince1970.isFinite,
              observedAt.timeIntervalSince1970.isFinite,
              uptime.isFinite, resetAt > observedAt
        else {
            self = Self()
            return observation
        }
        let next = Sample(resetAt: resetAt, observedAt: observedAt, uptime: uptime)
        if let last = samples.last {
            let elapsed = observedAt.timeIntervalSince(last.observedAt)
            let monotonicElapsed = uptime - last.uptime
            if elapsed <= 0 || elapsed > maximumGap || monotonicElapsed < 0
                || abs(elapsed - monotonicElapsed) > tolerance || last.resetAt <= observedAt {
                samples = [next]
                observation = .checking
                return observation
            }
            // 짧은 간격의 재조회는 판정 횟수에서 제외하되 시각 변경 즉시 반영
            if elapsed < 60 {
                if abs(resetAt.timeIntervalSince(last.resetAt)) > tolerance {
                    samples = [next]
                    observation = .checking
                }
                return observation
            }
            let resetDelta = resetAt.timeIntervalSince(last.resetAt)
            if abs(resetDelta) > tolerance && abs(resetDelta - elapsed) > tolerance {
                samples = [next]
                observation = .checking
                return observation
            }
        }
        samples.append(next)
        samples = Array(samples.suffix(3))
        guard samples.count == 3, let first = samples.first else {
            observation = .checking
            return observation
        }
        let stable = samples.allSatisfy { abs($0.resetAt.timeIntervalSince(first.resetAt)) <= tolerance }
        let moving = samples.allSatisfy {
            abs($0.resetAt.timeIntervalSince(first.resetAt)
                - $0.observedAt.timeIntervalSince(first.observedAt)) <= tolerance
        }
        observation = stable ? .stableObserved : moving ? .movingObserved : .checking
        return observation
    }
}
