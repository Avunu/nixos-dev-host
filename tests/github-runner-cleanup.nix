# What services.githubRepoRunners does about disk: the shared Nix cache, its
# pruning, and removing what retired runners left behind. No runner is
# started (registering needs github.com); only their units are inspected.
#
# What it checks:
#   - the runners get NIX_CACHE_HOME and may write to it through their sandbox;
#   - directories no runner uses are removed from /var/lib/github-runner,
#     while current runners' state and work directories, hidden entries and
#     anything that is not a directory stay;
#   - the prune removes git repositories and evaluation caches untouched for
#     `pruneAfter` days, keeps recent ones, and skips a repository whose lock
#     is held.
{ ... }:
let
  cache = "/var/cache/github-runner-nix";
  root = "/var/lib/github-runner";
in
{
  name = "github-runner-cleanup";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ ../modules/github-repo-runners.nix ];

      services.githubRepoRunners = {
        enable = true;
        owner = "Avunu";
        tokenFile = "/etc/fake-runner-token";
        runners.bench.repo = "bench";
        dockerSocket = false;
      };
      systemd.services.github-runner-bench.wantedBy = lib.mkForce [ ];
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    with subtest("runners use the shared cache, and may write to it"):
        env = machine.succeed("systemctl show -p Environment github-runner-bench.service")
        assert "NIX_CACHE_HOME=${cache}" in env, env
        rw = machine.succeed("systemctl show -p ReadWritePaths github-runner-bench.service")
        assert "${cache}" in rw, rw
        machine.succeed("[ \"$(stat -c '%U %a' ${cache})\" = 'github-runner 750' ]")

    with subtest("what retired runners left is removed, and nothing else"):
        machine.succeed(
            "install -d -o github-runner ${root}/bench ${root}/work-bench/_temp",
            "install -d -o github-runner ${root}/old-runner ${root}/work-old-runner/checkout/.git",
            "touch ${root}/work-old-runner/checkout/result",
            "install -d -o github-runner ${root}/.cache/keep",
            "touch ${root}/a-file",
        )
        machine.succeed("systemctl restart github-runners-remove-stale-dirs.service")
        machine.wait_until_succeeds(
            "[ \"$(systemctl show -p SubState --value github-runners-remove-stale-dirs.service)\" = exited ]"
        )
        machine.fail("test -e ${root}/old-runner")
        machine.fail("test -e ${root}/work-old-runner")
        machine.succeed(
            "test -d ${root}/bench",
            "test -d ${root}/work-bench/_temp",
            "test -d ${root}/.cache/keep",
            "test -f ${root}/a-file",
        )

    with subtest("the cache prune keeps what is in use and removes what is not"):
        machine.succeed(
            "cd ${cache} && su github-runner -s /bin/sh -c '"
            "mkdir -p gitv3/old/objects/pack gitv3/fresh/objects/pack gitv3/held/objects/pack eval-cache-v6 &&"
            "touch gitv3/old.lock gitv3/fresh.lock gitv3/held.lock gitv3/orphan.lock gitv3/fresh/FETCH_HEAD &&"
            "touch eval-cache-v6/old.sqlite eval-cache-v6/old.sqlite-wal eval-cache-v6/new.sqlite"
            "'",
            # Everything but `fresh` and new.sqlite last changed a month ago.
            "cd ${cache} && find gitv3/old gitv3/held gitv3/old.lock gitv3/held.lock gitv3/orphan.lock"
            " eval-cache-v6/old.sqlite eval-cache-v6/old.sqlite-wal -exec touch -d '30 days ago' {} +",
        )
        # A fetch under way holds the repository's lock.
        machine.succeed("su github-runner -s /bin/sh -c 'flock ${cache}/gitv3/held.lock sleep 600' >&2 &")
        machine.wait_until_succeeds("! flock -n ${cache}/gitv3/held.lock true")
        machine.succeed("systemctl start github-runners-prune-nix-cache.service")
        machine.fail("test -e ${cache}/gitv3/old")
        machine.fail("test -e ${cache}/gitv3/old.lock")
        machine.fail("test -e ${cache}/gitv3/orphan.lock")
        machine.fail("test -e ${cache}/eval-cache-v6/old.sqlite")
        machine.fail("test -e ${cache}/eval-cache-v6/old.sqlite-wal")
        machine.succeed(
            "test -d ${cache}/gitv3/fresh",
            "test -e ${cache}/gitv3/fresh.lock",
            "test -d ${cache}/gitv3/held",
            "test -e ${cache}/eval-cache-v6/new.sqlite",
        )
        machine.succeed("systemctl list-timers github-runners-prune-nix-cache.timer | grep -q prune")
  '';
}
