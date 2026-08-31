//
//  Nutrition Scanner — iOS SDK (Swift, no dependencies).
//
//  Manual capture:
//      let client = NutritionScannerClient(apiKey: "nls_...")
//      let result = try await client.scan(imageData: jpegData)
//
//  Auto capture: see AutoCaptureController.swift.
//

import Foundation

public let nutritionScannerDefaultBaseURL =
    URL(string: "https://nutrition-scanner-api-riiqvjsmkq-uc.a.run.app")!

public struct Nutriment: Decodable {
    public let text: String
    public let score: Double
    public let value: Double?
    public let unit: String?
}

public struct ScanEntity: Decodable {
    public let label: String
    public let text: String
    public let score: Double
}

public struct ScanResult: Decodable {
    public let entities: [ScanEntity]
    public let nutriments: [String: Nutriment]
    public let wordsDetected: Int

    public var foundTable: Bool { !entities.isEmpty }

    enum CodingKeys: String, CodingKey {
        case entities, nutriments
        case wordsDetected = "words_detected"
    }
}

public enum ScanError: Error, LocalizedError {
    case http(status: Int, detail: String)

    public var errorDescription: String? {
        if case let .http(status, detail) = self { return "HTTP \(status): \(detail)" }
        return nil
    }
}

public final class NutritionScannerClient {
    private let apiKey: String?
    /// Alternative to apiKey: supplies a Firebase ID token of a verified user.
    private let tokenProvider: (() async throws -> String)?
    private let baseURL: URL
    private let session: URLSession

    public init(
        apiKey: String? = nil,
        tokenProvider: (() async throws -> String)? = nil,
        baseURL: URL = nutritionScannerDefaultBaseURL,
        timeout: TimeInterval = 60
    ) {
        precondition(apiKey != nil || tokenProvider != nil, "Provide apiKey or tokenProvider.")
        self.apiKey = apiKey
        self.tokenProvider = tokenProvider
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: config)
    }

    /// Scan one image (JPEG/PNG/HEIC bytes). Keep the long side 1200-2000 px —
    /// `UIImage.jpegData(compressionQuality: 0.85)` after a resize is ideal.
    public func scan(imageData: Data, filename: String = "label.jpg") async throws -> ScanResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("extract"))
        request.httpMethod = "POST"
        if let apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        } else if let tokenProvider {
            request.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        }

        let boundary = "nutriscan-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"]
            throw ScanError.http(status: status, detail: detail ?? "unexpected error")
        }
        return try JSONDecoder().decode(ScanResult.self, from: data)
    }
}
