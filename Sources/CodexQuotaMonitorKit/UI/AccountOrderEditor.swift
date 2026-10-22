// 목적: 네 계정의 표시 순서 편집
// 이용처: 설정 화면의 독립 계정 순서 영역
// 사용방법·실행 예시: AccountOrderEditor(order: $order, names: names)
import SwiftUI

/// 드롭 확정 시에만 순서를 반영하는 계정 편집기
@MainActor
public struct AccountOrderEditor: View {
    @Binding private var order: [String]
    private let names: [String: String]
    @State private var draggedSlot: String?
    @State private var insertion: Int?
    @GestureState private var isDragging = false
    private static let slots = ["C1", "C2", "C3", "C4"]

    /// 호출자 소유 순서 바인딩과 선택적 이름 연결
    public init(order: Binding<[String]>, names: [String: String] = [:]) {
        _order = order
        self.names = names
    }

    private var displayedOrder: [String] {
        (order + Self.slots).reduce(into: []) { result, slot in
            if Self.slots.contains(slot), !result.contains(slot) { result.append(slot) }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(displayedOrder.enumerated()), id: \.element) { index, slot in
                GeometryReader { geometry in
                    row(slot, index: index, width: geometry.size.width)
                }
                .frame(height: 32)
            }
        }
        .onDisappear { draggedSlot = nil; insertion = nil }
        .onChange(of: isDragging) { _, active in
            if !active { draggedSlot = nil; insertion = nil }
        }
    }

    /// 원본 배열의 삽입 경계를 제거 후 인덱스로 보정하는 순수 이동 함수
    /// 범위: insertionIndex는 0...order.count, 무효 입력은 원본 반환
    nonisolated public static func moving(
        _ order: [String], slotID: String, toInsertionIndex insertionIndex: Int
    ) -> [String] {
        guard (0...order.count).contains(insertionIndex),
              let source = order.firstIndex(of: slotID) else { return order }
        var result = order
        result.remove(at: source)
        result.insert(slotID, at: insertionIndex - (source < insertionIndex ? 1 : 0))
        return result
    }

    /// 행 전체와 우측 손잡이를 공통 드래그 영역으로 구성
    private func row(_ slot: String, index: Int, width: CGFloat) -> some View {
        let name = AccountDisplayName.resolved(names[slot] ?? "", slotID: slot)
        return HStack(spacing: 8) {
            Text(slot).monospaced().fontWeight(.medium)
            if name != slot { Text(name).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 8)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if insertion == index { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .overlay(alignment: .bottom) {
            if index == 3, insertion == 4 {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .opacity(draggedSlot == slot ? 0.55 : 1)
        .help("행이나 오른쪽 손잡이를 드래그하여 계정 순서 변경")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name == slot ? slot : "\(slot), \(name)")
        .accessibilityValue("\(index + 1) / 4")
        .accessibilityAction(named: Text("위로 이동")) { move(slot, offset: -1) }
        .accessibilityAction(named: Text("아래로 이동")) { move(slot, offset: 1) }
        .gesture(
            DragGesture(minimumDistance: 4)
                .updating($isDragging) { _, active, _ in active = true }
                .onChanged { value in
                    draggedSlot = slot
                    let y = CGFloat(index * 32) + value.location.y
                    insertion = min(displayedOrder.count, max(0, Int((y / 32).rounded())))
                }
                .onEnded { value in
                    let y = CGFloat(index * 32) + value.location.y
                    if value.location.x >= 0, value.location.x <= width,
                       y >= 0, y <= CGFloat(displayedOrder.count * 32),
                       draggedSlot == slot, let insertion {
                        let current = displayedOrder
                        order = Self.moving(current, slotID: slot, toInsertionIndex: insertion)
                    }
                    draggedSlot = nil
                    insertion = nil
                }
        )
    }

    /// 접근성 이동 요청의 경계 검사와 즉시 반영
    private func move(_ slot: String, offset: Int) {
        let current = displayedOrder
        guard let index = current.firstIndex(of: slot),
              current.indices.contains(index + offset) else { return }
        draggedSlot = nil
        insertion = nil
        order = Self.moving(current, slotID: slot, toInsertionIndex: index + (offset > 0 ? 2 : -1))
    }

}
