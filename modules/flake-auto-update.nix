{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.devHost.flakeAutoUpdate;

  # One pass over one repository: bring a clone up to the remote base branch,
  # re-lock every input, and push the lock if it moved. Nothing is committed
  # unless flake.lock changed, so on a quiet day the timer does nothing but
  # fetch.
  #
  # A failed push is not repaired here. The next pass starts again from the
  # remote, so a push rejected because someone else pushed in between is
  # retried against their commit.
  refresh =
    name: repo:
    let
      dir = "${cfg.stateDirectory}/${name}";
      target = if repo.pushBranch == null then repo.branch else repo.pushBranch;
    in
    pkgs.writeShellApplication {
      name = "flake-auto-update-${name}";
      runtimeInputs = [
        pkgs.git
        config.nix.package
        pkgs.coreutils
      ];
      text = ''
        dir=${escapeShellArg dir}
        base=${escapeShellArg repo.branch}
        target=${escapeShellArg target}

        if [ ! -d "$dir/.git" ]; then
          git clone -q -- ${escapeShellArg repo.url} "$dir"
        fi
        cd "$dir"

        git fetch -q --prune origin
        git checkout -q -f -B "$target" "origin/$base"

        nix flake update

        # Nothing moved since base, or the target already carries this lock:
        # either way there is nothing to push, and skipping keeps a side branch
        # from being rewritten every interval.
        if git diff --quiet -- flake.lock; then
          echo "flake.lock already matches origin/$base"
          exit 0
        fi
        if [ "$(git hash-object -- flake.lock)" = "$(git rev-parse -q --verify "origin/$target:flake.lock" || true)" ]; then
          echo "origin/$target already has this flake.lock"
          exit 0
        fi

        git add flake.lock
        git -c user.name=flake-auto-update \
          -c "user.email=flake-auto-update@${config.networking.hostName}" \
          commit -q -m "chore: update flake"
        # The lease is against the remote-tracking ref fetched above: if the
        # target moved since, the push is refused and the next run starts over.
        git push --force-with-lease origin "HEAD:refs/heads/$target"
      '';
    };

  unitFor = name: repo: {
    service = {
      name = "flake-auto-update-${name}";
      value = {
        description = "Refresh and push the flake.lock of ${repo.url}";
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          # nix reads root's config and the access-tokens line for private
          # inputs from there, the same way system-upgrade does.
          Environment = "HOME=/root";
          ExecStart = getExe (refresh name repo);
          # Same posture as system-upgrade: a background job that evaluates and
          # downloads should yield to whoever is using the box.
          MemoryHigh = mkDefault "25%";
          CPUWeight = mkDefault 20;
          Nice = mkDefault 19;
        };
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        path = [
          pkgs.git
          config.nix.package
        ];
      };
    };
    timer = {
      name = "flake-auto-update-${name}";
      value = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = repo.interval;
          Unit = "flake-auto-update-${name}.service";
        };
      };
    };
  };

  units = mapAttrsToList unitFor cfg.repositories;
in
{
  config = mkIf (cfg.repositories != { }) {
    systemd.services = listToAttrs (map (u: u.service) units);
    systemd.timers = listToAttrs (map (u: u.timer) units);
  };
}
