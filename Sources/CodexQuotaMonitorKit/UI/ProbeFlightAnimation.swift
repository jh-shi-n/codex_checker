// 목적: 요청 전송·성공·실패를 비행 경로로 표시
// 이용처: 사용 구간 초기화 요청의 진행 카드
// 사용방법: 외부 요청 상태를 state로 전달, 높이 36pt와 가변 너비 사용
// 실행 예시: ProbeFlightAnimation(state: .sending)
import AppKit
import SwiftUI

/// 요청 전송 카드의 외부 상태
public enum ProbeFlightState: Equatable, Sendable {
    case idle, sending, succeeded, failed
}

/// 시간 기반 위치 검증용 비행 단계
enum ProbeFlightPhase: Equatable, Sendable {
    case parked, entering, hovering, departing, succeeded, failed
}

/// 경로 진행률·수직 이동량·반복 갱신 필요 여부의 순수 결과
struct ProbeFlightSnapshot: Equatable, Sendable {
    let phase: ProbeFlightPhase
    let progress: Double
    let lift: Double
    let isAnimating: Bool
}

/// 진입 완료 보장과 재시도 초기화를 담당하는 순수 시간 상태
struct ProbeFlightTiming: Equatable, Sendable {
    static let entranceDuration = 0.7
    static let departureDuration = 0.8
    static let failureSettleDuration = 0.25
    private(set) var state: ProbeFlightState
    private var startedAt: Date?
    private var resolvedAt: Date?
    private var originProgress = 0.5
    private var originLift = 0.0

    /// 진행 중 상태만 진입 시작, 재개된 종료 상태는 정적 표시
    init(state: ProbeFlightState, at date: Date) {
        self.state = state
        startedAt = state == .sending ? date : nil
    }

    /// 새 요청 초기화 및 현재 위치를 보존하는 종료 시각 기록
    mutating func update(state next: ProbeFlightState, at date: Date) {
        guard next != state else { return }
        switch next {
        case .idle, .sending:
            startedAt = next == .sending ? date : nil
            resolvedAt = nil
            originProgress = 0.5
            originLift = 0
        case .succeeded, .failed:
            if startedAt != nil || state != .idle {
                let entranceEnd = startedAt?.addingTimeInterval(Self.entranceDuration) ?? date
                let resolution = max(date, entranceEnd)
                let origin = snapshot(at: resolution)
                resolvedAt = resolution
                originProgress = origin.progress
                originLift = origin.lift
            }
        }
        state = next
    }

    /// 지정 시각의 결정적 위치 산출, 동작 줄이기는 시각과 무관한 정적 결과
    func snapshot(at date: Date, reduceMotion: Bool = false) -> ProbeFlightSnapshot {
        if reduceMotion || state == .idle || startedAt == nil && resolvedAt == nil {
            switch state {
            case .idle: return .init(phase: .parked, progress: 0.15, lift: 0, isAnimating: false)
            case .sending: return .init(phase: .hovering, progress: 0.5, lift: 0, isAnimating: false)
            case .succeeded: return .init(phase: .succeeded, progress: 0.85, lift: 0, isAnimating: false)
            case .failed: return .init(phase: .failed, progress: 0.5, lift: 0, isAnimating: false)
            }
        }
        let elapsed = max(0, date.timeIntervalSince(startedAt ?? date))
        if startedAt != nil && elapsed < Self.entranceDuration {
            return .init(phase: .entering, progress: 0.5 * eased(elapsed / Self.entranceDuration), lift: 0, isAnimating: true)
        }
        if state == .sending {
            let hover = max(0, elapsed - Self.entranceDuration)
            let lift = 2.2 * sin(hover * 2 * .pi / 2.6) * eased(hover / 0.35)
            return .init(phase: .hovering, progress: 0.5, lift: lift, isAnimating: true)
        }
        let duration = state == .succeeded ? Self.departureDuration : Self.failureSettleDuration
        let terminalElapsed = max(0, date.timeIntervalSince(resolvedAt ?? date))
        let fraction = eased(terminalElapsed / duration)
        let target = state == .succeeded ? 1.0 : 0.5
        let moving = terminalElapsed < duration
        let phase: ProbeFlightPhase = state == .failed ? .failed : (moving ? .departing : .succeeded)
        return .init(phase: phase, progress: originProgress + (target - originProgress) * fraction,
                     lift: originLift * (1 - fraction), isAnimating: moving)
    }

