// 목적: 서버 계정 사용량과 로컬 통계의 출처 구분
// 이용처: 계정 상세 상단
// 사용방법: 현재 계정과 서버 조회 저장소 전달
import Charts
import SwiftUI

/// 서버 날짜를 변환·보간하지 않는 일별 토큰 막대 표시
struct AccountTokenUsageView: View {
    let account: AccountState
    @ObservedObject var store: AccountTokenUsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("계정 토큰 사용량").font(.headline)
                Spacer()
                if store.isLoading(for: account) { ProgressView().controlSize(.small) }
                Button("업데이트") { store.refresh(for: account, force: true) }
                    .buttonStyle(.appAction)
                    .disabled(store.isLoading(for: account) || account.status == .notConfigured)
            }
            if let snapshot = store.snapshot(for: account) {
                HStack(spacing: 18) {
                    metric("누적 토큰", snapshot.lifetimeTokens)
                    metric("일 최대 토큰", snapshot.peakDailyTokens)
                }
                if let days = snapshot.days, !days.isEmpty {
                    Chart(Array(days.suffix(30))) { day in
                        BarMark(x: .value("서버 날짜", day.date), y: .value("토큰", day.tokens))
                            .foregroundStyle(Color.accentColor)
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 75)
                    Text("서버 제공 날짜: \(days.first!.date) ~ \(days.last!.date) · 최근 최대 30개 날짜 표시")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(snapshot.days == nil ? "서버에서 일별 내역을 제공하지 않았습니다." : "서버가 반환한 일별 내역이 없습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("조회 \(AccountDashboardFormatting.dateText(snapshot.fetchedAt, dateStyle: .short, timeStyle: .short))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if !store.isLoading(for: account) {
                Text("서버 사용량을 아직 확인하지 못했습니다. CLI 버전·로그인 방식에 따라 제공되지 않을 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.hasFailed(for: account) {
                Text(store.snapshot(for: account) == nil ? "서버 사용량 조회 실패" : "서버 사용량 갱신 실패 · 마지막 정상 결과 표시 중")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("계정 서버 집계 · 누락 날짜는 0으로 계산하지 않습니다. 날짜 기준과 집계 범위는 서버 제공값을 따릅니다.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .task(id: "\(account.id)-\(account.configurationGeneration)-\(account.email ?? "")") { store.refresh(for: account) }
    }

    /// 미제공 수치를 0과 구분한 토큰 요약
    private func metric(_ title: String, _ value: Int64?) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map(AccountDashboardFormatting.numberText) ?? "미제공").font(.subheadline.monospacedDigit())
        }
    }
}
