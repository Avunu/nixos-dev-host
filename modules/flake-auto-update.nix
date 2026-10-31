{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.devHost.flakeAutoUpdate;
  app = config.devHost.githubApp;
  writer = app.writer;

  githubAppToken = import ../pkgs/github-app-token.nix { inherit pkgs; };

  # owner and name of a GitHub repository URL, or null for anything else.
  githubRepoOf =
    url:
    let
      m = builtins.match "https://github\\.com/([^/]+)/([^/]+)" (removeSuffix "/" url);
    in
    if m == null then
      null
    else
      {
        owner = elemAt m 0;
        name = removeSuffix ".git" (elemAt m 1);
      };

  # With the writer App, the push authenticates with the run's own token
  # (GH_TOKEN, minted in `refresh`) instead of the shared credential helper:
  # the empty helper clears the system's, and the one after it answers from
  # the environment. Only the push: `nix flake update` still fetches private
  # inputs with the shared, read-only token, which can see more than the one
  # repository this token is narrowed to.
  pushAuth = optionalString (writer != null) (
    "-c credential.https://github.com.helper= -c "
    + escapeShellArg ''credential.https://github.com.helper=!f() { test "$1" = get && printf 'username=x-access-token\npassword=%s\n' "$GH_TOKEN"; }; f''
  );

  # One branch's worth of a pass, run from inside the clone that refresh has
  # just fetched: rebuild the branch as the remote base branch plus one lock
  # commit, re-lock (every input, or only the ones named after the branch and
  # title), and push if that differs from what the remote branch holds.
  #
  # Rebuilding from base on every pass is what keeps a side branch mergeable:
  # nothing is rebased, the lock is simply re-locked on top of wherever base is
  # now, so a lock change that lands on base never leaves the pull request in
  # conflict. A side branch whose parent is still base and whose lock already
  # matches is left alone, so it is only rewritten when base or the lock moves.
  #
  # When the lock goes to a side branch rather than the base branch, the pass
  # also makes sure a pull request carries it. The push itself is what updates
  # an open one; this only opens one when none is, and closes one whose changes
  # have already reached base some other way.
  #
  # A failed push or pull request is not repaired here. The next pass starts
  # again from the remote, so a push rejected because someone else pushed in
  # between is retried against their commit, and a pull request that could not
  # be opened is retried against the branch that is already pushed.
  updateBranch =
    name: repo:
    let
      side = repo.pushBranch != null && repo.pushBranch != repo.branch;
    in
    pkgs.writeShellApplication {
      name = "flake-auto-update-${name}-branch";
      runtimeInputs = [
        pkgs.git
        config.nix.package
        pkgs.coreutils
      ]
      ++ optionals side [
        pkgs.gh
        pkgs.jq
      ];
      text = ''
        target=$1
        title=$2
        shift 2
        base=${escapeShellArg repo.branch}

        git checkout -q -f -B "$target" "origin/$base"

        # No inputs named means all of them.
        nix flake update "$@"

        # Nothing moved since base: there is nothing to push, and nothing for a
        # pull request to carry.
        if git diff --quiet -- flake.lock; then
          echo "$target: flake.lock already matches origin/$base"
          ${optionalString side ''
            # Whatever an open pull request carried has reached base some other
            # way (another of these pull requests, or a hand edit), so it has
            # nothing left to merge.
            for pr in $(gh pr list --state open --base "$base" --head "$target" --json number --jq '.[].number'); do
              gh pr close "$pr" --delete-branch \
                --comment "origin/$base already has everything this pull request carried."
            done
          ''}
          exit 0
        fi

        # The target is already base plus this lock: skipping the push keeps a
        # side branch from being rewritten every interval. A target whose parent
        # is no longer base is rebuilt even when the lock is the same, which is
        # what keeps its pull request rebased on base.
        current=$(git rev-parse -q --verify "origin/$target" || true)
        if [ -n "$current" ] \
          && [ "$(git rev-parse -q --verify "$current^" || true)" = "$(git rev-parse "origin/$base")" ] \
          && [ "$(git rev-parse -q --verify "$current:flake.lock" || true)" = "$(git hash-object -- flake.lock)" ]; then
          echo "origin/$target is already origin/$base plus this flake.lock"
        else
          git add flake.lock
          git -c user.name=flake-auto-update \
            -c "user.email=flake-auto-update@${config.networking.hostName}" \
            commit -q -m "$title"
          # The lease is against the remote-tracking ref fetched above: if the
          # target moved since, the push is refused and the next run starts over.
          ${
            optionalString (writer != null) ''
              # $GH_TOKEN is single-quoted on purpose: the helper reads it from
              # the environment, so the token itself is never an argument.
              # shellcheck disable=SC2016
            ''
          }git ${pushAuth} push --force-with-lease origin "HEAD:refs/heads/$target"
        fi
      ''
      + optionalString side ''

        # Only a side branch needs a pull request; a push to the base branch
        # is the change.
        #
        # The pull request is identified by what it changes, not by its head
        # commit: the head is rebuilt whenever base moves, but a lock carrying
        # the same input revisions is the same question. The marker records
        # those revisions in the body, so a closed or merged pull request for
        # them is not asked again; an input that moves again is a new question.
        changes=$(jq -rn --slurpfile old <(git show "origin/$base:flake.lock") --slurpfile new flake.lock '
          def ref: if . == null then "none" else (.rev // .narHash // "?")[0:12] end;
          $old[0].nodes as $o
          | $new[0].nodes | to_entries[]
          | select(.value.locked != null and .value.locked != $o[.key].locked)
          | "- `\(.key)`: \($o[.key].locked | ref) → \(.value.locked | ref)"')
        marker="<!-- flake-auto-update: $(sha256sum <<<"$changes" | cut -c1-16) -->"
        body=$(printf '%s\n\n%s\n\n%s\n' \
          "Automated flake.lock refresh from ${config.networking.hostName}. This branch is rebuilt from $base plus one lock commit whenever $base or the lock moves, so it stays mergeable; merge it when it is ready." \
          "$changes" "$marker")

        prs=$(gh pr list --state all --base "$base" --head "$target" --json number,state,body)
        open=$(jq -r 'first(.[] | select(.state == "OPEN")) | .number' <<<"$prs")

        if [ -n "$open" ]; then
          # The push above already updated its commits; the body is kept to
          # match, so the marker a reviewer closes it under is the right one.
          if jq -e --argjson n "$open" --arg m "$marker" 'any(.[]; .number == $n and (.body | contains($m)))' <<<"$prs" >/dev/null; then
            echo "$target already has a pull request for this flake.lock"
          else
            gh pr edit "$open" --title "$title" --body "$body"
          fi
        elif jq -e --arg m "$marker" 'any(.[]; .body | contains($m))' <<<"$prs" >/dev/null; then
          echo "$target already had a pull request for these input revisions"
        else
          gh pr create --base "$base" --head "$target" --title "$title" --body "$body"
        fi
      '';
    };

  # One pass over one repository: bring a clone up to the remote, then hand
  # each branch the grouping asks for to updateBranch. Nothing is committed
  # unless flake.lock changed, so on a quiet day the timer does nothing but
  # fetch.
  #
  # Each branch runs as its own process, so one input that fails to lock or
  # push does not stop the others; the pass still fails if any of them did.
  refresh =
    name: repo:
    let
      dir = "${cfg.stateDirectory}/${name}";
      target = if repo.pushBranch == null then repo.branch else repo.pushBranch;
      side = target != repo.branch;
      tokenFile = config.devHost.githubTokenFile;
      branch = getExe (updateBranch name repo);
    in
    pkgs.writeShellApplication {
      name = "flake-auto-update-${name}";
      runtimeInputs = [
        pkgs.git
        pkgs.coreutils
      ]
      ++ optionals side [
        pkgs.gnused
        pkgs.jq
      ]
      ++ optional (writer != null) githubAppToken;
      text = ''
        dir=${escapeShellArg dir}
        target=${escapeShellArg target}

        if [ ! -d "$dir/.git" ]; then
          git clone -q -- ${escapeShellArg repo.url} "$dir"
        fi
        cd "$dir"

        git fetch -q --prune origin
      ''
      + optionalString (writer != null) ''

        # This run's own token, from the writer App: narrowed to this one
        # repository, contents and pull requests write, and gone within the
        # hour. The push and gh both take it from GH_TOKEN; it is never written
        # anywhere, nor passed as an argument.
        GH_TOKEN=$(github-app-token \
          --api-url ${escapeShellArg app.apiUrl} \
          --app-id ${toString writer.appId} \
          --key-file ${escapeShellArg writer.privateKeyFile} \
          --owner ${escapeShellArg (githubRepoOf repo.url).owner} \
          --repository ${escapeShellArg (githubRepoOf repo.url).name} \
          --permission contents=write \
          --permission pull_requests=write)
        export GH_TOKEN
      ''
      + optionalString (writer == null && side && tokenFile != null) ''

        # gh is handed the same token git pushes with, by asking git for it, so
        # there is one place the GitHub credential is configured (secrets.nix).
        GH_TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' \
          | GIT_TERMINAL_PROMPT=0 git credential fill \
          | sed -n 's/^password=//p')
        export GH_TOKEN
      ''
      + ''

        failed=0
      ''
      + optionalString (repo.grouping != "on") ''
        ${branch} "$target" "chore: update flake" || failed=1
      ''
      + optionalString (repo.grouping != "off") ''

        # The root's own inputs, as base locks them; one that only follows
        # another input has nothing of its own to update.
        inputs=$(git show ${escapeShellArg "origin/${repo.branch}:flake.lock"} \
          | jq -r '.nodes[.root].inputs | to_entries[] | select(.value | type == "string") | .key')
        for input in $inputs; do
          ${branch} "$target-$input" "chore: update flake input $input" "$input" || failed=1
        done
      ''
      + ''

        exit "$failed"
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
    # Separate pull requests need somewhere separate to live; pushing each
    # input straight onto the base branch would just be the ungrouped update
    # split into commits.
    assertions = concatLists (
      mapAttrsToList (name: repo: [
        {
          assertion = repo.grouping == "off" || (repo.pushBranch != null && repo.pushBranch != repo.branch);
          message = "devHost.flakeAutoUpdate.repositories.${name}.grouping = \"${repo.grouping}\" opens a pull request per input, so it needs a pushBranch other than branch.";
        }
        {
          # The writer's token is narrowed to the repository by owner and name.
          assertion = writer == null || githubRepoOf repo.url != null;
          message = "devHost.flakeAutoUpdate.repositories.${name}.url is not an https://github.com/<owner>/<name> URL, which devHost.githubApp.writer needs to narrow its token to it.";
        }
      ]) cfg.repositories
    );

    systemd.services = listToAttrs (map (u: u.service) units);
    systemd.timers = listToAttrs (map (u: u.timer) units);
  };
}
