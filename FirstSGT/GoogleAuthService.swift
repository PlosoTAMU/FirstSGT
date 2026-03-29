import Foundation
import Security

actor GoogleAuthService {
    static let shared = GoogleAuthService()
    
    private var cachedToken: String?
    private var tokenExpiry: Date?
    
    func getAccessToken() async throws -> String {
        if let token = cachedToken, let expiry = tokenExpiry, Date() < expiry {
            return token
        }
        let credentials = try loadCredentials()
        let jwt = try makeJWT(credentials: credentials)
        let token = try await exchangeJWTForToken(jwt: jwt)
        cachedToken = token
        tokenExpiry = Date().addingTimeInterval(3500)
        return token
    }
    
    // MARK: - Load credentials
    
    private func loadCredentials() throws -> [String: String] {
        guard let url = Bundle.main.url(forResource: "firstsgt-27133013414e", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { throw AuthError.missingCredentials }
        return json
    }
    
    // MARK: - Build JWT
    
    private func makeJWT(credentials: [String: String]) throws -> String {
        guard let email = credentials["client_email"],
              let privateKeyPEM = credentials["private_key"]
        else { throw AuthError.missingCredentials }
        
        let now = Int(Date().timeIntervalSince1970)
        
        let header = base64url(try JSONSerialization.data(withJSONObject: [
            "alg": "RS256", "typ": "JWT"
        ]))
        let payload = base64url(try JSONSerialization.data(withJSONObject: [
            "iss": email,
            "scope": "https://www.googleapis.com/auth/spreadsheets",
            "aud": "https://oauth2.googleapis.com/token",
            "iat": now,
            "exp": now + 3600
        ]))
        
        let signingInput = "\(header).\(payload)"
        let signature = try sign(message: signingInput, pemKey: privateKeyPEM)
        return "\(signingInput).\(signature)"
    }
    
    // MARK: - Sign with RS256
    
    private func sign(message: String, pemKey: String) throws -> String {
        let stripped = pemKey
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
        
        guard let keyData = Data(base64Encoded: stripped) else {
            throw AuthError.invalidKey
        }
        
        let pkcs1Data = try stripPKCS8Header(from: keyData)
        
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(pkcs1Data as CFData, attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }
        
        let messageData = Data(message.utf8)
        guard let signature = SecKeyCreateSignature(
            secKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            messageData as CFData,
            &error
        ) else {
            throw error!.takeRetainedValue()
        }
        
        return base64url(signature as Data)
    }
    
    // MARK: - Strip PKCS#8 header
    
    private func stripPKCS8Header(from data: Data) throws -> Data {
        var bytes = [UInt8](data)
        var index = 0
        
        guard bytes[index] == 0x30 else { throw AuthError.invalidKey }
        index += 1
        
        // Skip outer sequence length
        if bytes[index] & 0x80 != 0 {
            index += Int(bytes[index] & 0x7F) + 1
        } else {
            index += 1
        }
        
        // Skip version INTEGER (0x02 0x01 0x00)
        guard bytes[index] == 0x02 else { throw AuthError.invalidKey }
        index += 3
        
        // Skip AlgorithmIdentifier SEQUENCE
        guard bytes[index] == 0x30 else { throw AuthError.invalidKey }
        index += 1
        if bytes[index] & 0x80 != 0 {
            let lenBytes = Int(bytes[index] & 0x7F)
            var len = 0
            for i in 1...lenBytes { len = (len << 8) | Int(bytes[index + i]) }
            index += lenBytes + 1 + len
        } else {
            index += Int(bytes[index]) + 1
        }
        
        // Skip OCTET STRING tag and length
        guard bytes[index] == 0x04 else { throw AuthError.invalidKey }
        index += 1
        if bytes[index] & 0x80 != 0 {
            index += Int(bytes[index] & 0x7F) + 1
        } else {
            index += 1
        }
        
        return Data(bytes[index...])
    }
    
    // MARK: - Exchange JWT for access token
    
    private func exchangeJWTForToken(jwt: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(jwt)".data(using: .utf8)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let token = json.access_token else { throw AuthError.tokenFailed }
        return token
    }
    
    // MARK: - Helpers
    
    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    enum AuthError: Error {
        case missingCredentials, invalidKey, tokenFailed
    }
    
    struct TokenResponse: Codable {
        let access_token: String?
    }
}
