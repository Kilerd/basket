import Foundation
import Security

/// Code-signature checks with the Security framework: who signed the running app, and whether an
/// extracted update is signed by the same Apple developer team (docs/updates.md, step 3).
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
                throw UpdateError.unavailable("This copy of Basket isn't code signed (a development build), so it can't verify updates. Get new versions from GitHub Releases.")
            }
            guard !isAdHoc, let teamID, CodeSignature.isValidTeamID(teamID) else {
                throw UpdateError.unavailable("This copy of Basket is signed ad hoc (a development build or a fork), so it can't verify updates. Get new versions from GitHub Releases.")
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

    /// The designated requirement an update must satisfy (docs/updates.md).
    public static func requirement(teamID: String, identifier: String = UpdatePolicy.bundleIdentifier) throws -> String {
        guard isValidTeamID(teamID) else { throw UpdateError.codeSignature("invalid team identifier") }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Validates the whole bundle (all architectures, nested code, strict) against the requirement.
    public static func verify(bundle: URL, teamID: String) throws {
        let text = try requirement(teamID: teamID)
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.codeSignature("the signing requirement can't be compiled")
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
