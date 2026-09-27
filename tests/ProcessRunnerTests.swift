import Foundation

@main
struct ProcessRunnerTests {
    static func main() {
        let result = ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while [ $i -lt 2000 ]; do printf o; printf e >&2; i=$((i + 1)); done"],
            timeout: 10)
        precondition(result.code == 0, "child process did not finish")
        precondition(result.out.count == 2000, "stdout was not drained")
        precondition(result.err.count == 2000, "stderr was not drained")
    }
}
