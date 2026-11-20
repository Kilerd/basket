// `basket-docker`: a `docker` command for Apple's `container` CLI. Installed as `~/.basket/bin/docker`
// by `DockerShimInstaller`; translates the command line (`DockerCommandTranslator`) and execs `container`
// so stdin/stdout/stderr, the TTY, signals and the exit code pass through untouched.
//
// BASKET_DOCKER_DRYRUN=1 prints the translated command(s) instead of running them.
import BasketCore
import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment
let dryRun = environment["BASKET_DOCKER_DRYRUN"] == "1"

var options = DockerCommandTranslator.Options()
if arguments.contains("compose") {
    options.composeExecutable = DockerShimRuntime.composeExecutable(
        environment: environment, shimPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
}
let translation = DockerCommandTranslator.translate(arguments, options: options)
exit(ShimRunner(dryRun: dryRun, environment: environment).execute(translation))
