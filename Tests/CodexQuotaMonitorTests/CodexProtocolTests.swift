import Foundation
import XCTest
@testable import CodexQuotaMonitorKit

final class CodexProtocolTests: XCTestCase {
    func testLineDecoderHandlesMultipleMessagesAndKeepsPartialLine() throws {
        var decoder = CodexLineDecoder()
        let firstChunk = Data("{\"method\":\"server/notification\",\"params\":{}}\n{\"id\":0,\"result\":{}}\n{\"id\"".utf8)
        let secondChunk = Data(":1,\"result\":{\"account\":{}}}\nnot-json\n".utf8)

        let first = try decoder.append(firstChunk)
        XCTAssertEqual(first.count, 2)
        XCTAssertNil(first[0].id)
        XCTAssertEqual(first[1].id, 0)

        let second = try decoder.append(secondChunk)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].id, 1)
        XCTAssertEqual(second[0].result?.objectValue?["account"]?.objectValue, [:])
    }

    func testLineDecoderRejectsOversizedLineAndResetsBuffer() throws {
        var decoder = CodexLineDecoder()
        let oversizedLine = Data(repeating: 0x61, count: CodexLineDecoder.maximumLineBytes + 1)

        XCTAssertThrowsError(try decoder.append(oversizedLine + Data([0x0A]))) { error in
            XCTAssertEqual(
                error as? CodexLineDecoderError,
                .lineTooLarge(maximumBytes: CodexLineDecoder.maximumLineBytes)
            )
        }

        let messages = try decoder.append(Data("{\"id\":9,\"result\":{}}\n".utf8))
        XCTAssertEqual(messages.map(\.id), [9])
    }

    func testLineDecoderRejectsNewlineFreeOversizedBufferAndResetsBuffer() throws {
        var decoder = CodexLineDecoder()
        let firstChunk = Data(repeating: 0x61, count: CodexLineDecoder.maximumBufferBytes - 1)
        let secondChunk = Data(repeating: 0x62, count: 2)

        XCTAssertNoThrow(try decoder.append(firstChunk))
        XCTAssertThrowsError(try decoder.append(secondChunk)) { error in
            XCTAssertEqual(
                error as? CodexLineDecoderError,
                .bufferTooLarge(maximumBytes: CodexLineDecoder.maximumBufferBytes)
            )
        }

        let messages = try decoder.append(Data("{\"id\":10,\"result\":{}}\n".utf8))
        XCTAssertEqual(messages.map(\.id), [10])
    }

    func testInitializeIsEncodedAsOneJsonLineAndFollowUpRequestsUseExpectedParams() throws {
        let initialize = try CodexProtocol.initializeRequest.encodedLine()
        let initializeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: initialize) as? [String: Any]
        )

        XCTAssertEqual(initializeObject["id"] as? Int, 0)
        XCTAssertEqual(initializeObject["method"] as? String, "initialize")
        XCTAssertNotNil(initializeObject["params"] as? [String: Any])

        let requests = CodexProtocol.postInitializeRequests
        XCTAssertEqual(requests.map(\.method), ["initialized", "account/read", "account/rateLimits/read"])
        XCTAssertNil(requests[0].id)
        XCTAssertEqual(requests[1].id, 1)
        XCTAssertEqual(requests[2].id, 2)
        XCTAssertEqual(requests[1].params?.objectValue?["refreshToken"]?.boolValue, false)
        XCTAssertEqual(requests[2].params, .null)
    }

    func testMalformedAndBlankLinesAreIgnoredByParser() {
        XCTAssertNil(CodexMessage(line: Data("not-json\n".utf8)))
        XCTAssertNil(CodexMessage(line: Data("   \n".utf8)))
        XCTAssertNotNil(CodexMessage(line: Data("{\"id\":7,\"result\":{}}\r\n".utf8)))
    }

    func testCodexProcessReadsResponseDrainsStderrAndTerminatesWithinBound() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/sh
        i=0
        while [ "$i" -lt 4096 ]; do
          printf 'stderr-noise-%s\\n' "$i" >&2
          i=$((i + 1))
        done
        IFS= read -r request
        printf '%s\\n' '{"id":0,"result":{}}'
        while IFS= read -r request; do
          :
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )

        let process = CodexProcess()
        try process.launch(executable: executable, home: directory)
        try process.send(CodexProtocol.initializeRequest)
        let responses = try process.readResponses(
            for: [0],
            until: Date().addingTimeInterval(2)
        )

        XCTAssertEqual(responses[0]?.id, 0)
        let start = Date()
        process.terminate(until: Date().addingTimeInterval(1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testCodexProcessPrependsExecutableDirectoryWhenInheritedPathOmitsIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-codex")
        try Data("#!/usr/bin/env node\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )

        let node = directory.appendingPathComponent("node")
        let nodeScript = """
        #!/bin/sh
        IFS= read -r request
        printf '%s\\n' '{"id":0,"result":{}}'
        while IFS= read -r request; do
          :
        done
        """
        try Data(nodeScript.utf8).write(to: node)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: node.path
        )

        let process = CodexProcess(inheritedEnvironment: ["PATH": "/usr/bin:/bin"])
        try process.launch(executable: executable, home: directory)
        try process.send(CodexProtocol.initializeRequest)
        let responses = try process.readResponses(
            for: [0],
            until: Date().addingTimeInterval(2)
        )

        XCTAssertEqual(responses[0]?.id, 0)
        process.terminate(until: Date().addingTimeInterval(1))
    }

    func testCodexProcessDoesNotReadTerminationStatusWhileProcessIsStillRunning() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/sh
        exec 1>&-
        sleep 2
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )

        let process = CodexProcess()
        try process.launch(executable: executable, home: directory)
        defer { process.terminate(until: Date().addingTimeInterval(1)) }

        XCTAssertThrowsError(
            try process.readResponses(for: [0], until: Date().addingTimeInterval(1))
        ) { error in
            guard case let CodexProcessError.readFailed(message) = error else {
                return XCTFail("Expected readFailed, got \(error)")
            }
            XCTAssertEqual(message, "Codex output closed before process exit")
        }
    }

    func testCodexProcessForceKillsSignalIgnoringChildWithinBoundedDeadline() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/sh
        trap '' TERM
        while :; do
          :
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )

        let process = CodexProcess()
        try process.launch(executable: executable, home: directory)

        let start = Date()
        process.terminate(until: Date().addingTimeInterval(0.05))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)

        // Cleanup is idempotent after the forced-termination path.
        process.terminate(until: Date().addingTimeInterval(0.05))
    }
}
