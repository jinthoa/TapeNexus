import Foundation

/// Runs a short-lived helper while draining stdout and stderr concurrently.
/// Reading one pipe to EOF before the other can deadlock when the child fills
/// the unread pipe's kernel buffer.
enum ProcessRunner {
    struct Result {
        let code: Int
        let out: String
        let err: String
    }

    static func run(executable: URL, arguments: [String],
                    environment: [String: String]? = nil,
                    timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return Result(code: -1, out: "", err: error.localizedDescription)
        }

        let readers = DispatchGroup()
        var outData = Data()
        var errData = Data()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
        process.waitUntilExit()
        readers.wait()
        return Result(code: Int(process.terminationStatus),
                      out: String(data: outData, encoding: .utf8) ?? "",
                      err: String(data: errData, encoding: .utf8) ?? "")
    }
}
