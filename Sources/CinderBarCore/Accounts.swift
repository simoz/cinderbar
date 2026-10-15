import Foundation

// Who each agent is signed in as, read from where the tool already records it.
// Those files also hold OAuth tokens: one display field is taken from each and
// the rest is dropped, never copied, logged or cached.
//
//   Claude  ~/.claude.json      oauthAccount.emailAddress, else its displayName
//   Codex   ~/.codex/auth.json  the email claim of the ChatGPT id_token; a
//                               machine signed in with an API key says "API key"
//   Grok    $GROK_HOME/auth.json (Grok.account)

public enum Accounts {
    /// A JSON object from a file no larger than 16 MB, else nil.
    static func object(_ url: URL) -> [String: Any]? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue, size <= 16 << 20,
              let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func claude(_ url: URL) -> String? {
        guard let oauth = object(url)?["oauthAccount"] as? [String: Any] else { return nil }
        return cleanAccount(oauth["emailAddress"]) ?? cleanAccount(oauth["displayName"])
    }

    public static func codex(_ url: URL) -> String? {
        guard let auth = object(url) else { return nil }
        let tokens = auth["tokens"] as? [String: Any]
        if let jwt = tokens?["id_token"] as? String, let claims = jwtPayload(jwt),
           let email = cleanAccount(claims["email"]) { return email }
        let key = auth["OPENAI_API_KEY"] as? String ?? ""
        if (auth["auth_mode"] as? String)?.lowercased() == "apikey" || (!key.isEmpty && tokens == nil) { return "API key" }
        return nil
    }

    /// The claims of a JWT, decoded without verifying it: only a label is read.
    static func jwtPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2, parts[1].count <= 64 << 10 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