    /// 시작·종료 시점의 속도를 줄이는 제한 범위 보간
    private func eased(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}

/// 화면 밖 양끝과 카드 중앙을 연결하는 삼차 곡선
struct ProbeFlightRoute: Shape {
    /// 점선·기체 위치 계산에 공유하는 삼차 곡선 제어점
    private static func controls(in rect: CGRect) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        (CGPoint(x: rect.minX - 28, y: rect.minY + rect.height * 0.65),
         CGPoint(x: rect.minX + rect.width * 0.26, y: rect.minY + rect.height * 0.12),
         CGPoint(x: rect.minX + rect.width * 0.74, y: rect.minY + rect.height * 0.88),
         CGPoint(x: rect.maxX + 28, y: rect.minY + rect.height * 0.35))
    }

    /// 카드 너비에 맞춘 점선 경로 생성
    func path(in rect: CGRect) -> Path {
        let (a, b, c, d) = Self.controls(in: rect)
        var path = Path()
        path.move(to: a)
        path.addCurve(to: d, control1: b, control2: c)
        return path
    }

    /// 진행률에 대응하는 좌표·접선 각도의 결정적 산출
    static func position(at progress: Double, in rect: CGRect) -> (point: CGPoint, angle: Double) {
        let (a, b, c, d) = controls(in: rect)
        let t = CGFloat(min(1, max(0, progress))), u = 1 - t
        let x = u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x
        let y = u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y
        let dx = 3 * u * u * (b.x - a.x) + 6 * u * t * (c.x - b.x) + 3 * t * t * (d.x - c.x)
        let dy = 3 * u * u * (b.y - a.y) + 6 * u * t * (c.y - b.y) + 3 * t * t * (d.y - c.y)
        return (CGPoint(x: x, y: y), Double(atan2(dy, dx)) * 180 / .pi)
    }
}

/// 요청 상태에 맞춰 필요한 구간에서만 갱신하는 비행 카드
@MainActor
public struct ProbeFlightAnimation: View {
    private let state: ProbeFlightState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var timing: ProbeFlightTiming
    @State private var ticking: Bool
    @State private var visible = false

    /// 외부 상태 주입 및 최초 표시의 시간 상태 준비
    public init(state: ProbeFlightState) {
        self.state = state
        _timing = State(initialValue: ProbeFlightTiming(state: state, at: Date()))
        _ticking = State(initialValue: state == .sending)
    }

