import Foundation
import HogCore

Command.forwardSignals()

do {
    let args = try Args(Array(CommandLine.arguments.dropFirst()))
    exit(CLI(args).run().rawValue)
} catch {
    FileHandle.standardError.write(Data("hog: \(error)\nhog help\n".utf8))
    exit(Exit.usage.rawValue)
}
