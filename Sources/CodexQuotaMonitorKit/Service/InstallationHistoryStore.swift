// 목적: 실행 이력과 최초 계정 등록 완료 상태의 JSON 영속 저장
// 이용처: 최초 연결 가이드와 계정 삭제 이후 안내 구분
// 사용방법: 앱 시작 시 생성 후 첫 계정 등록 시 markAccountRegistered 호출
import Foundation

/// 계정 경로·인증 정보와 분리된 앱 설치 단위의 실행 이력
public struct InstallationHistory: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var firstLaunchedAt: Date
    public var lastLaunchedAt: Date
    public var launchCount: Int
    public var hasRegisteredAccount: Bool
}

/// 첫 실행 시 파일 생성 및 최초 등록 이후 계정 삭제와 무관한 완료 상태 유지
@MainActor
public final class InstallationHistoryStore {
    public let fileURL: URL
    public let isFirstLaunch: Bool
    public private(set) var history: InstallationHistory
    public private(set) var storageError: String?
    private let configurationFile: AppConfigurationFile

    /// 사용자별 앱 지원 폴더의 실행 이력 파일 경로
    public static var defaultFileURL: URL {
        AppConfigurationFile.defaultFileURL
    }

    public var requiresAccountSetup: Bool { !history.hasRegisteredAccount }

    /// 기존 등록 계정의 완료 상태 이관 및 실행 횟수·시각 저장
    public init(fileURL: URL, hasExistingAccount: Bool = false, now: Date = Date()) {
        self.fileURL = fileURL
        let configurationFile = AppConfigurationFile(fileURL: fileURL)
        self.configurationFile = configurationFile
        var loaded: InstallationHistory?
        var loadError: String?
        do {
            loaded = try configurationFile.read()?.installation
        } catch {
            loadError = "실행 이력 파일을 읽지 못했습니다: \(error.localizedDescription)"
        }
        self.storageError = loadError
        self.isFirstLaunch = loaded == nil && loadError == nil
        self.history = InstallationHistory(
            firstLaunchedAt: now, lastLaunchedAt: now, launchCount: 0,
            hasRegisteredAccount: hasExistingAccount
        )
        if let loaded { history = loaded }
        history.hasRegisteredAccount = history.hasRegisteredAccount || hasExistingAccount
        history.launchCount = history.launchCount < Int.max ? history.launchCount + 1 : Int.max
        history.lastLaunchedAt = now
        persist()
    }

    /// 계정 삭제·표시 비활성화로 되돌아가지 않는 최초 등록 완료 저장
    @discardableResult
    public func markAccountRegistered() -> Bool {
        history.hasRegisteredAccount = true
        return persist()
    }

    /// 원자적 파일 교체 및 손상된 기존 파일의 덮어쓰기 방지
    @discardableResult
    private func persist() -> Bool {
        do {
            try configurationFile.saveInstallation(history)
            storageError = nil
            return true
        } catch {
            storageError = "실행 이력을 저장하지 못했습니다: \(error.localizedDescription)"
            return false
        }
    }
}
