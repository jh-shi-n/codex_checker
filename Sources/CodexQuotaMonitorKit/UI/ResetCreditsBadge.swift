// 목적: 리셋권 목록·선택·사용 확인 및 처리 결과 표시
// 이용처: 계정 상세 화면 헤더
// 사용방법: 최신 계정과 리셋권 사용 콜백 전달
// 실행 예시: 계정 상세 → 리셋권 → 행 선택 → 사용 → 확인
import SwiftUI

/// 개별 리셋권 목록과 확인 창 승인 이후의 사용 요청 제공
struct ResetCreditsBadge: View {
    let account: AccountState
    let consume: ResetCreditRunner
    private var credits: RateLimitResetCredits? { account.resetCredits }
    @State private var isExpanded = false
    @State private var selectedID: String?
    @State private var confirmingCredit: RateLimitResetCredits.Credit?
    @State private var isConfirming = false
    @ObservedObject private var redemption = ResetCreditRedemptionStore.shared

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
                .frame(width: 340)
                .alert("정말 사용하시겠습니까?", isPresented: $isConfirming) {
                    Button("취소", role: .cancel) { confirmingCredit = nil }
                    Button("사용", role: .destructive) {
                        if let credit = confirmingCredit {
                            redemption.start(credit: credit, account: account, runner: consume)
                        }
                        confirmingCredit = nil
                    }
                } message: {
                    Text("\(account.email ?? account.id) 계정의 리셋권 1개를 사용해 초기화 가능한 한도를 초기화합니다. 사용한 리셋권은 되돌릴 수 없습니다.")
                }
        }
    }

    /// 누락·일부 상세와 잔여 0개를 구분하는 소멸일 목록
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("리셋권")
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
                                    Button {
                                        selectedID = selectedID == credit.id ? nil : credit.id
                                    } label: {
                                        HStack {
                                            Text("리셋권 \(index + 1)")
                                            Spacer()
                                            if selectedID != credit.id {
                                                if let expiresAt = credit.expiresAt {
                                                    Text(expiresAt, format: .dateTime.year().month().day().hour().minute())
                                                } else {
                                                    Text("소멸일 미제공")
                                                }
                                            }
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 30)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("리셋권 \(index + 1), \(selectedID == credit.id ? "소멸일 보기" : "사용 버튼 보기")")
                                    if selectedID == credit.id {
                                        Button("사용") {
                                            confirmingCredit = credit
                                            isConfirming = true
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .disabled(!redemption.canUse(credit, for: account))
                                    }
                                }
                                .frame(minHeight: 30)
                                .padding(.horizontal, 6)
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
                    Text("리셋권 목록을 새로고침한 뒤 사용해 주세요.")
                        .font(.caption)
                }
            } else {
                Text("리셋권 정보를 조회할 수 없습니다.")
                    .foregroundStyle(.secondary)
            }
            if redemption.isRunning(for: account) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("리셋권 사용 중…")
                }
            }
            if let message = redemption.message(for: account) {
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
