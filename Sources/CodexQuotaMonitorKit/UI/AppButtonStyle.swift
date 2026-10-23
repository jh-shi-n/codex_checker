// 목적: 화면 간 버튼 외형·눌림·비활성 피드백 통일
// 이용처: 설정·계정 연결·상세·빈 화면의 공통 버튼
// 사용방법: buttonStyle(.appAction·.appPrimary·.appIcon·.appDisclosure·.appGraphic) 지정
import SwiftUI

/// 기본 클릭·키보드 동작을 유지하는 역할별 공통 버튼 스타일
public struct AppButtonStyle: PrimitiveButtonStyle {
    /// 일반 동작·주요 동작·아이콘·펼치기·시각 데이터의 구분
    enum Kind { case action, primary, icon, disclosure, graphic }
    let kind: Kind

    /// 일반·주요 버튼은 시스템 포커스와 키보드 반응 사용
    @ViewBuilder
    public func makeBody(configuration: Configuration) -> some View {
        switch kind {
        case .action:
            BorderedButtonStyle().makeBody(configuration: configuration).controlSize(.small)
        case .primary:
            BorderedProminentButtonStyle().makeBody(configuration: configuration).controlSize(.small)
        case .icon, .disclosure, .graphic:
            Button(configuration).buttonStyle(InlineFeedbackStyle(kind: kind))
        }
    }
}

/// 화면에서 버튼 역할만 지정하는 공통 스타일 진입점
public extension PrimitiveButtonStyle where Self == AppButtonStyle {
    static var appAction: Self { Self(kind: .action) }
    static var appPrimary: Self { Self(kind: .primary) }
    static var appIcon: Self { Self(kind: .icon) }
    static var appDisclosure: Self { Self(kind: .disclosure) }
    static var appGraphic: Self { Self(kind: .graphic) }
}

/// 기본 Button의 실행 시점을 유지한 채 눌림 상태만 시각화하는 연결
private struct InlineFeedbackStyle: ButtonStyle {
    let kind: AppButtonStyle.Kind

    /// SwiftUI 기본 입력 처리 결과를 공통 피드백에 전달
    func makeBody(configuration: Configuration) -> some View {
        InlineButtonFeedback(configuration: configuration, kind: kind)
    }
}

/// 기존 그래프·배지 형상과 행 레이아웃을 보존하는 공통 입력 피드백
private struct InlineButtonFeedback: View {
    let configuration: ButtonStyleConfiguration
    let kind: AppButtonStyle.Kind
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Group {
            if kind == .graphic {
                configuration.label
                    .opacity(isEnabled ? (configuration.isPressed ? 0.6 : (isHovered ? 0.85 : 1)) : 0.4)
            } else {
                configuration.label
                    .padding(.horizontal, kind == .icon ? 4 : 6)
                    .padding(.vertical, 4)
                    .frame(minWidth: kind == .icon ? 26 : nil, minHeight: 26)
                    .background(Color.primary.opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .opacity(isEnabled ? 1 : 0.4)
            }
        }
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isHovered)
    }

    /// 비활성 상태를 제외한 호버·눌림 배경 강도 선택
    private var backgroundOpacity: Double {
        guard isEnabled else { return 0 }
        return configuration.isPressed ? 0.16 : (isHovered ? 0.08 : 0)
    }
}
