import Foundation

// Explicit development-only input. Never source this file as shell code or log its contents.
struct LocalTestCredentials {
    let account: String
    let password: String
    let countryCode: String

    init(contents: String) throws {
        var fields: [String: String] = [:]
        for raw in contents.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let split = line.firstIndex(of: "=") else { throw Self.invalid }
            let key = String(line[..<split])
            guard ["IMOU_EMAIL", "IMOU_PASSWORD", "IMOU_COUNTRY_CODE"].contains(key),
                  fields[key] == nil else { throw Self.invalid }
            fields[key] = String(line[line.index(after: split)...])
        }
        guard let account = fields["IMOU_EMAIL"], !account.isEmpty,
              let password = fields["IMOU_PASSWORD"], !password.isEmpty else { throw Self.invalid }
        self.account = account
        self.password = password
        self.countryCode = fields["IMOU_COUNTRY_CODE"] ?? ""
    }

    static func read(path: String) throws -> Self {
        // Bound the read, and report only a fixed error rather than file contents or credentials.
        guard let handle = FileHandle(forReadingAtPath: path) else { throw invalid }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16 * 1024 + 1), data.count <= 16 * 1024,
              let contents = String(data: data, encoding: .utf8) else { throw invalid }
        return try Self(contents: contents)
    }

    private static var invalid: ImouError {
        .message("Could not read the local test credentials file. Check its format and required fields.")
    }
}
