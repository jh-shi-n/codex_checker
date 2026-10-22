// 목적: 앱 설정과 설치 이력의 단일 config.json 저장소
// 이용처: 앱 시작·설정 변경·최초 계정 등록
// 사용방법: PreferencesStore와 InstallationHistoryStore에 동일 파일 경로 연결
import Foundation

/// 인증 정보 없이 저장 가능한 앱 설정의 명시적 허용 목록
public struct AppPreferencesPayload: Codable, Equatable, Sendable {
    public var accountPaths: [String]
    public var enabledAccountIDs: [String]
    public var accountDisplayOrder: [String]
    public var refreshIntervalMinutes: Int
    public var resetReminderMinutes: Int
    public var activityNotificationDurationSeconds: Int
    public var showAccountLabels: Bool
    public var launchAtLogin: Bool

    /// 기존 정규화 경로와 동일한 키를 사용하는 설정 로드 어댑터
    @MainActor var preferenceValues: [String: Any] {
        [
            PreferencesStore.Keys.accountPaths: accountPaths,
            PreferencesStore.Keys.enabledAccountIDs: enabledAccountIDs,
            PreferencesStore.Keys.accountDisplayOrder: accountDisplayOrder,
            PreferencesStore.Keys.refreshIntervalMinutes: refreshIntervalMinutes,
            PreferencesStore.Keys.resetReminderMinutes: resetReminderMinutes,
            PreferencesStore.Keys.activityNotificationDurationSeconds: activityNotificationDurationSeconds,
            PreferencesStore.Keys.showAccountLabels: showAccountLabels,
            PreferencesStore.Keys.launchAtLogin: launchAtLogin,
        ]
    }
}

/// 실행 이력과 앱 설정을 분리한 버전 2 설정 파일
public struct AppConfigurationDocument: Codable, Equatable, Sendable {
    public var schemaVersion = 2
    public var installation: InstallationHistory?
    public var settings: AppPreferencesPayload?
}

/// 서로 다른 소비자의 이력·설정 저장 시 다른 섹션을 보존하는 파일 경계
@MainActor
public final class AppConfigurationFile {
    public let fileURL: URL

    /// 사용자별 앱 지원 폴더의 공용 설정 경로
    public static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("CodexQuotaMonitor/config.json")
    }

    /// 실제 사용자 파일 또는 격리된 테스트 파일 연결
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 이전 파일명·버전 1 이력의 복원 및 알 수 없는 버전의 저장 차단
    public func read() throws -> AppConfigurationDocument? {
        let legacy = fileURL.deletingLastPathComponent().appendingPathComponent("installation.json")
        let source = !FileManager.default.fileExists(atPath: fileURL.path)
            && fileURL.lastPathComponent == "config.json"
            && FileManager.default.fileExists(atPath: legacy.path) ? legacy : fileURL
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let data = try Data(contentsOf: source)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(VersionHeader.self, from: data)
        if header.schemaVersion == 1 {
            let history = try decoder.decode(InstallationHistory.self, from: data)
            return AppConfigurationDocument(installation: history)
        }
        guard header.schemaVersion == 2 else { throw CocoaError(.fileReadCorruptFile) }
        let document = try decoder.decode(AppConfigurationDocument.self, from: data)
        if let history = document.installation, history.schemaVersion != 1 || (!history.hasRegisteredAccount && history.firstAccountRegisteredAt != nil) {
            throw CocoaError(.fileReadCorruptFile)
        }
        return document
    }

    /// 앱 설정 변경 시 실행 이력의 최신 파일 값 보존
    public func saveSettings(_ settings: AppPreferencesPayload) throws {
        var document = try read() ?? AppConfigurationDocument()
        guard document.settings != settings else { return }
        document.settings = settings
        try write(document)
    }

    /// 실행·등록 이력 변경 시 계정 경로와 다른 설정 보존
    public func saveInstallation(_ history: InstallationHistory) throws {
        var document = try read() ?? AppConfigurationDocument()
        document.installation = history
        try write(document)
    }

    /// 허용된 Codable 필드만 원자적으로 저장하고 사용자 전용 파일 권한 적용
    private func write(_ document: AppConfigurationDocument) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// 임의 필드 저장 없이 파일 형식 버전만 판별하는 읽기 경계
    private struct VersionHeader: Decodable {
        let schemaVersion: Int
    }
}
