// 목적: 메인 세션의 명시적 턴 시작·완료·중단 이벤트만 읽기
// 이용처: SQLite 세션 수집 결과의 메인 상태 보완
// 사용방법: 계정 홈 내부 JSONL 경로 전달, 미지원·읽기 실패 시 nil 유지
import Foundation

/// 대화 내용 없이 상태와 턴 번호만 보관하는 수집 결과
struct MainSessionTurnState: Equatable, Sendable {
    let status: SessionActivityStatus
    let turnID: String
}

/// 파일별 마지막 64KiB와 최대 64개 메타데이터 캐시를 사용하는 읽기 전용 수집기
actor MainSessionTurnReader {
    static let maximumReadBytes = 64 * 1024
    private var files: [URL: Cursor] = [:]

    /// 파일 교체·절단·추가 기록 판별용 메타데이터와 마지막 명시적 상태
    private struct Cursor {
        let identity: String
        let size: UInt64
        let modified: Date
        let state: MainSessionTurnState?
        var accessedAt: Date
    }

    /// 답변·도구 본문을 디코딩하지 않는 이벤트 메타데이터 투영
    private struct Event: Decodable {
        let type: String?
        let payload: Payload?

        /// 실제 턴 이벤트의 종류와 번호만 추출
        struct Payload: Decodable {
            let type: String?
            let turn_id: String?
        }
    }

    /// 경로 경계·파일 종류·바이트 상한 확인 후 완결된 최신 턴 이벤트 반환
    func state(home: URL, path: String) -> MainSessionTurnState? {
        guard !Task.isCancelled, home.isFileURL else { return nil }
        let root = home.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent("sessions").resolvingSymlinksInPath()
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/"), url.pathExtension == "jsonl" else { return nil }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let number = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            let size = number.uint64Value
            let identity = "\(attributes[.systemNumber] ?? 0)-\(attributes[.systemFileNumber] ?? 0)"
            let previous = files[url]
            if var previous, previous.identity == identity, previous.size == size, previous.modified == modified {
                previous.accessedAt = Date()
                files[url] = previous
                return previous.state
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let start = size > UInt64(Self.maximumReadBytes) ? size - UInt64(Self.maximumReadBytes) : 0
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: Self.maximumReadBytes) ?? Data()
            var state: MainSessionTurnState?
            if let previous, previous.identity == identity, size > previous.size,
               size - previous.size <= UInt64(Self.maximumReadBytes) {
                state = previous.state
            }
            var lines = data.split(separator: 10, omittingEmptySubsequences: false)
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            // 쓰기 중인 마지막 행은 다음 조회에서 처리
            if !lines.isEmpty { lines.removeLast() }
            let decoder = JSONDecoder()
            for line in lines {
                guard !Task.isCancelled else { return nil }
                guard let event = try? decoder.decode(Event.self, from: Data(line)),
                      event.type == "event_msg", let payload = event.payload,
                      let turnID = payload.turn_id, !turnID.isEmpty else { continue }
                let status: SessionActivityStatus
                switch payload.type {
                case "task_started": status = .working
                case "task_complete": status = .completed
                case "turn_aborted": status = .stopped
                default: continue
                }
                state = MainSessionTurnState(status: status, turnID: turnID)
            }
            if files[url] == nil, files.count >= 64,
               let oldest = files.min(by: { $0.value.accessedAt < $1.value.accessedAt })?.key {
                files.removeValue(forKey: oldest)
            }
            files[url] = Cursor(identity: identity, size: size, modified: modified,
                                state: state, accessedAt: Date())
            return state
        } catch {
            files.removeValue(forKey: url)
            return nil
        }
    }
}
