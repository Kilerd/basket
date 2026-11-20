import Foundation

extension DockerCommandTranslator {
    /// `docker`, `docker --help`.
    public static let helpText = """
        Usage:  docker COMMAND

        Basket's docker shim: runs Docker commands with Apple's `container` CLI.

        Containers:
          ps, run, create, start, stop, restart, kill, rm, logs, exec, inspect, cp, stats,
          commit, export, container ls|prune|…
        Images:
          images, pull, push, tag, rmi, save, load, build, image ls|inspect|prune|…
        Volumes and networks:
          volume create|ls|rm|inspect|prune, network create|ls|rm|inspect|prune
        Registry and system:
          login, logout, version, info, system df|info|prune

        Docker flags with an apple/container equivalent are translated; flags without one are
        dropped with a warning (--restart, --health-*, --log-*, …); flags that would change what
        you get (--privileged, --device, --network host, -P, …) are refused.
        `docker pull` fetches only this Mac's platform, like Docker does.
        `docker compose` is not supported yet: use Basket's Containers → Compose Up… (⇧⌘O).

        BASKET_DOCKER_DRYRUN=1 docker …   prints the `container` command instead of running it.
        Mapping table: https://github.com/Kilerd/basket/blob/main/docs/docker-shim.md

        """
}
