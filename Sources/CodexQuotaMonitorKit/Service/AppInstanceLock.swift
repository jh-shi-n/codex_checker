// 목적: 앱 사본 사이의 프로세스 단일 실행 보장
// 이용처: 설정·서비스 초기화 이전의 앱 시작 경계
// 사용방법: acquire 성공 인스턴스를 앱 수명 동안 보관
import Darwin
import Foundation

/// 종료 시 커널에서 해제되는 사용자별 비차단 실행 잠금
public final class AppInstanceLock {
    private let fileURL: URL
    private var descriptor: Int32 = -1

    /// 앱 설치 경로와 독립적인 공용 잠금 파일 연결
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 보유 중인 잠금 해제; 파일 삭제에 따른 서로 다른 inode 잠금 방지
    deinit {
        release()
    }

    /// 중복 실행은 false, 파일 접근 실패는 오류로 구분하는 원자적 잠금 획득
    public func acquire() throws -> Bool {
        if descriptor >= 0 { return true }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let candidate = open(fileURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard candidate >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(candidate, LOCK_EX | LOCK_NB) == 0 {
            descriptor = candidate
            return true
        }
        let code = errno
        close(candidate)
        if code == EWOULDBLOCK { return false }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// 정상 종료·테스트 종료 시 명시적 잠금 해제
    public func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }
}