    /// 종료 시 반복 갱신 해제 및 접근성 상태 전달
    public var body: some View {
        Group {
            if visible && ticking && !reduceMotion {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
                    let snapshot = timing.snapshot(at: context.date)
                    card(snapshot)
                        .onChange(of: snapshot.isAnimating, initial: true) { _, active in
                            if !active { ticking = false }
                        }
                }
            } else {
                card(timing.snapshot(at: Date(), reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .transaction { $0.animation = nil }
        .onAppear { visible = true; synchronize() }
        .onDisappear { visible = false }
        .onChange(of: state) { _, _ in synchronize() }
        .onChange(of: reduceMotion) { _, _ in synchronize() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("요청 전송")
        .accessibilityValue(statusText)
    }

    /// 표시 복귀·재시도·접근성 변경 시 필요한 갱신만 재개
    private func synchronize() {
        let now = Date()
        timing.update(state: state, at: now)
        ticking = timing.snapshot(at: now, reduceMotion: reduceMotion).isAnimating
    }

    /// 제목과 버튼 사이의 투명한 경로·기체·실패 배지 구성
    private func card(_ snapshot: ProbeFlightSnapshot) -> some View {
        GeometryReader { geometry in
            let pose = ProbeFlightRoute.position(at: snapshot.progress, in: CGRect(origin: .zero, size: geometry.size))
            ZStack(alignment: .topTrailing) {
                ProbeFlightRoute()
                    .trim(from: 0, to: snapshot.phase == .entering ? min(1, snapshot.progress * 2) : 1)
                    .stroke(Color.purple.opacity(state == .idle ? 0.23 : 0.48),
                                          style: StrokeStyle(lineWidth: 1.3, lineCap: .round, dash: [3, 5]))
                airplane.frame(width: 26, height: 20)
                    .shadow(color: .purple.opacity(0.45), radius: 5)
                    .rotationEffect(.degrees(pose.angle))
                    .overlay(alignment: .topTrailing) {
                        if state == .failed {
                            Text("!").font(.system(size: 10, weight: .black))
                                .foregroundStyle(Color.black)
                                .frame(width: 14, height: 14).background(.orange, in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1))
                                .offset(x: 5, y: -3)
                        }
                    }
                    .position(x: pose.point.x, y: pose.point.y + CGFloat(snapshot.lift))
                    .opacity(state == .idle ? 0.48 : 1)

            }
            .clipped()
        }
    }

    /// 한 번 읽은 SVG 우선 사용 및 리소스 누락 시 네이티브 기체 표시
    @ViewBuilder private var airplane: some View {
        if let image = ProbeAirplaneAsset.image {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            ProbeAirplaneShape().fill(Color(red: 0.88, green: 0.84, blue: 1))
        }
    }

    /// 동작 줄이기에서도 구분 가능한 상태 문구
    private var statusText: String {
        switch state {
        case .idle: "전송 준비"
        case .sending: "전송 중"
        case .succeeded: "✓ 전송 완료"
        case .failed: "전송 실패"
        }
    }
}

/// 설치 리소스 번들과 패키지 번들의 기체 이미지 단일 로드
@MainActor
private enum ProbeAirplaneAsset {
    static let image: NSImage? = load()

    /// 설치 번들 누락·해석 실패 시 패키지 SVG 순차 조회
    private static func load() -> NSImage? {
        let installed = Bundle.main.resourceURL?
            .appendingPathComponent("CodexQuotaMonitor_CodexQuotaMonitorKit.bundle")
        if let installed, let bundle = Bundle(url: installed),
           let url = bundle.url(forResource: "probe-airplane", withExtension: "svg"),
           let image = NSImage(contentsOf: url) { return image }
        if let url = Bundle.module.url(forResource: "probe-airplane", withExtension: "svg") {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

/// 오른쪽 기수의 네이티브 대체 기체
private struct ProbeAirplaneShape: Shape {
    /// SVG와 같은 상면 실루엣의 정규화 경로 생성
    func path(in rect: CGRect) -> Path {
        let points: [CGPoint] = [CGPoint(x: 0.98, y: 0.5), CGPoint(x: 0.64, y: 0.40),
            CGPoint(x: 0.43, y: 0.08), CGPoint(x: 0.31, y: 0.08), CGPoint(x: 0.40, y: 0.42),
            CGPoint(x: 0.18, y: 0.42), CGPoint(x: 0.09, y: 0.25), CGPoint(x: 0.02, y: 0.25),
            CGPoint(x: 0.07, y: 0.5), CGPoint(x: 0.02, y: 0.75), CGPoint(x: 0.09, y: 0.75),
            CGPoint(x: 0.18, y: 0.58), CGPoint(x: 0.40, y: 0.58), CGPoint(x: 0.31, y: 0.92),
            CGPoint(x: 0.43, y: 0.92), CGPoint(x: 0.64, y: 0.60)]
        var path = Path()
        path.addLines(points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) })
        path.closeSubpath()
        return path
    }
}
