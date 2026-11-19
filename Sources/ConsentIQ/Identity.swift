import Foundation

/// The subject to send and the identity token to send with it. A token is signed over one exact
/// identifier, and ConsentIQ verifies it against the subject as sent, so when the submitted identifier is
/// the signed one written differently (an email's case, a phone's spacing) the signed form goes instead.
/// Any other identifier goes unsigned. The server is the judge.
func signedSubject(identityToken: String?, identityFor: String?, identifier: String) -> (subjectId: String, identityToken: String?) {
    guard let identityToken, !identityToken.isEmpty else { return (identifier, nil) }
    guard let identityFor else { return (identifier, identityToken) }
    return sameIdentifier(identityFor, identifier) ? (identityFor, identityToken) : (identifier, nil)
}

/// Whether two identifiers name the same person: emails by case, phones by their digits once both read as
/// one (an optional leading plus, then digits with spaces, dots, dashes or brackets). Anything else must
/// match exactly, so two names never collapse to the same empty digit string.
func sameIdentifier(_ first: String, _ second: String) -> Bool {
    let lhs = first.trimmingCharacters(in: .whitespacesAndNewlines)
    let rhs = second.trimmingCharacters(in: .whitespacesAndNewlines)
    if lhs.contains("@") || rhs.contains("@") { return lhs.lowercased() == rhs.lowercased() }
    if let lhsDigits = phoneDigits(lhs), let rhsDigits = phoneDigits(rhs) { return lhsDigits == rhsDigits }
    return lhs == rhs
}

private func phoneDigits(_ value: String) -> String? {
    guard value.range(of: #"^\+?[\d\s().-]+$"#, options: .regularExpression) != nil else { return nil }
    let digits = value.replacingOccurrences(of: #"[\s().-]"#, with: "", options: .regularExpression)
    return digits.range(of: #"^\+?\d{7,15}$"#, options: .regularExpression) != nil ? digits : nil
}
