# What services.githubRepoRunners does to keep the runners' disk bounded: the
# shared tool cache, and the sweep of checkouts nobody uses any more. No runner
# is started (registering needs github.com); a process named like a runner's
# worker stands in for a job, and the sweep is run by hand with its settings
# overridden through SWEEP_* so each case needs no waiting.
#
# What it checks:
#   - the runners get XDG_CACHE_HOME and may write to it through their sandbox,
#     and NIX_CACHE_HOME still wins for Nix;
#   - a checkout unused for longer than `maxAge` goes, judged by its .git (the
#     directory it sits in was created long ago and says nothing); recent ones,
#     the runner's own hidden and _-prefixed directories, and a checkout whose
#     runner has a job all stay;
#   - when the disk is low, the stalest checkouts go first and the ones used
#     within `protectHours` stay;
#   - the tool cache is left alone the first time (the clock starts), left alone
#     while a job runs, and emptied in place afterwards: the same directory,
#     same owner, nothing in it.
{ ... }:
let
  root = "/var/lib/github-runner";
  gate = "/run/github-runners-gc";
  tools = "/var/cache/github-runner-tools";
  stamp = "/var/lib/github-runners-sweep/tool-cache-reset";
in
{
  name = "github-runner-sweep";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ ../modules/github-repo-runners.nix ];

      services.githubRepoRunners = {
        enable = true;
        owner = "Avunu";
        tokenFile = "/etc/fake-runner-token";
        runners.bench.repo = "bench";
        runners.other.repo = "other";
        dockerSocket = false;
      };
      systemd.services.github-runner-bench.wantedBy = lib.mkForce [ ];
      systemd.services.github-runner-other.wantedBy = lib.mkForce [ ];
    };

  testScript = ''
    import re

    machine.wait_for_unit("multi-user.target")

    sweep = re.findall(
        r"path=(\S+)",
        machine.succeed("systemctl show -p ExecStart --value github-runners-sweep.service"),
    )[0]

    def run_sweep(**env):
        """The sweep as the unit runs it, with settings overridden."""
        flags = " ".join(f"-E SWEEP_{k.upper()}={v}" for k, v in env.items())
        return machine.succeed(f"systemd-run --wait --pipe --collect {flags} {sweep} 2>&1")

    def checkout(runner, name, hours):
        """A checkout as actions/checkout leaves it, last used `hours` ago.

        Its directory and the one above it are brand new either way; only .git
        says when it was used."""
        path = f"${root}/work-{runner}/{name}/{name}"
        machine.succeed(
            f"install -d -o github-runner {path}/.git/objects",
            f"echo content > {path}/file",
            f"touch -d '{hours} hours ago' {path}/.git",
        )

    def exists(runner, name):
        return machine.execute(f"test -d ${root}/work-{runner}/{name}")[0] == 0

    def trash_empty(runner):
        machine.succeed(f"test -z \"$(ls -A ${root}/work-{runner}/.sweep-trash 2>/dev/null)\"")

    def start_job():
        machine.succeed(
            "systemd-run --unit=fake-job --collect /run/current-system/sw/bin/bash"
            " -c 'exec -a Runner.Worker /run/current-system/sw/bin/bash -c \"/run/current-system/sw/bin/sleep 600; :\"'"
        )
        machine.wait_until_succeeds("pgrep -f 'Runner[.]Worker'", timeout=15)

    with subtest("the runners share the tool cache, and Nix keeps its own"):
        env = machine.succeed("systemctl show -p Environment github-runner-bench.service")
        assert "XDG_CACHE_HOME=${tools}" in env, env
        assert "NIX_CACHE_HOME=/var/cache/github-runner-nix" in env, env
        rw = machine.succeed("systemctl show -p ReadWritePaths github-runner-bench.service")
        assert "${tools}" in rw, rw
        machine.succeed("[ \"$(stat -c '%U %a' ${tools})\" = 'github-runner 750' ]")
        machine.succeed("systemctl list-timers github-runners-sweep.timer | grep -q sweep")

    with subtest("old checkouts go, recent ones and the runner's own directories stay"):
        checkout("bench", "old-repo", 24 * 10)
        checkout("bench", "new-repo", 1)
        # A checkout on a runner that has a job is not touched, however old.
        checkout("other", "busy-repo", 24 * 10)
        machine.succeed("touch ${gate}/jobs/other")
        # The runner's HOME is hidden, and _actions, _tool, _temp are the runner's.
        for keep in [".cache/pkg", "_actions/act", "_tool/node"]:
            machine.succeed(
                f"install -d -o github-runner ${root}/work-bench/{keep}/.git",
                f"touch -d '30 days ago' ${root}/work-bench/{keep}/.git",
            )
        out = run_sweep(min_free_percent=0)
        assert "old-repo" in out, out
        assert not exists("bench", "old-repo")
        assert exists("bench", "new-repo")
        assert exists("other", "busy-repo")
        for keep in [".cache/pkg", "_actions/act", "_tool/node"]:
            machine.succeed(f"test -d ${root}/work-bench/{keep}")
        trash_empty("bench")

        # The job ends: the checkout it kept alive goes at the next sweep.
        machine.succeed("rm ${gate}/jobs/other")
        run_sweep(min_free_percent=0)
        assert not exists("other", "busy-repo")
        assert exists("bench", "new-repo")

    with subtest("on a low disk the stalest go first, and the recent ones are protected"):
        checkout("bench", "day-old", 30)
        checkout("bench", "hours-old", 3)
        checkout("other", "just-used", 1)
        # min == target == 100: always low and never satisfied, so it sweeps
        # everything older than protectHours and stops there.
        out = run_sweep(min_free_percent=100, target_free_percent=100, protect_hours=2)
        assert "disk is low" in out, out
        assert not exists("bench", "day-old")
        assert not exists("bench", "hours-old")
        assert exists("other", "just-used")
        assert exists("bench", "new-repo")
        trash_empty("bench")

        # And with enough free space it stops as soon as it has reached the target.
        checkout("bench", "kept-by-target", 30)
        run_sweep(min_free_percent=100, target_free_percent=0, protect_hours=2)
        assert exists("bench", "kept-by-target")

    with subtest("the tool cache: the clock starts, a job holds it off, then it is emptied in place"):
        machine.succeed(
            "su github-runner -s /bin/sh -c 'mkdir -p ${tools}/uv/wheels ${tools}/yarn && touch ${tools}/uv/wheels/a ${tools}/yarn/b ${tools}/.hidden'"
        )
        # The sweeps above already started the clock; start from before that.
        machine.succeed("rm -f ${stamp}")
        run_sweep(min_free_percent=0)
        machine.succeed("test -e ${stamp}", "test -e ${tools}/uv/wheels/a")

        machine.succeed("touch -d '40 days ago' ${stamp}")
        start_job()
        machine.succeed("touch ${gate}/jobs/bench")
        out = run_sweep(min_free_percent=0)
        assert "a job is running" in out, out
        machine.succeed("test -e ${tools}/uv/wheels/a")
        machine.fail("find ${stamp} -mmin -5 | grep -q .")

        before = machine.succeed("stat -c '%i %U %a' ${tools}").strip()
        machine.succeed("systemctl stop fake-job.service", "rm ${gate}/jobs/bench")
        out = run_sweep(min_free_percent=0)
        assert "Emptied ${tools}" in out, out
        machine.succeed("test -z \"$(ls -A ${tools})\"")
        assert machine.succeed("stat -c '%i %U %a' ${tools}").strip() == before
        machine.succeed("find ${stamp} -mmin -5 | grep -q .")

        # Emptied just now: not again.
        machine.succeed("touch ${tools}/fresh")
        run_sweep(min_free_percent=0)
        machine.succeed("test -e ${tools}/fresh")
  '';
}
