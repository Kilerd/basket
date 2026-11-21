import Foundation
import Security

/// Code-signature checks with the Security framework: who signed the running app, and whether an
/// extracted update is a notarized Developer ID app of the same Apple developer team
/// (docs/updates.md, step 3).
public enum CodeSignature {
    public struct Info: Equatable, Sendable {
        /// The signing identifier (normally the bundle id); nil when unsigned.
        public var identifier: String?
        /// The Apple developer team (certificate leaf OU); nil for ad-hoc or unsigned code.
        public var teamID: String?
        public var isAdHoc: Bool

        public init(identifier: String?, teamID: String?, isAdHoc: Bool) {
            self.identifier = identifier
            self.teamID = teamID
            self.isAdHoc = isAdHoc
        }

        public var isSigned: Bool { identifier != nil }

        /// A team to require of updates, or why there is none (updates are then disabled).
        public func updateTeam() throws -> String {
            guard isSigned else {
                throw UpdateError.unavailable(String(localized: "This copy of Basket isn't code signed (a development build), so it can't verify updates. Get new versions from GitHub Releases.", bundle: .main))
            }
            guard !isAdHoc, let teamID, CodeSignature.isValidTeamID(teamID) else {
                throw UpdateError.unavailable(String(localized: "This copy of Basket is signed ad hoc (a development build or a fork), so it can't verify updates. Get new versions from GitHub Releases.", bundle: .main))
            }
            return teamID
        }
    }

    /// The signature of this process's own code (`SecCodeCopySelf`).
    public static func runningApp() -> Info {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return Info(identifier: nil, teamID: nil, isAdHoc: false)
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return Info(identifier: nil, teamID: nil, isAdHoc: false)
        }
        return info(of: staticCode)
    }

    /// The signature of the bundle or binary at `url` (not validated; see `verify`).
    public static func info(at url: URL) -> Info {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return Info(identifier: nil, teamID: nil, isAdHoc: false)
        }
        return info(of: staticCode)
    }

    static func info(of code: SecStaticCode) -> Info {
        var dict: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dict) == errSecSuccess,
              let info = dict as? [String: Any]
        else { return Info(identifier: nil, teamID: nil, isAdHoc: false) }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return Info(
            identifier: info[kSecCodeInfoIdentifier as String] as? String,
            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
            isAdHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0)
    }

    /// Apple team ids are 10 upper-case letters and digits; anything else never reaches a
    /// requirement string.
    public static func isValidTeamID(_ team: String) -> Bool {
        team.count == 10 && team.allSatisfy { ($0.isASCII && $0.isUppercase && $0.isLetter) || ($0.isASCII && $0.isNumber) }
    }

    /// The code requirement an update must satisfy (docs/updates.md, step 3): an Apple-anchored
    /// chain, this bundle id, the running app's team, the Developer ID intermediate
    /// (1.2.840.113635.100.6.2.6) and leaf (1.2.840.113635.100.6.1.13) markers, and notarization.
    public static func requirement(teamID: String, identifier: String = UpdatePolicy.bundleIdentifier) throws -> String {
        try developerIDRequirement(teamID: teamID, identifier: identifier) + " and notarized"
    }

    #if DEBUG
    /// DEBUG builds only (`BASKET_UPDATE_ALLOW_UNNOTARIZED=1`, the local end-to-end run): the same
    /// requirement without `notarized`, for Developer ID builds that were never notarized.
    /// Release builds don't contain it.
    public static func requirementAllowingUnnotarized(teamID: String, identifier: String = UpdatePolicy.bundleIdentifier) throws -> String {
        try developerIDRequirement(teamID: teamID, identifier: identifier)
    }
    #endif

    private static func developerIDRequirement(teamID: String, identifier: String) throws -> String {
        guard isValidTeamID(teamID) else { throw UpdateError.codeSignature(String(localized: "the team identifier is invalid", bundle: .main)) }
        guard !identifier.isEmpty, identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            throw UpdateError.codeSignature(String(localized: "the bundle identifier is invalid", bundle: .main))
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    }

    /// Validates the whole bundle (all architectures, nested code, strict) against the update
    /// requirement for `teamID`.
    public static func verify(bundle: URL, teamID: String) throws {
        try verify(bundle: bundle, requirement: requirement(teamID: teamID))
    }

    /// Validates the whole bundle (all architectures, nested code, strict) against `text`, a
    /// requirement as `requirement(teamID:)` makes it.
    public static func verify(bundle: URL, requirement text: String) throws {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.codeSignature(String(localized: "the signing requirement can't be compiled", bundle: .main))
        }
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode)
        guard created == errSecSuccess, let staticCode else {
            throw UpdateError.codeSignature(message(for: created))
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, requirement, &error)
        guard status == errSecSuccess else {
            let detail = error?.takeRetainedValue().localizedDescription ?? message(for: status)
            throw UpdateError.codeSignature(detail)
        }
    }

    static func message(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
