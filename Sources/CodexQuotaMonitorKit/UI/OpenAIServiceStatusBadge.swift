// 목적: 서비스 상태에 따른 표정 SVG와 클릭 현황 표시
// 이용처: 계정 상세의 구독 뱃지 옆 공용 서비스 상태 안내
// 사용방법: 앱 전체에서 공유하는 OpenAIServiceStatusStore 전달
import SwiftUI

/// 노치 화면과 별도 팝오버 사이의 공용 상태 저장소 전달 경계
private struct OpenAIServiceStatusEnvironmentKey: EnvironmentKey {
    static let defaultValue: OpenAIServiceStatusStore? = nil
}

extension EnvironmentValues {
    /// 모델을 생성하거나 조회하지 않고 기존 공용 저장소만 전달
    var openAIServiceStatus: OpenAIServiceStatusStore? {
        get { self[OpenAIServiceStatusEnvironmentKey.self] }
        set { self[OpenAIServiceStatusEnvironmentKey.self] = newValue }
    }
}

/// 정상·이상 표정과 미확인 상태를 구분하는 공용 현황 버튼
public struct OpenAIServiceStatusBadge: View {
    @ObservedObject private var store: OpenAIServiceStatusStore
    @State private var isExpanded = false

    /// 네 계정이 동일하게 관찰할 저장소 연결
    public init(store: OpenAIServiceStatusStore) {
        self.store = store
    }

    public var body: some View {
        Button { isExpanded.toggle() } label: {
            Group {
                if let snapshot = store.snapshot,
                   let icon = OpenAIServiceStatusIcon.image(hasIssues: !snapshot.affectedComponents.isEmpty) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("OpenAI 서비스 현황")
        .accessibilityLabel(accessibilityLabel)
        .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
            OpenAIServiceStatusDetails(snapshot: store.snapshot, refreshFailed: store.refreshFailed)
        }
    }

    /// 색상·표정을 보지 않고도 상태를 구분할 수 있는 접근성 문구
    private var accessibilityLabel: String {
        guard let snapshot = store.snapshot else { return "OpenAI 서비스 현황 미확인" }
        return snapshot.affectedComponents.isEmpty
            ? "OpenAI 서비스 현황 정상"
            : "OpenAI 서비스 현황 \(snapshot.affectedComponents.count)개 기능 알림"
    }

}

/// 공식 제품 구분에 따른 표시 전용 서비스 섹션
struct OpenAIServiceSection: Identifiable {
    let title: String
    let components: [OpenAIServiceComponent]
    var id: String { title }
    var affectedCount: Int { components.filter(\.isAffected).count }

    /// 중복 이름의 Login은 공식 식별자로 구분하며 미지원 기능은 기타로 보존
    static func grouped(_ components: [OpenAIServiceComponent]) -> [Self] {
        let categories: [(String, Set<String>)] = [
            ("APIs", ["Chat Completions", "Responses", "Agents", "Decisions", "Fine-tuning",
                      "Embeddings", "Images", "Batch", "Audio", "Moderations", "Realtime", "Files", "Live"]),
            ("ChatGPT", ["Conversations", "ChatGPT Work", "Codex in ChatGPT Desktop", "Compliance API",
                         "Search", "File uploads", "Voice mode", "GPTs", "Image Generation", "Deep Research",
                         "Agent", "dots", "Space", "Sites", "Connectors/Apps"]),
            ("Codex", ["Codex Web", "Codex API", "CLI", "VS Code extension"]),
            ("FedRAMP", ["FedRAMP"]),
            ("Ads Platform", ["Ads Manager", "Ads API"]),
        ]
        var buckets: [String: [OpenAIServiceComponent]] = [:]
        for component in components {
            let category: String
            switch component.id {
            case "01JSM5RTJWHRWDTS6Q604VEW3B": category = "APIs"
            case "01JMXBNJXG1S2D9V65P1ZZTD94": category = "ChatGPT"
            default:
                category = categories.first { $0.1.contains(component.name) }?.0 ?? "기타"
            }
            buckets[category, default: []].append(component)
        }
        return (categories.map(\.0) + ["기타"]).compactMap { title in
            guard let items = buckets[title], !items.isEmpty else { return nil }
            return Self(title: title, components: items.filter(\.isAffected) + items.filter { !$0.isAffected })
        }
    }
}

/// 정상·미확인을 포함한 마지막 확인 시각과 전체 기능 현황
public struct OpenAIServiceStatusDetails: View {
    public let snapshot: OpenAIServiceStatusSnapshot?
    public let refreshFailed: Bool

    /// 마지막 성공 스냅샷·미확인 및 이후 조회 실패 여부 지정
    public init(snapshot: OpenAIServiceStatusSnapshot?, refreshFailed: Bool = false) {
        self.snapshot = snapshot
        self.refreshFailed = refreshFailed
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OpenAI 서비스 현황")
                .font(.headline)
            if let snapshot {
                Text("\(AccountDashboardFormatting.dateText(snapshot.checkedAt, timeStyle: .medium)) 기준")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(snapshot.affectedComponents.isEmpty
                     ? "모든 서비스 정상 · \(snapshot.components.count)개 기능"
                     : "\(snapshot.affectedComponents.count)개 기능에 알림이 있습니다.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(snapshot.affectedComponents.isEmpty ? Color.green : .red)
            } else {
                Text("아직 서비스 상태를 확인하지 못했습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if refreshFailed {
                Text(snapshot == nil
                     ? "상태 조회에 실패했습니다. 다음 할당량 조회 시 다시 확인합니다."
                     : "최근 갱신에 실패하여 마지막 확인 결과를 표시합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !sections.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(sections) { section in
                            serviceSection(section)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(CGFloat(snapshot?.components.count ?? 0) * 27 + CGFloat(sections.count) * 42, 320))
            }
            Link("공식 상태 페이지 열기", destination: URL(string: "https://status.openai.com/")!)
                .font(.caption)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .preferredColorScheme(.dark)
    }

    /// 공식 제품 순서와 섹션 내 알림 우선순위를 적용한 표시 목록
    var sections: [OpenAIServiceSection] {
        OpenAIServiceSection.grouped(snapshot?.components ?? [])
    }

    /// 제품 제목·상태 요약·기능 목록을 구분하는 섹션 구성
    private func serviceSection(_ section: OpenAIServiceSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(section.affectedCount == 0
                     ? "정상 · \(section.components.count)개 기능"
                     : "알림 \(section.affectedCount)개 · \(section.components.count)개 기능")
                    .font(.caption2)
                    .foregroundStyle(section.affectedCount == 0 ? Color.secondary : .orange)
            }
            Divider()
            ForEach(section.components) { component in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(component.name)
                        .font(.caption.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(component.statusText)
                        .font(.caption)
                        .foregroundStyle(component.isAffected ? Color.red : .green)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
