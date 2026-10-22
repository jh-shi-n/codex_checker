// 목적: UserDefaults와 config.json의 동일 등록 이력 자료형
import Foundation

/// 과거 실행 시각·횟수를 사용하지 않는 등록 이력
public struct InstallationHistory: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var hasRegisteredAccount: Bool
    public var firstAccountRegisteredAt: Date?
}
