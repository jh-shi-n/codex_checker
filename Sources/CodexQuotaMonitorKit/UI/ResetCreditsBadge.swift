// 목적: 이메일 옆 리셋권 통합 잔여 개수와 클릭 상세 표시
// 이용처: 계정 상세 화면 헤더
// 사용방법: 최신 계정의 resetCredits 전달
import SwiftUI

/// 리셋권 개수 버튼과 개별 소멸일 목록 제공
struct ResetCreditsBadge: View {
    let credits: RateLimitResetCredits?
    @State private var isExpanded = false

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Label("리셋권 \(credits.map { String($0.availableCount) } ?? "—")", systemImage: "ticket")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help("리셋권 잔여 개수 및 소멸일 확인")
        .accessibilityLabel("리셋권 \(credits.map { "잔여 \($0.availableCount)개" } ?? "조회 불가"), 소멸일 보기")
        .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
            details
                .padding(14)
                .frame(width: 300)
        }
    }

    /// 누락·일부 상세와 잔여 0개를 구분하는 소멸일 목록
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("리셋권 소멸일")
                .font(.headline)
            if let credits {
                Text("통합 잔여 \(credits.availableCount)개")
                    .font(.subheadline)
                if credits.availableCount == 0 {
                    Text("남은 리셋권 없음")
                        .foregroundStyle(.secondary)
                } else if let rows = credits.availableCredits, !rows.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, credit in
                                HStack {
                                    Text("리셋권 \(index + 1)")
                                    Spacer()
                                    if let expiresAt = credit.expiresAt {
                                        Text(expiresAt, format: .dateTime.year().month().day().hour().minute())
                                    } else {
                                        Text("소멸일 미제공")
                                    }
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    if !credits.hasCompleteDetails {
                        Text("일부 리셋권의 소멸일만 제공되었습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("개별 소멸일 미제공")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("리셋권 정보를 조회할 수 없습니다.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
