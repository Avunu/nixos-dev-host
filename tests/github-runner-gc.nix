# Garbage collection waits for the runners' jobs. No runner is started
# (registering needs github.com): the test runs each runner's real hooks in the
# unit's sandbox, and a process named like a runner's worker stands in for a job.
#
# What it checks:
#   - the runners have the hooks and may write to the gate;
#   - determinate-nixd's own collector is off, according to the daemon itself;
#   - with no job running, nix-gc collects, and clears a dead runner's mark;
#   - with a job running, nix-gc collects nothing until the job ends, holds a
#     new job back once `idleWait` is up, and lets it go when it has collected;
#   - if the job outlasts `drainWait`, nix-gc fails, collects nothing, and new
#     jobs start again;
#   - low disk space starts nix-gc, but not again within 6 hours.
{ inputs }:
{ ... }:
let
  gate = "/run/github-runners-gc";
in
{
  name = "github-runner-gc";

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        inputs.determinate.nixosModules.default
        ../modules/github-repo-runners.nix
      ];

      services.githubRepoRunners = {
        enable = true;
        owner = "Avunu";
        tokenFile = "/etc/fake-runner-token";
        runners.bench.repo = "bench";
        dockerSocket = false;
        gc = {
          idleWait = 1;
          drainWait = 1;
          # Always "low", so the test can start it by hand.
          minFreePercent = 100;
        };
      };
      systemd.services.github-runner-bench.wantedBy = lib.mkForce [ ];
    };

  testScript = ''
    import re

    machine.wait_for_unit("multi-user.target")

    env = machine.succeed("systemctl show -p Environment github-runner-bench.service")
    started = re.findall(r"ACTIONS_RUNNER_HOOK_JOB_STARTED=(\S+)", env)[0]
    completed = re.findall(r"ACTIONS_RUNNER_HOOK_JOB_COMPLETED=(\S+)", env)[0]

    def hook(path, timeout=""):
        """As the runner runs a hook: bash -e, as its user, in its sandbox."""
        return (
            "systemd-run --wait --pipe --collect -p User=github-runner"
            f" -p ProtectSystem=strict -p ReadWritePaths=${gate} {timeout}"
            f" /run/current-system/sw/bin/bash -e {path}"
        )

    def garbage(name):
        """A path nothing refers to."""
        return machine.succeed(
            f"echo {name} > /tmp/{name} && nix-store --add /tmp/{name} && rm /tmp/{name}"
        ).strip()

    def start_job():
        # A bash, because coreutils' sleep goes by its argv[0]. The ":" stops bash
        # exec-ing the sleep, which would lose the name.
        machine.succeed(
            "systemd-run --unit=fake-job --collect /run/current-system/sw/bin/bash"
            " -c 'exec -a Runner.Worker /run/current-system/sw/bin/bash -c \"/run/current-system/sw/bin/sleep 600; :\"'"
        )
        machine.wait_until_succeeds("pgrep -f 'Runner[.]Worker'", timeout=15)

    def stop_job():
        machine.succeed("systemctl stop fake-job.service")

    def gc_state():
        return machine.succeed("systemctl show -p ActiveState --value nix-gc.service").strip()

    with subtest("the runners have the hooks and can reach the gate"):
        assert started.endswith(".sh") and completed.endswith(".sh"), env
        rw = machine.succeed("systemctl show -p ReadWritePaths github-runner-bench.service")
        assert "${gate}" in rw, rw

    with subtest("determinate-nixd's collector is off"):
        machine.succeed("grep -q '\"strategy\":\"disabled\"' /etc/determinate/config.json")
        # The daemon is socket-activated, and root otherwise goes straight to the store.
        machine.succeed("NIX_REMOTE=daemon nix-store --query --hash /run/current-system")
        machine.wait_until_succeeds(
            # -a and grep -a: the daemon's lines carry colour codes.
            "journalctl -b -a --no-pager | grep -aq 'strategy=disabled; skipping'",
            timeout=120,
        )

    with subtest("no job: it collects, and a dead runner's mark does not hold it up"):
        path = garbage("idle")
        machine.succeed("touch ${gate}/jobs/dead-runner")
        machine.succeed("systemctl start nix-gc.service")
        machine.fail(f"nix-store --check-validity {path}")
        machine.fail("test -e ${gate}/jobs/dead-runner")

    with subtest("a job holds it off, a new job waits, and both finish"):
        path = garbage("busy")
        start_job()
        machine.succeed(hook(started))
        machine.succeed("test -e ${gate}/jobs/bench")

        machine.succeed("systemctl start --no-block nix-gc.service")
        # Looking for an idle moment: new jobs still start.
        machine.succeed("sleep 5")
        assert gc_state() == "activating", gc_state()
        machine.succeed(hook(started))

        # Past idleWait: running jobs drain, new ones wait in their hook.
        machine.wait_until_succeeds(
            "journalctl -u nix-gc.service -b --no-pager | grep -q 'holding new jobs back'",
            timeout=120,
        )
        machine.succeed(f"nix-store --check-validity {path}")
        machine.fail(hook(started, "--property=RuntimeMaxSec=5"))

        machine.succeed(hook(completed))
        machine.fail("test -e ${gate}/jobs/bench")
        stop_job()
        machine.wait_until_succeeds("systemctl show -p ActiveState --value nix-gc.service | grep -qx inactive", timeout=90)
        machine.fail(f"nix-store --check-validity {path}")
        machine.succeed(hook(started))
        machine.succeed(hook(completed))

    with subtest("a job that outlasts drainWait: it gives up and lets new jobs start"):
        path = garbage("long")
        start_job()
        machine.succeed(hook(started))
        machine.succeed("systemctl start --no-block nix-gc.service")
        machine.wait_until_succeeds("systemctl is-failed nix-gc.service", timeout=240)
        machine.succeed(f"nix-store --check-validity {path}")
        machine.succeed("journalctl -u nix-gc.service -b --no-pager | grep -q 'not collecting'")
        machine.succeed(hook(started))
        machine.succeed(hook(completed))
        stop_job()
        machine.succeed("systemctl reset-failed nix-gc.service")

    with subtest("low disk space starts it, but not again within 6 hours"):
        path = garbage("pressure")
        machine.succeed("rm -f ${gate}/last-collection")
        machine.succeed("systemctl start github-runners-gc-under-pressure.service")
        machine.wait_until_succeeds(f"! nix-store --check-validity {path}", timeout=60)
        path = garbage("pressure-again")
        machine.wait_until_succeeds("systemctl show -p ActiveState --value nix-gc.service | grep -qx inactive", timeout=60)
        machine.succeed("systemctl start github-runners-gc-under-pressure.service")
        machine.succeed("sleep 3")
        machine.succeed(f"nix-store --check-validity {path}")
        machine.succeed(
            "journalctl -u github-runners-gc-under-pressure.service -b --no-pager | grep -q 'in the last 6 hours'"
        )
        machine.succeed("systemctl list-timers github-runners-gc-under-pressure.timer | grep -q pressure")
  '';
}
