import Foundation

/// Creates the first super admin on a fresh Strapi app, through the same endpoint as the welcome form.
public enum AdminBootstrap {
    public static let passwordAccount = "strapi-admin-password"

    public struct Credentials: Sendable {
        public var email: String
        public var password: String
        public var firstname: String
        public var lastname: String

        public init(email: String, password: String, firstname: String, lastname: String) {
            self.email = email
            self.password = password
            self.firstname = firstname
            self.lastname = lastname
        }
    }

    public enum Outcome: Equatable, Sendable {
        case created
        case alreadyHasAdmin
        case failed(String)
    }

    /// Strapi's rule: 8–72 bytes, one lowercase, one uppercase, one number.
    public static func passwordProblem(_ password: String) -> String? {
        if password.count < 8 { return "At least 8 characters" }
        if password.utf8.count > 72 { return "At most 72 bytes" }
        if password.range(of: "[a-z]", options: .regularExpression) == nil { return "Needs a lowercase letter" }
        if password.range(of: "[A-Z]", options: .regularExpression) == nil { return "Needs an uppercase letter" }
        if password.range(of: "[0-9]", options: .regularExpression) == nil { return "Needs a number" }
        return nil
    }

    public static func ensureAdmin(port: Int, credentials: Credentials) -> Outcome {
        let base = "http://localhost:\(port)/admin"
        struct Init: Decodable {
            struct DataBody: Decodable { var hasAdmin: Bool }
            var data: DataBody
        }
        guard case .success(let (status, body)) = request("GET", "\(base)/init", json: nil), status == 200,
              let info = try? JSONDecoder().decode(Init.self, from: body) else {
            return .failed("could not read /admin/init")
        }
        if info.data.hasAdmin { return .alreadyHasAdmin }

        let payload: [String: String] = [
            "email": credentials.email,
            "password": credentials.password,
            "firstname": credentials.firstname,
            "lastname": credentials.lastname,
        ]
        switch request("POST", "\(base)/register-admin", json: payload) {
        case .success(let (status, body)) where (200..<300).contains(status):
            _ = body
            return .created
        case .success(let (status, body)):
            struct APIError: Decodable {
                struct E: Decodable { var message: String }
                var error: E
            }
            let message = (try? JSONDecoder().decode(APIError.self, from: body))?.error.message ?? "HTTP \(status)"
            return .failed(message)
        case .failure(let error):
            return .failed(error.localizedDescription)
        }
    }

    static func request(_ method: String, _ url: String, json: [String: String]?) -> Result<(Int, Data), Error> {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.timeoutInterval = 20
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<(Int, Data), Error> = .failure(URLError(.timedOut))
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { result = .failure(error) }
            else { result = .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())) }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return result
    }
}
