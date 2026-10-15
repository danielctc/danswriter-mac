import Foundation
import Darwin

final class CLIProcessRunner: @unchecked Sendable {
    func run(provider: AIProvider, executablePath override: String, model: String, prompt: String, timeout: TimeInterval,
             codexRequestOverrides: [String] = []) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        let executable = try resolveExecutable(provider: provider, override: override)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("writeon-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let schemaURL = temporary.appendingPathComponent("response-schema.json")
        try JSONSerialization.data(withJSONObject: AIPrompt.schema, options: [.sortedKeys]).write(to: schemaURL)
        let workingDirectory = temporary.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var environment = subscriptionEnvironment()
        if provider == .codex {
            environment["CODEX_HOME"] = try await prepareCodexHome(executable: executable, inside: temporary,
                                                                     workingDirectory: workingDirectory,
                                                                     environment: environment, deadline: deadline)
        }
        _ = try await execute(executable: "/usr/bin/git", arguments: ["init", "--quiet"], currentDirectory: workingDirectory,
                              environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"],
                              input: nil, deadline: deadline)
        return try await execute(executable: executable,
                                 arguments: arguments(provider: provider, model: model, schemaPath: schemaURL.path,
                                                      codexRequestOverrides: codexRequestOverrides),
                                 currentDirectory: workingDirectory, environment: environment,
                                 input: Data(prompt.utf8), deadline: deadline)
    }

