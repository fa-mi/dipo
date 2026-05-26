import Foundation
import Network
import CryptoKit
import Security

// MARK: - Network Errors

enum NetworkError: Error, LocalizedError {
    case invalidURL
    case noConnection
    case timeout
    case invalidResponse
    case httpError(statusCode: Int)
    case sslPinningFailed
    case decodingError(Error)
    case encodingError(Error)
    case serverError(String)
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return loc("error.invalid_url")
        case .noConnection:
            return loc("error.no_connection")
        case .timeout:
            return loc("error.timeout")
        case .invalidResponse:
            return loc("error.invalid_response")
        case .httpError(let code):
            return "HTTP Error \(code)"
        case .sslPinningFailed:
            return loc("error.ssl_pinning_failed")
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        case .encodingError(let error):
            return "Encoding error: \(error.localizedDescription)"
        case .serverError(let message):
            return message
        case .unknown:
            return loc("error.unknown")
        }
    }
    
    var isRetryable: Bool {
        switch self {
        case .timeout, .noConnection:
            return true
        case .httpError(let code):
            return code >= 500 || code == 408 || code == 429
        default:
            return false
        }
    }
}

// MARK: - Request Configuration

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
}

struct Endpoint {
    let path: String
    let method: HTTPMethod
    let headers: [String: String]?
    let body: Data?
    let queryItems: [URLQueryItem]?
    
    init(
        path: String,
        method: HTTPMethod = .get,
        headers: [String: String]? = nil,
        body: Data? = nil,
        queryItems: [URLQueryItem]? = nil
    ) {
        self.path = path
        self.method = method
        self.headers = headers
        self.body = body
        self.queryItems = queryItems
    }
    
    func asURLRequest() throws -> URLRequest {
        guard var components = URLComponents(string: path) else {
            throw NetworkError.invalidURL
        }
        
        if let queryItems = queryItems {
            components.queryItems = queryItems
        }
        
        guard let url = components.url else {
            throw NetworkError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        
        // Default headers
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("DiPo-iOS/1.0", forHTTPHeaderField: "User-Agent")
        
        // Custom headers
        headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        
        return request
    }
}

// MARK: - SSL Pinning

class SSLPinningDelegate: NSObject, URLSessionDelegate {

    // ── Why there is no certificate pinning here ──────────────────────────
    //
    // The previous implementation pinned against a PLACEHOLDER public-key
    // hash ("AAAA…="). Pinning was disabled in DEBUG but ACTIVE in Release,
    // so every HTTPS request silently failed on TestFlight / the App Store
    // (the real server hash never matched the placeholder) while working
    // fine when run from Xcode — breaking Ask DiPo, receipt scanning, the
    // live FX-rate fetch, and any other networked feature.
    //
    // Pinning was removed rather than "fixed": our only backend is a
    // Cloudflare Worker (*.workers.dev), and Cloudflare rotates its TLS
    // certificates frequently. Pinning to a fixed key would break the app
    // unpredictably on every rotation. Standard system TLS validation —
    // full certificate-chain verification against the device's trusted CA
    // store, which `.performDefaultHandling` triggers — is secure and
    // rotation-proof. ATS (App Transport Security) is also still enforced.
    //
    // The delegate is kept as a thin pass-through so pinning can be
    // reintroduced cleanly if we ever move to a fixed-certificate backend.

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Let the OS perform its standard, secure trust evaluation.
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - Network Service

protocol NetworkServiceProtocol {
    func fetch<T: Decodable>(_ endpoint: Endpoint) async throws -> T
    func fetchRaw(_ endpoint: Endpoint) async throws -> Data
}

@Observable
final class NetworkService: NetworkServiceProtocol {
    static let shared = NetworkService()
    
    private let session: URLSession
    private let maxRetries = 3
    private let retryDelay: TimeInterval = 1.0
    
    var isOnline: Bool = true
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        // Enable SSL pinning for production
        let delegate = SSLPinningDelegate()
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        
        // Monitor network connectivity
        startMonitoring()
    }
    
    // MARK: - Network Monitoring
    
