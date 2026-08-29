import Foundation
import Dispatch

struct DomesticMetadataHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
}

protocol DomesticMetadataTransport: Sendable {
    func send(_ request: URLRequest) async throws -> DomesticMetadataHTTPResponse
}

struct URLSessionDomesticMetadataTransport: DomesticMetadataTransport {
    static let secureSession = SecureURLSessionFactory.ephemeral(
        requestTimeout: 30,
        resourceTimeout: 45
    )

    private let session: URLSession

    init(session: URLSession = URLSessionDomesticMetadataTransport.secureSession) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> DomesticMetadataHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        return DomesticMetadataHTTPResponse(
            data: data,
            statusCode: http.statusCode,
            headers: headers
        )
    }
}

struct ClosureDomesticMetadataTransport: DomesticMetadataTransport {
    private let handler: @Sendable (URLRequest) async throws -> DomesticMetadataHTTPResponse

    init(handler: @escaping @Sendable (URLRequest) async throws -> DomesticMetadataHTTPResponse) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> DomesticMetadataHTTPResponse {
        try await handler(request)
    }
}

struct DomesticMetadataRetryPolicy: Codable, Hashable, Sendable {
    let maximumAttempts: Int
    let initialDelayNanoseconds: UInt64
    let maximumDelayNanoseconds: UInt64
    let transientHTTPStatusCodes: Set<Int>

    static let `default` = DomesticMetadataRetryPolicy(
        maximumAttempts: 4,
        initialDelayNanoseconds: 1_000_000_000,
        maximumDelayNanoseconds: 16_000_000_000,
        transientHTTPStatusCodes: [408, 409, 425, 429, 500, 502, 503, 504, 529]
    )

    static let immediateTest = DomesticMetadataRetryPolicy(
        maximumAttempts: 4,
        initialDelayNanoseconds: 0,
        maximumDelayNanoseconds: 0,
        transientHTTPStatusCodes: [408, 409, 425, 429, 500, 502, 503, 504, 529]
    )
}

actor DomesticMetadataRateLimiter {
    private let minimumIntervalNanoseconds: UInt64
    private var nextRequestNanoseconds: UInt64 = 0

    init(minimumIntervalNanoseconds: UInt64) {
        self.minimumIntervalNanoseconds = minimumIntervalNanoseconds
    }

    func waitForTurn() async throws {
        guard minimumIntervalNanoseconds > 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let scheduled = max(now, nextRequestNanoseconds)
        let following = scheduled.addingReportingOverflow(minimumIntervalNanoseconds)
        nextRequestNanoseconds = following.overflow ? UInt64.max : following.partialValue
        if scheduled > now {
            try await Task.sleep(nanoseconds: scheduled - now)
        }
    }
}

struct DomesticMetadataHTTPClient: Sendable {
    private let source: DomesticMetadataSource
    private let transport: any DomesticMetadataTransport
    private let retryPolicy: DomesticMetadataRetryPolicy
    private let rateLimiter: DomesticMetadataRateLimiter

    init(
        source: DomesticMetadataSource,
        transport: any DomesticMetadataTransport,
        retryPolicy: DomesticMetadataRetryPolicy = .default,
        minimumIntervalNanoseconds: UInt64 = 800_000_000
    ) {
        self.source = source
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.rateLimiter = DomesticMetadataRateLimiter(
            minimumIntervalNanoseconds: minimumIntervalNanoseconds
        )
    }

    func data(for request: URLRequest) async throws -> Data {
        var delay = retryPolicy.initialDelayNanoseconds
        var lastTransportError: DomesticMetadataError?

        for attempt in 1...max(1, retryPolicy.maximumAttempts) {
            try Task.checkCancellation()
            try await rateLimiter.waitForTurn()
            do {
                let response = try await transport.send(request)
                if response.statusCode == 200 {
                    return response.data
                }
                let error = DomesticMetadataError.httpStatus(source, response.statusCode)
                guard retryPolicy.transientHTTPStatusCodes.contains(response.statusCode),
                      attempt < retryPolicy.maximumAttempts else {
                    throw error
                }
                let retryDelay = retryAfterNanoseconds(response.headers) ?? delay
                if retryDelay > 0 { try await Task.sleep(nanoseconds: retryDelay) }
                delay = min(delay.multipliedReportingOverflow(by: 2).partialValue, retryPolicy.maximumDelayNanoseconds)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DomesticMetadataError {
                throw error
            } catch {
                let value = error as NSError
                lastTransportError = .transport(source, domain: value.domain, code: value.code)
                guard attempt < retryPolicy.maximumAttempts else { break }
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                delay = min(delay.multipliedReportingOverflow(by: 2).partialValue, retryPolicy.maximumDelayNanoseconds)
            }
        }

        throw lastTransportError ?? DomesticMetadataError.transport(
            source,
            domain: NSURLErrorDomain,
            code: URLError.unknown.rawValue
        )
    }

    private func retryAfterNanoseconds(_ headers: [String: String]) -> UInt64? {
        guard let value = headers.first(where: {
            $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame
        })?.value.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let seconds = UInt64(value) {
            return min(seconds, 120) * 1_000_000_000
        }

        let formats = [
            "EEE',' dd MMM yyyy HH':'mm':'ss z",
            "EEEE',' dd-MMM-yy HH':'mm':'ss z",
            "EEE MMM d HH':'mm':'ss yyyy",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let retryDate = formatter.date(from: value) {
                let seconds = max(1, min(120, Int(ceil(retryDate.timeIntervalSinceNow))))
                return UInt64(seconds) * 1_000_000_000
            }
        }
        return nil
    }
}