    private func execute(executable: String, arguments: [String], currentDirectory: URL, environment: [String: String],
                         input: Data?, deadline: Date) async throws -> Data {
        try Task.checkCancellation()
        guard deadline.timeIntervalSinceNow > 0 else { throw AIError.timedOut }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try resolveLauncher())
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        process.standardInput = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.arguments = [executable] + arguments
        let box = ProcessBox(process: process)
        let collector = OutputCollector(process: process, stdout: stdout, stderr: stderr, overflowHandler: { box.stop(.outputTooLarge) })
        do { try process.run() } catch { throw AIError.providerUnavailable("A local CLI command could not be started") }
        collector.start()
        let stdin = process.standardInput as? Pipe
        if let input {
            DispatchQueue.global(qos: .utility).async {
                do { try Self.writeWithoutSIGPIPE(input, to: stdin!.fileHandleForWriting) }
                catch { box.stop(.providerUnavailable("The provider CLI could not read the request")) }
                try? stdin?.fileHandleForWriting.close()
            }
        } else {
            try? stdin?.fileHandleForWriting.close()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completion = ProcessCompletion(continuation: continuation, collector: collector, processBox: box)
                process.terminationHandler = { finished in completion.finish(status: finished.terminationStatus) }
                let timeoutTask = Task {
                    try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                    if !Task.isCancelled { box.stop(.timedOut) }
                }
                completion.installOnFinish { timeoutTask.cancel() }
                if !process.isRunning { completion.finish(status: process.terminationStatus) }
            }
        } onCancel: {
            box.stop(.cancelled)
        }
    }

    private func resolveExecutable(provider: AIProvider, override: String) throws -> String {
        let localClaude = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
        let candidates = override.isEmpty ? (provider == .codex ? ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"] : [localClaude, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]) : [override]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) { return path }
        throw AIError.providerUnavailable(provider == .codex ? "Codex CLI was not found" : "Claude CLI was not found")
    }

    private func resolveLauncher() throws -> String {
        let processExecutable = ProcessInfo.processInfo.arguments.first
        let appExecutable = Bundle.main.executableURL?.path
        for candidate in [appExecutable, processExecutable].compactMap({ $0 }) {
            let sibling = URL(fileURLWithPath: candidate).deletingLastPathComponent().appendingPathComponent("WriteOnLauncher").path
            if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        }
        throw AIError.providerUnavailable("The isolated CLI launcher is unavailable")
    }

    func arguments(provider: AIProvider, model: String, schemaPath: String,
                   codexRequestOverrides: [String] = []) -> [String] {
        switch provider {
        case .codex:
            var result = ["exec", "-c", "forced_login_method=\"chatgpt\""]
            for setting in codexRequestOverrides { result += ["-c", setting] }
            for feature in ["apps", "browser_use", "browser_use_external", "browser_use_full_cdp_access", "computer_use", "image_generation", "in_app_browser", "in_app_chat", "in_app_dictation", "in_app_local_automation", "in_app_updates", "memories", "multi_agent", "multi_agent_v2", "plugins", "shell_tool", "sleep_tool", "tool_suggest", "code_mode", "code_mode_host", "code_mode_only", "code_mode_prewarm"] {
                result += ["--disable", feature]
            }
            result += ["--ephemeral", "--json", "--sandbox", "read-only"]
            if !model.isEmpty { result += ["--model", model] }
            result += ["--output-schema", schemaPath]
            return result + ["-"]
        case .claude:
            var result = ["-p", "--output-format", "json", "--json-schema", Self.schemaJSON,
                          "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                          "--no-session-persistence", "--max-turns", "1"]
            if !model.isEmpty { result += ["--model", model] }
            return result
        }
    }

    private func subscriptionEnvironment() -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME", "CLAUDE_CONFIG_DIR"] {
            if let value = current[key] { env[key] = value }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        return env
    }

    private func prepareCodexHome(executable: String, inside temporary: URL, workingDirectory: URL,
                                  environment: [String: String], deadline: Date) async throws -> String {
        let current = ProcessInfo.processInfo.environment
        let originalHome = current["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let original = URL(fileURLWithPath: originalHome, isDirectory: true)
        let config = original.appendingPathComponent("config.toml")
        guard FileManager.default.isReadableFile(atPath: config.path) else {
            throw AIError.providerUnavailable("Codex configuration could not be isolated")
        }
        let isolated = temporary.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let isolatedConfig = isolated.appendingPathComponent("config.toml")
        try Data(contentsOf: config).write(to: isolatedConfig, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: isolatedConfig.path)

        let auth = original.appendingPathComponent("auth.json")
        if FileManager.default.fileExists(atPath: auth.path) {
            try FileManager.default.createSymbolicLink(at: isolated.appendingPathComponent("auth.json"), withDestinationURL: auth)
        }
        for directory in ["hooks", "plugins", "skills", "rules", "policies"] {
            let source = original.appendingPathComponent(directory, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue {
                try FileManager.default.createSymbolicLink(at: isolated.appendingPathComponent(directory), withDestinationURL: source)
            }
        }
        for file in ["AGENTS.md", "hooks.json"] {
            let source = original.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.createSymbolicLink(at: isolated.appendingPathComponent(file), withDestinationURL: source)
            }
        }

        var isolatedEnvironment = environment
        isolatedEnvironment["CODEX_HOME"] = isolated.path
        var entries: [[String: Any]]
        do {
            let listing = try await execute(executable: executable, arguments: ["mcp", "list", "--json", "--disable", "plugins"],
                                            currentDirectory: workingDirectory, environment: isolatedEnvironment,
                                            input: nil, deadline: min(deadline, Date().addingTimeInterval(5)))
            guard let parsed = try? JSONSerialization.jsonObject(with: listing) as? [[String: Any]], parsed.count <= 100 else {
                throw AIError.providerUnavailable("Codex MCP configuration could not be isolated")
            }
            entries = parsed
        } catch let error as AIError { throw error }
        catch { throw AIError.providerUnavailable("Codex MCP discovery failed") }

        for _ in 0..<4 {
            for entry in entries where entry["enabled"] as? Bool != false {
                guard let name = entry["name"] as? String, !name.isEmpty, name.count <= 128, !name.hasPrefix("-") else {
                    throw AIError.providerUnavailable("Codex MCP configuration could not be isolated")
                }
                do { _ = try await execute(executable: executable, arguments: ["mcp", "remove", name, "--disable", "plugins"],
                                           currentDirectory: workingDirectory, environment: isolatedEnvironment,
                                           input: nil, deadline: min(deadline, Date().addingTimeInterval(5))) }
                catch let error as AIError { throw error }
                catch { throw AIError.providerUnavailable("Codex MCP removal failed") }
            }
            do {
                let verification = try await execute(executable: executable, arguments: ["mcp", "list", "--json", "--disable", "plugins"],
                                                     currentDirectory: workingDirectory, environment: isolatedEnvironment,
                                                     input: nil, deadline: min(deadline, Date().addingTimeInterval(5)))
                guard let remaining = try? JSONSerialization.jsonObject(with: verification) as? [[String: Any]], remaining.count <= 100 else {
                    throw AIError.providerUnavailable("Codex MCP verification failed")
                }
                if remaining.allSatisfy({ $0["enabled"] as? Bool == false }) { return isolated.path }
                entries = remaining
            } catch let error as AIError { throw error }
            catch { throw AIError.providerUnavailable("Codex MCP verification failed") }
        }
        let enabled = entries.filter { $0["enabled"] as? Bool == true }.count
        throw AIError.providerUnavailable("Codex MCP tools could not be disabled (\(enabled) enabled entries remain)")
    }

    private func initializeRepository(at directory: URL) throws {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "--quiet"]
        git.currentDirectoryURL = directory
        git.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        do { try git.run(); git.waitUntilExit() } catch { throw AIError.providerUnavailable("Could not prepare the isolated request") }
        guard git.terminationStatus == 0 else { throw AIError.providerUnavailable("Could not prepare the isolated request") }
    }

    private static func writeWithoutSIGPIPE(_ data: Data, to handle: FileHandle) throws {
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw AIError.providerUnavailable("The provider CLI could not read the request")
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(handle.fileDescriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written; continue }
                if written == -1 && errno == EINTR { continue }
                throw AIError.providerUnavailable("The provider CLI could not read the request")
            }
        }
    }

    private static let schemaJSON: String = {
        let data = (try? JSONSerialization.data(withJSONObject: AIPrompt.schema, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }()
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var reason: AIError?
    private var cleanupScheduled = false

    init(process: Process) { self.process = process }

    func stop(_ error: AIError) {
        lock.lock()
        if reason == nil { reason = error }
        let shouldSignal = !cleanupScheduled
        cleanupScheduled = true
        lock.unlock()
        if shouldSignal { terminateGroup(forceAfter: 1) }
    }

    func cleanupAfterLeaderExit() {
        lock.lock()
        let shouldSignal = !cleanupScheduled
        cleanupScheduled = true
        lock.unlock()
        if shouldSignal { terminateGroup(forceAfter: 1) }
    }

    private func terminateGroup(forceAfter delay: TimeInterval) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        _ = Darwin.kill(-pid, SIGTERM)
        if process.isRunning { _ = Darwin.kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            _ = Darwin.kill(-pid, SIGKILL)
            if self.process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
        }
    }

    func stopReason() -> AIError? {
        lock.lock(); defer { lock.unlock() }; return reason
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let overflowHandler: () -> Void
    private let stdout: Pipe
    private let stderr: Pipe
    private var out = Data()
    private var err = Data()
    private var oversized = false

    init(process: Process, stdout: Pipe, stderr: Pipe, overflowHandler: @escaping () -> Void) {
        self.overflowHandler = overflowHandler; self.stdout = stdout; self.stderr = stderr
    }

    func start() {
        let outputHandle = stdout.fileHandleForReading
        let errorHandle = stderr.fileHandleForReading
        setNonblocking(outputHandle)
        setNonblocking(errorHandle)
        outputHandle.readabilityHandler = { [weak self] _ in self?.drain(outputHandle, toError: false) }
        errorHandle.readabilityHandler = { [weak self] _ in self?.drain(errorHandle, toError: true) }
    }

    private func setNonblocking(_ handle: FileHandle) {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    private func drain(_ handle: FileHandle, toError: Bool) {
        lock.lock()
        drainLocked(handle, toError: toError)
        let shouldStop = oversized
        lock.unlock()
        if shouldStop { overflowHandler() }
    }

    private func drainLocked(_ handle: FileHandle, toError: Bool) {
        let descriptor = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            let data = Data(buffer.prefix(count))
            let total = out.count + err.count
            let available = max(0, 1_000_001 - total)
            let kept = Data(data.prefix(available))
            if toError { err.append(kept) } else { out.append(kept) }
            oversized = oversized || total + data.count > 1_000_000
            if oversized { break }
        }
    }

    func result(status: Int32, reason: AIError?) throws -> Data {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        drainLocked(stdout.fileHandleForReading, toError: false)
        drainLocked(stderr.fileHandleForReading, toError: true)
        let output = out
        let errorOutput = err
        let isOversized = oversized
        lock.unlock()
        if let reason { throw reason }
        if isOversized { throw AIError.outputTooLarge }
        guard status == 0 else {
            let details = String(decoding: errorOutput, as: UTF8.self).lowercased()
            let category: String
            if details.contains("hook") || details.contains("trust") { category = "hook" }
            else if details.contains("login") || details.contains("auth") { category = "authentication" }
            else if details.contains("mcp") || details.contains("tool") { category = "tool configuration" }
            else if details.contains("model") { category = "model configuration" }
            else if details.contains("config") || details.contains("invalid option") { category = "configuration" }
            else { category = "unclassified" }
            throw AIError.providerUnavailable("The provider CLI exited with an error (\(category))")
        }
        return output
    }

}

private final class ProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private let collector: OutputCollector
    private let processBox: ProcessBox
    private var onFinish: (() -> Void)?

    init(continuation: CheckedContinuation<Data, Error>, collector: OutputCollector, processBox: ProcessBox) {
        self.continuation = continuation; self.collector = collector; self.processBox = processBox
    }

    func installOnFinish(_ handler: @escaping () -> Void) {
        lock.lock()
        let alreadyFinished = continuation == nil
        if !alreadyFinished { onFinish = handler }
        lock.unlock()
        if alreadyFinished { handler() }
    }

    func finish(status: Int32) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let onFinish = self.onFinish
        lock.unlock()
        onFinish?()
        processBox.cleanupAfterLeaderExit()
        do { continuation.resume(returning: try collector.result(status: status, reason: processBox.stopReason())) }
        catch { continuation.resume(throwing: error) }
    }
}
