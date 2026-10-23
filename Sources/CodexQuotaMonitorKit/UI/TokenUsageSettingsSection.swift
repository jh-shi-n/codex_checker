// 목적: 주간 차트 전환·형태·일별 집계 보관 기간 설정
// 이용처: 앱 설정의 토큰 사용량 섹션
// 사용방법: 원자적 저장을 수행하는 옵션 바인딩 전달
import SwiftUI

/// 기간 축소 시 삭제 범위를 확인하는 토큰 표시 설정
struct TokenUsageSettingsSection: View {
    @Binding var options: TokenUsageOptions
    @State private var draft: TokenUsageOptions
    @State private var pendingMonths: Int?
    @State private var showsRetentionConfirmation = false

    /// 설정 호스트의 관찰 여부와 독립적인 반응형 초안 구성
    init(options: Binding<TokenUsageOptions>) {
        self._options = options
        self._draft = State(initialValue: options.wrappedValue)
    }

    var body: some View {
        Section("토큰 사용량") {
            Toggle("주간 사용량 차트 사용", isOn: Binding(
                get: { draft.weeklyChartEnabled },
                set: { var value = options; value.weeklyChartEnabled = $0; apply(value) }
            ))
            Picker("차트 형태", selection: Binding(
                get: { draft.chartStyle },
                set: { var value = options; value.chartStyle = $0; apply(value) }
            )) {
                ForEach(TokenChartStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!draft.weeklyChartEnabled)
            Picker("일별 집계 보관 기간", selection: Binding(
                get: { draft.retentionMonths },
                set: { months in chooseRetention(months) }
            )) {
                Text("3개월").tag(3)
                Text("6개월").tag(6)
                Text("1년").tag(12)
            }
            Text("차트를 끄면 기존 잔디를 표시합니다. 표시 방식과 관계없이 일별 집계는 보관하며, 업데이트할 때 로컬 기록을 다시 읽습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text("4개 계정 기준 일별 집계 예상 용량: 3개월 약 32KiB · 6개월 52KiB · 1년 84KiB. 원본 로그와 임시 파일 제외.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { draft = options }
        .onChange(of: options) { _, value in draft = value }
        .confirmationDialog("보관 기간을 줄일까요?", isPresented: $showsRetentionConfirmation, titleVisibility: .visible) {
            Button("이전 집계 삭제", role: .destructive) {
                if let months = pendingMonths { applyRetention(months) }
                pendingMonths = nil
            }
            Button("취소", role: .cancel) { pendingMonths = nil }
        } message: {
            if let months = pendingMonths {
                let cutoff = TokenUsageOptions(retentionMonths: months).cutoff(at: Date())
                Text("\(cutoff.formatted(date: .abbreviated, time: .omitted)) 이전 일별 집계를 삭제합니다. 원본 세션 파일은 유지됩니다.")
            }
        }
    }

    /// 축소 요청만 확인 대기 후 실제 옵션에 반영
    private func chooseRetention(_ months: Int) {
        if months < options.retentionMonths { pendingMonths = months; showsRetentionConfirmation = true }
        else { applyRetention(months) }
    }

    /// 변경된 보관 정책을 저장 경계로 전달
    private func applyRetention(_ months: Int) {
        var value = options
        value.retentionMonths = months
        apply(value)
    }

    /// 저장 성공·실패의 실제 설정값을 초안에 다시 반영
    private func apply(_ value: TokenUsageOptions) {
        options = value
        draft = options
    }
}
