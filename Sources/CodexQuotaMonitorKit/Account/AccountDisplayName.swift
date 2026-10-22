// 목적: 슬롯 식별자와 독립적인 계정 표시 이름의 정규화
// 이용처: 계정 이름 입력·저장·표시의 공통 정책
// 사용방법: normalized로 저장값 구성, resolved로 슬롯 기본값 적용
// 실행 예시: AccountDisplayName.resolved(" 업무 ", slotID: "C1")
import Foundation

/// 유니코드 문자·숫자·결합 문자와 ASCII 공백만 허용하는 표시 이름 정책
public enum AccountDisplayName {
    public static let maxLength = 14

    /// NFC 정규화·금지 문자 제거·공백 정리 후 Swift Character 기준 14자 제한
    public static func normalized(_ raw: String) -> String {
        let scalars = raw.precomposedStringWithCanonicalMapping.unicodeScalars.filter { scalar in
            // 이모지 표시 선택자·키캡 결합문자의 잔존 방지
            guard scalar.value != 0xFE0E, scalar.value != 0xFE0F, scalar.value != 0x20E3 else { return false }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber,
                 .nonspacingMark, .spacingMark, .enclosingMark:
                return true
            default:
                return scalar.value == 0x20
            }
        }
        let value = String(String.UnicodeScalarView(scalars))
            .precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(value.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 누락·정규화 후 빈 이름의 슬롯 ID 기본값 반환
    public static func resolved(_ raw: String?, slotID: String) -> String {
        let value = normalized(raw ?? "")
        return value.isEmpty ? slotID : value
    }
}
