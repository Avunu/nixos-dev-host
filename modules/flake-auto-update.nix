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
  # When the lock goes to a side branch rather than the base branch, the pass
  # also makes sure a pull request carries it. The push itself is what updates
  # an open one; this only opens one when none is.
  #
  # A failed push or pull request is not repaired here. The next pass starts
  # again from the remote, so a push rejected because someone else pushed in
  # between is retried against their commit, and a pull request that could not
  # be opened is retried against the branch that is already pushed.
  refresh =
    name: repo:
    let
      dir = "${cfg.stateDirectory}/${name}";
      target = if repo.pushBranch == null then repo.branch else repo.pushBranch;
      tokenFile = config.devHost.githubTokenFile;
    in
    pkgs.writeShellApplication {
      name = "flake-auto-update-${name}";
      runtimeInputs = [
        pkgs.git
        config.nix.package
        pkgs.coreutils
      ]
      ++ optionals (target != repo.branch) [
        pkgs.gh
        pkgs.gnused
        pkgs.jq
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

        # Nothing moved since base: there is nothing to push, and nothing for a
        # pull request to carry.
        if git diff --quiet -- flake.lock; then
          echo "flake.lock already matches origin/$base"
          exit 0
        fi

        # The target already carries this lock: skipping the push keeps a side
        # branch from being rewritten every interval.
        if [ "$(git hash-object -- flake.lock)" = "$(git rev-parse -q --verify "origin/$target:flake.lock" || true)" ]; then
          echo "origin/$target already has this flake.lock"
        else
          git add flake.lock
          git -c user.name=flake-auto-update \
            -c "user.email=flake-auto-update@${config.networking.hostName}" \
            commit -q -m "chore: update flake"
          # The lease is against the remote-tracking ref fetched above: if the
          # target moved since, the push is refused and the next run starts over.
          git push --force-with-lease origin "HEAD:refs/heads/$target"
        fi
      ''
      + optionalString (target != repo.branch) ''

        # Only a side branch needs a pull request; a push to the base branch
        # is the change.
        #
        # gh is handed the same token git pushes with, by asking git for it, so
        # there is one place the GitHub credential is configured (secrets.nix).
        ${optionalString (tokenFile != null) ''
          GH_TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' \
            | GIT_TERMINAL_PROMPT=0 git credential fill \
            | sed -n 's/^password=//p')
          export GH_TOKEN
        ''}
        sha=$(git rev-parse "origin/$target")
        prs=$(gh pr list --state all --base "$base" --head "$target" --json state,headRefOid)

        # An open pull request is already updated by the push above. A closed or
        # merged one for this exact commit was an answer to this exact lock, so
        # it is not asked again; a lock that moves again is a new commit, and a
        # new question.
        if jq -e --arg sha "$sha" 'any(.[]; .state == "OPEN" or .headRefOid == $sha)' <<<"$prs" >/dev/null; then
          echo "$target already has a pull request for this flake.lock"
        else
          gh pr create --base "$base" --head "$target" \
            --title "chore: update flake" \
            --body "Automated flake.lock refresh from ${config.networking.hostName}. This branch is rebuilt from $base plus one lock commit whenever the lock moves, so merge it when it is ready."
        fi
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
