import Foundation

/// Runs a program with exactly the environment given, and never waits for it longer than allowed.
enum Subprocess {
    /// The status when the program couldn't be started.
    static let notStarted: Int32 = -1
    /// The status when it was stopped: too slow, or more output than asked for.
    static let stopped: Int32 = -2

    /// - Parameters:
    ///   - environment: everything the program gets; nothing is inherited from this app.
    ///   - timeout: seconds until the program, and anything it started, is killed.
    ///   - outputLimit: bytes of output to keep. A program that writes more is stopped.
    /// - Returns: the exit status (`notStarted`, `stopped`, or -1 for a crash) and what it printed.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                    timeout: TimeInterval, outputLimit: Int) -> (status: Int32, output: Data) {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { return (notStarted, Data()) }
        let (reading, writing) = (ends[0], ends[1])
        _ = fcntl(reading, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writing, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writing, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group, so a timeout can stop the helpers it started too. And no open
        // file of this app is passed on, only the three set up above.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
        close(writing)
        guard spawned == 0 else { close(reading); return (notStarted, Data()) }
        defer { close(reading) }

        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var finished = false
        while !finished {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { break }
            var waiting = pollfd(fd: reading, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, Int32(min(left * 1000, 60_000).rounded(.up)))
            if ready < 0, errno != EINTR { break }
            guard ready > 0 else { continue }
            let count = read(reading, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { finished = count == 0; break }
            output.append(contentsOf: buffer[0..<count])
            if output.count > outputLimit { break }
        }

        var status: Int32 = 0
        if finished {
            // The output is closed; the exit follows at once, except for a program that closed it early.
            while true {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { return (exitCode(status), output) }
                if result < 0, errno != EINTR { return (notStarted, output) }
                if deadline.timeIntervalSinceNow <= 0 { break }
                usleep(2_000)
            }
        }
        killpg(pid, SIGKILL)
        kill(pid, SIGKILL)
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        return (stopped, output)
    }

    /// The program's own exit code, or -1 when a signal ended it.
    private static func exitCode(_ status: Int32) -> Int32 {
        status & 0x7f == 0 ? (status >> 8) & 0xff : -1
    }
}
