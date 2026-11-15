import XCTest
@testable import ProvenanceCleaner

final class OpenAIProvenanceClientTests: XCTestCase {
    private let image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])

    private static let example = Data("""
    {"object":"content_provenance_check","created_at":1778000000,"results":[
      {"type":"c2pa","outcome":"detected","validation_state":"trusted","issuer":"OpenAI OpCo, LLC","model":"gpt-image","generated_at":"2026-07-27T18:34:12Z"},
      {"type":"synthid","outcome":"not_detected","model":null,"generated_at":null}
    ]}
    """.utf8)

    private func client(waits: WaitRecorder = WaitRecorder()) -> OpenAIProvenanceClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration, delegate: AIReviewSessionDelegate(), delegateQueue: nil)
        return OpenAIProvenanceClient(session: session, wait: { await waits.record($0) })
    }

    private func failure(_ replies: [StubURLProtocol.Reply], waits: WaitRecorder = WaitRecorder()) async -> ProvenanceCheckError? {
        StubURLProtocol.reset(replies)
        do {
            _ = try await client(waits: waits).check(imageData: image, fileExtension: "png", apiKey: "sk-secret")
            return nil
        } catch {
            return error as? ProvenanceCheckError
        }
    }

    func testRequestIsOneMultipartFilePartWithANeutralName() throws {
        let request = OpenAIProvenanceClient.urlRequest(
            imageData: image, fileExtension: "jpg", mediaType: "image/jpeg", apiKey: "sk-secret", boundary: "B"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/content_provenance_checks")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=B")
        let body = try XCTUnwrap(request.httpBody)
        var expected = Data("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"image.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        expected.append(image)
        expected.append(Data("\r\n--B--\r\n".utf8))
        XCTAssertEqual(body, expected)
    }

    func testOnlyTheImageTypesOpenAIAcceptsAreOffered() {
        for name in ["a.png", "a.jpg", "a.JPEG", "a.webp", "a.gif"] {
            XCTAssertTrue(OpenAIProvenanceClient.supports(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["a.tiff", "a.heic", "a.avif", "a.bmp", "a.pdf", "a.mp3"] {
            XCTAssertFalse(OpenAIProvenanceClient.supports(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    func testReadsTheDocumentedExample() throws {
        let result = try OpenAIProvenanceClient.result(from: Self.example)
        XCTAssertEqual(result.c2pa, ProvenanceSignal(
            kind: .c2pa, detected: true, validationState: "trusted",
            issuer: "OpenAI OpCo, LLC", model: "gpt-image", generatedAt: "2026-07-27T18:34:12Z"
        ))
        XCTAssertEqual(result.synthID?.detected, false)
        XCTAssertNil(result.synthID?.model)
        XCTAssertTrue(result.detectedAny)
    }

    func testOmittedChecksStayOmittedAndUnknownTypesAreSkipped() throws {
        let data = Data(#"{"object":"content_provenance_check","results":[{"type":"synthid","outcome":"detected"},{"type":"future_signal","outcome":"maybe"}]}"#.utf8)
        let result = try OpenAIProvenanceClient.result(from: data)
        XCTAssertEqual(result.signals.map(\.kind), [.synthID])
        XCTAssertNil(result.c2pa)
        XCTAssertEqual(result.synthID?.detected, true)
    }

    func testAnythingButTheAgreedShapeIsRefused() {
        let bad = [
            #"{"object":"something_else","results":[]}"#,
            #"{"object":"content_provenance_check"}"#,
            #"{"object":"content_provenance_check","results":[{"type":"synthid","outcome":"probably"}]}"#,
            #"{"object":"content_provenance_check","results":[{"type":"synthid"}]}"#,
            "not json",
        ]
        for text in bad {
            XCTAssertThrowsError(try OpenAIProvenanceClient.result(from: Data(text.utf8)), text) { error in
                XCTAssertEqual(error as? ProvenanceCheckError, .unreadableResponse)
            }
        }
    }

    func testSendsAndReadsAnAnswer() async throws {
        StubURLProtocol.reset([.init(body: Self.example)])
        let result = try await client().check(imageData: image, fileExtension: "PNG", apiKey: "sk-secret")
        XCTAssertEqual(result.c2pa?.detected, true)
        let sent = StubURLProtocol.requests
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(String(decoding: sent[0].body, as: UTF8.self).contains("filename=\"image.png\"\r\nContent-Type: image/png"))
    }

    func testStatusCodesBecomeClearErrors() async {
        let noAccess = await failure([.init(status: 404, body: Data(#"{"error":{"message":"Not found"}}"#.utf8))])
        XCTAssertEqual(noAccess, .noAccess)
        let badKey = await failure([.init(status: 401)])
        XCTAssertEqual(badKey, .badKey)
        let noCredit = await failure([.init(status: 402)])
        XCTAssertEqual(noCredit, .noCredit)
        let rejected = await failure([.init(status: 400, body: Data(#"{"error":{"message":"Unsupported file for key sk-secret","code":"unsupported_file"}}"#.utf8))])
        XCTAssertEqual(rejected, .rejected(status: 400, message: "Unsupported file for key [key]"))
    }

    func testRateLimitWaitsOnceAsAsked() async throws {
        let waits = WaitRecorder()
        StubURLProtocol.reset([.init(status: 429, headers: ["Retry-After": "3"]), .init(body: Self.example)])
        _ = try await client(waits: waits).check(imageData: image, fileExtension: "png", apiKey: "k")
        let recorded = await waits.values
        XCTAssertEqual(recorded, [3])

        let twice = await failure([.init(status: 429, headers: ["Retry-After": "1"]), .init(status: 429, headers: ["Retry-After": "1"])])
        XCTAssertEqual(twice, .rateLimited)
        let longWait = WaitRecorder()
        let tooLong = await failure([.init(status: 429, headers: ["Retry-After": "600"])], waits: longWait)
        XCTAssertEqual(tooLong, .rateLimited)
        let none = await longWait.values
        XCTAssertTrue(none.isEmpty)
    }

    func testServerErrorsAreRetriedOnce() async {
        let overloaded = await failure([.init(status: 503), .init(status: 500)])
        XCTAssertEqual(overloaded, .overloaded)
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testRefusesUnsupportedAndOversizedImagesWithoutSending() async {
        StubURLProtocol.reset([])
        do {
            _ = try await client().check(imageData: image, fileExtension: "tiff", apiKey: "k")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? ProvenanceCheckError, .unsupportedType)
        }
        do {
            _ = try await client().check(imageData: Data(count: OpenAIProvenanceClient.maximumBytes + 1), fileExtension: "png", apiKey: "k")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? ProvenanceCheckError, .tooLarge)
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }
}

// MARK: - Store

private final class OpenAIKeyOnly: APIKeyStoring, @unchecked Sendable {
    let stored: String?
    init(_ stored: String?) { self.stored = stored }
    func hasKey(for provider: AIProvider) -> Bool { provider == .openAI && stored != nil }
    func key(for provider: AIProvider) throws -> String? { provider == .openAI ? stored : nil }
    func save(_ key: String, for provider: AIProvider) throws {}
    func delete(for provider: AIProvider) throws {}
}

private actor FakeChecker: ProvenanceChecking {
    private(set) var calls: [(bytes: Int, fileExtension: String, apiKey: String)] = []
    private let failure: ProvenanceCheckError?
    private let hangs: Bool

    init(failure: ProvenanceCheckError? = nil, hangs: Bool = false) {
        self.failure = failure
        self.hangs = hangs
    }

    func check(imageData: Data, fileExtension: String, apiKey: String) async throws -> ProvenanceCheckResult {
        calls.append((imageData.count, fileExtension, apiKey))
        if hangs { try await Task.sleep(for: .seconds(60)) }
        if let failure { throw failure }
        return ProvenanceCheckResult(signals: [
            ProvenanceSignal(kind: .synthID, detected: true, validationState: nil, issuer: nil, model: "gpt-image", generatedAt: nil),
        ])
    }
}

private actor ImageEngine: WatermarkEngine {
    func capabilities() async throws -> EngineCapabilities { EngineCapabilities(report: WatermarkReport()) }
    func inspect(_ input: EngineInput) async throws -> InspectionResult { EngineInspection(kind: .image, report: WatermarkReport()) }
    func clean(_ input: EngineInput, options: CleanOptions) async throws -> CleanResult {
        throw WatermarkEngineError.invalidInput("Not used")
    }
    func scan(_ input: EngineInput) async throws -> PromptInjectionScan { PromptInjectionScan(raw: .object([:])) }
    func cancel(requestID: UUID) async {}
}

@MainActor
final class OnlineProvenanceStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func store(
        checker: FakeChecker,
        key: String? = "sk-openai",
        enabled: Bool = true,
        file: String = "photo.png"
    ) async throws -> (AppStore, CleanerJob.ID, URL) {
        let name = "OnlineProvenanceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        let preferences = AppPreferences(defaults: defaults)
        preferences.offerOnlineProvenanceCheck = enabled
        let source = root.appendingPathComponent(file)
        try Data([1, 2, 3, 4]).write(to: source)
        let store = AppStore(
            engine: ImageEngine(),
            preferences: preferences,
            stagingRoot: root.appendingPathComponent("stage"),
            apiKeys: OpenAIKeyOnly(key),
            provenanceChecker: checker
        )
        await store.addAndInspect([source])
        return (store, try XCTUnwrap(store.selectedJobID), source)
    }

    func testOffDefaultAndOnlyForSupportedImages() async throws {
        let name = "OnlineProvenanceDefault.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        XCTAssertFalse(AppPreferences(defaults: defaults).offerOnlineProvenanceCheck)

        let (off, offID, _) = try await store(checker: FakeChecker(), enabled: false)
        let offJob = try XCTUnwrap(off.jobs.first { $0.id == offID })
        XCTAssertFalse(off.offersOnlineProvenanceCheck(offJob))
        await off.checkProvenanceOnline(jobID: offID)
        XCTAssertNil(off.jobs.first?.onlineProvenanceCheck)

        let (tiff, tiffID, _) = try await store(checker: FakeChecker(), file: "scan.tiff")
        XCTAssertFalse(tiff.offersOnlineProvenanceCheck(try XCTUnwrap(tiff.jobs.first { $0.id == tiffID })))
    }

    func testSendsTheOriginalOnceWithTheOpenAIKey() async throws {
        let checker = FakeChecker()
        let (store, id, _) = try await store(checker: checker)
        await store.checkProvenanceOnline(jobID: id)

        let job = try XCTUnwrap(store.jobs.first)
        guard case let .finished(result) = job.onlineProvenanceCheck?.state else {
            return XCTFail("expected a finished check, got \(String(describing: job.onlineProvenanceCheck))")
        }
        XCTAssertEqual(result.synthID?.detected, true)
        let calls = await checker.calls
        XCTAssertEqual(calls.map(\.bytes), [4])
        XCTAssertEqual(calls.map(\.fileExtension), ["png"])
        XCTAssertEqual(calls.map(\.apiKey), ["sk-openai"])

        // The same file isn't sent again, however often it's asked for.
        XCTAssertFalse(store.canCheckProvenanceOnline(job))
        await store.checkProvenanceOnline(jobID: id)
        await store.inspect(jobID: id)
        await store.checkProvenanceOnline(jobID: id)
        let again = await checker.calls
        XCTAssertEqual(again.count, 1)
        XCTAssertNotNil(store.jobs.first?.onlineProvenanceCheck)
    }

    func testAChangedOriginalClearsTheResultOnTheNextCheck() async throws {
        let (store, id, source) = try await store(checker: FakeChecker())
        await store.checkProvenanceOnline(jobID: id)
        XCTAssertNotNil(store.jobs.first?.onlineProvenanceCheck)

        try Data([9, 9, 9, 9, 9, 9]).write(to: source)
        await store.inspect(jobID: id)
        XCTAssertNil(store.jobs.first?.onlineProvenanceCheck)
        XCTAssertTrue(store.canCheckProvenanceOnline(try XCTUnwrap(store.jobs.first)))
    }

    func testMissingKeyAndFailuresCanBeTriedAgain() async throws {
        let checker = FakeChecker()
        let (store, id, _) = try await store(checker: checker, key: nil)
        await store.checkProvenanceOnline(jobID: id)
        XCTAssertEqual(store.jobs.first?.onlineProvenanceCheck?.state, .failed(ProvenanceCheckError.missingKey.localizedDescription))
        let calls = await checker.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(store.canCheckProvenanceOnline(try XCTUnwrap(store.jobs.first)))

        let (denied, deniedID, _) = try await self.store(checker: FakeChecker(failure: .noAccess))
        await denied.checkProvenanceOnline(jobID: deniedID)
        XCTAssertEqual(denied.jobs.first?.onlineProvenanceCheck?.state, .failed(ProvenanceCheckError.noAccess.localizedDescription))
    }

    func testStoppingLeavesTheFileUnchecked() async throws {
        let (store, id, _) = try await store(checker: FakeChecker(hangs: true))
        let task = Task { await store.checkProvenanceOnline(jobID: id) }
        while store.jobs.first?.isCheckingProvenanceOnline != true { await Task.yield() }
        XCTAssertTrue(store.isBusy)
        await store.cancelAllProcessing()
        await task.value
        XCTAssertNil(store.jobs.first?.onlineProvenanceCheck)
        XCTAssertFalse(store.isBusy)
    }
}