    private func startMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isOnline = path.status == .satisfied
            }
        }
        let queue = DispatchQueue(label: "NetworkMonitor")
        monitor.start(queue: queue)
    }
    
    // MARK: - Request Execution
    
    /// Fetch and decode JSON response
    func fetch<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        let data = try await fetchRaw(endpoint)
        
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            throw NetworkError.decodingError(error)
        }
    }
    
    /// Fetch raw data with retry logic
    func fetchRaw(_ endpoint: Endpoint) async throws -> Data {
        guard isOnline else {
            throw NetworkError.noConnection
        }
        
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                let request = try endpoint.asURLRequest()
                print("[DiPo] Network: \(endpoint.method.rawValue) \(endpoint.path) (attempt \(attempt)/\(maxRetries))")
                
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.invalidResponse
                }
                
                print("[DiPo] Network: Response \(httpResponse.statusCode)")
                
                // Handle HTTP status codes
                switch httpResponse.statusCode {
                case 200...299:
                    return data
                    
                case 400:
                    throw NetworkError.httpError(statusCode: 400)
                    
                case 401:
                    // Unauthorized - could trigger re-authentication
                    throw NetworkError.httpError(statusCode: 401)
                    
                case 403:
                    throw NetworkError.httpError(statusCode: 403)
                    
                case 404:
                    throw NetworkError.httpError(statusCode: 404)
                    
                case 408, 429, 500...599:
                    // Retryable errors
                    throw NetworkError.httpError(statusCode: httpResponse.statusCode)
                    
                default:
                    throw NetworkError.httpError(statusCode: httpResponse.statusCode)
                }
                
            } catch let error as NetworkError {
                lastError = error
                
                // Retry only for retryable errors and not on last attempt
                if error.isRetryable && attempt < maxRetries {
                    let delay = retryDelay * Double(attempt)
                    print("[DiPo] Network: Retrying after \(delay)s due to: \(error.localizedDescription)")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                
                throw error
                
            } catch {
                lastError = error
                
                // Check if it's a timeout or connection error
                if (error as NSError).code == NSURLErrorTimedOut {
                    if attempt < maxRetries {
                        try await Task.sleep(nanoseconds: UInt64(retryDelay * Double(attempt) * 1_000_000_000))
                        continue
                    }
                    throw NetworkError.timeout
                }
                
                if (error as NSError).code == NSURLErrorNotConnectedToInternet {
                    throw NetworkError.noConnection
                }
                
                throw NetworkError.unknown
            }
        }
        
        throw lastError ?? NetworkError.unknown
    }
    
    // MARK: - Convenience Methods
    
    /// POST request with Encodable body
    func post<T: Encodable, R: Decodable>(
        path: String,
        body: T,
        headers: [String: String]? = nil
    ) async throws -> R {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        
        let bodyData: Data
        do {
            bodyData = try encoder.encode(body)
        } catch {
            throw NetworkError.encodingError(error)
        }
        
        let endpoint = Endpoint(
            path: path,
            method: .post,
            headers: headers,
            body: bodyData
        )
        
        return try await fetch(endpoint)
    }
}

// MARK: - Usage Examples in Comments

/*
 
 // Example 1: Simple GET request
 struct ExchangeRateResponse: Decodable {
     let rates: [String: Double]
 }
 
 func fetchExchangeRate() async throws {
     let endpoint = Endpoint(path: "https://open.er-api.com/v6/latest/USD")
     let response: ExchangeRateResponse = try await NetworkService.shared.fetch(endpoint)
     print("IDR Rate: \(response.rates["IDR"] ?? 0)")
 }
 
 // Example 2: POST with authentication
 struct LoginRequest: Encodable {
     let email: String
     let password: String
 }
 
 struct LoginResponse: Decodable {
     let token: String
     let userId: String
 }
 
 func login(email: String, password: String) async throws {
     let request = LoginRequest(email: email, password: password)
     let response: LoginResponse = try await NetworkService.shared.post(
         path: "https://api.yourbank.com/auth/login",
         body: request
     )
     print("Token: \(response.token)")
 }
 
 // Example 3: Handling errors
 func safeNetworkCall() async {
     do {
         let data = try await NetworkService.shared.fetchRaw(
             Endpoint(path: "https://api.example.com/data")
         )
         print("Success: \(data.count) bytes")
     } catch NetworkError.noConnection {
         print("No internet connection")
     } catch NetworkError.sslPinningFailed {
         print("Security error: SSL pinning failed")
     } catch {
         print("Error: \(error.localizedDescription)")
     }
 }
 
 */
