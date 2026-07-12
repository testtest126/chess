import EngineLab
import Foundation

// Thin shim: every bit of real logic lives in `EngineLab.CLI` (and is unit
// tested there); this just wires arguments to it and forwards the exit code.
exit(CLI.run(CommandLine.arguments))
