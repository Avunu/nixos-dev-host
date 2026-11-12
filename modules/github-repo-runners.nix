# Self-hosted GitHub Actions runners, one per repository, on top of nixpkgs'
# services.github-runners: name a repo, get a runner.
#
#   services.githubRepoRunners = {
#     enable = true;
#     owner = "Avunu";
#     tokenFile = config.age.secrets.some-pat.path;
#     repos = [ "repo-a" "repo-b" ];            # by name alone: one runner each
#     # or { repo-a = 1; repo-b = 8; }          # with how many runners each gets
#     runners.repo-c-big = {                    # or spelled out, for the odd one
#       repo = "repo-c";
#       tokenFile = config.age.secrets.repo-c-pat.path;
#     };
#   };
#
# Or for the whole organisation at once, registered through a GitHub App
# rather than a PAT:
#
#   services.githubRepoRunners = {
#     enable = true;
#     owner = "Avunu";
#     githubApp = { appId = 123456; privateKeyFile = config.age.secrets.app-key.path; };
#     orgRunners = 8;                           # any repository's jobs
#     runners.bench = { extraLabels = [ "bench" ]; };   # no `repo`: org-wide too
#   };
#
# An organisation runner registers against https://github.com/<owner> and
# takes jobs from every repository the runner group allows, so labels are what
# keep one repository's jobs on its own runners. Its registration token is
# minted just before each start: the App signs a JWT, gets an installation
# token narrowed to organization_self_hosted_runners, and spends it on
# `POST /orgs/<owner>/actions/runners/registration-token`; nixpkgs then sees a
# token it has not registered with and registers afresh, replacing the
# runner of the same name. So every start is a new registration, and nothing
# that outlives an hour is stored but the App's key, which only root reads.
#
# All runners share one user and one Nix fetcher cache (`nixCache`), but each
# gets its own workDir, so two concurrent jobs cannot collide over one
# checkout. The cache has to be pointed at explicitly: nixpkgs sets every
# runner's HOME to its workDir, so ~/.cache/nix would be one full copy of every
# git input per runner (10 GB each, within a day, on nix-runner-elitedesk).
#
# What the runners leave behind is cleaned up too: a runner that is renamed
# or removed leaves its workDir and state directory (and the GC roots in
# them) where they were, so those are deleted (`removeStaleDirs`), and the
# shared cache is pruned of repositories no job has fetched for a while.
#
# The same HOME also holds every other tool's cache (~/.cache: uv, yarn, prek…),
# which is where a workDir's disk goes next: 16 GB of it per runner on
# nix-runner-elitedesk, twenty times over, with 87 GiB on disk for caches that
# are the same bytes in every runner. `toolCache` points XDG_CACHE_HOME at one
# shared directory instead, emptied now and then while no job runs.
#
# And a workDir keeps a checkout of every repository its runner has ever
# served. With a pool of runners that take any repository's jobs, that is every
# repository on every runner (20 × ~40 GB, 94 GiB of it .git). `sweep` removes
# the checkouts nothing has used for a while, and the stalest ones sooner when
# the disk runs low. It takes the same gate as garbage collection, so it never
# removes a checkout from under a running job.
#
# Garbage collection waits for the jobs: see `gcGate` below.
#
# Not part of nixosModules.devHost: a host opts in by importing
# nixos-dev-host.nixosModules.githubRepoRunners. The one thing it still
# provides itself is the token's agenix secret, owned by `user`.
#
# Besides the runners this sets up what they need to be of any use: the user,
# trusted in nix.settings.trusted-users (or the workflows' `access-tokens` are
# silently ignored); the packages a workflow written for GitHub's hosted Ubuntu
# image expects; and the nix-ld libraries that the prebuilt toolchains
# setup-node, setup-python, setup-uv and setup-bun download need.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.githubRepoRunners;
  inherit (lib) mkOption types;

  # What a workflow written for GitHub's hosted Ubuntu image commonly calls, so
  # jobs can move here with `runs-on` alone. The first four are what
  # actions/checkout (git) and actions/cache (tar, zstd, gzip) need; nixpkgs'
  # runner unit already adds bash, coreutils and nix.
  hostedImagePackages = with pkgs; [
    git
    gnutar
    gzip
    zstd

    curl
    diffutils
    file
    findutils
    gawk
    gh
    gnugrep
    gnumake
    gnused
    jq
    nodejs
    openssh
    procps
    python3
    unzip
    wget
    which
    xz
    zip
  ];

  # What the binaries those setup-* actions download expect from an Ubuntu
  # image. They are added to nixpkgs' own default set (a list option, so the
  # definitions concatenate).
  nixLdLibraries = with pkgs; [
    stdenv.cc.cc.lib
    bzip2
    curl
    expat
    gdbm
    icu
    keyutils
    krb5
    libffi
    libuuid
    libxcrypt-legacy
    libxml2
    ncurses
    openssl
    readline
    sqlite
    util-linux
    xz
    zlib
  ];

  workDirOf = key: "${cfg.workRoot}/work-${key}";
  unitOf = key: "github-runner-${key}";

  # ── Garbage collection ───────────────────────────────────────
  # A job's store paths are not all rooted while it runs. A step that built
  # something and a later step that uses it share a store path and nothing
  # else, so a collection between the two takes it away and every job on the
  # machine fails in the same second. So on a runner host nothing collects
  # while a job runs:
  #
  #   - each job's started hook takes the lock shared, marks the job as running
  #     and lets go; its completed hook removes the mark. While a collection
  #     holds the lock, a job starting just waits in its hook.
  #   - nix-gc takes the lock exclusively and collects only with no job marked.
  #     It looks for an idle moment for `gc.idleWait`, and then holds the lock
  #     so running jobs drain and new ones wait, for at most `gc.drainWait`.
  #   - determinate-nixd's own disk-pressure collector, which no unit here can
  #     order against, is turned off. `gc.minFreePercent` replaces it.
  #
  # `nix-collect-garbage` run by hand is not covered: use
  # `systemctl start nix-gc` on these machines.
  gateDir = "/run/github-runners-gc";
  gateLock = "${gateDir}/lock";
  gateJobs = "${gateDir}/jobs";
  gateStamp = "${gateDir}/last-collection";

  # The runner runs a hook as `bash -e`, and only one whose name ends in .sh. A
  # gate that cannot do its work must never be what fails a job.
  jobStartedHook =
    key:
    pkgs.writeShellScript "github-runner-job-started-${key}.sh" ''
      exec 9>${gateLock} || exit 0
      ${pkgs.util-linux}/bin/flock -s 9 || exit 0
      : >${gateJobs}/${key} || exit 0
    '';
  jobCompletedHook =
    key:
    pkgs.writeShellScript "github-runner-job-completed-${key}.sh" ''
      ${pkgs.coreutils}/bin/rm -f ${gateJobs}/${key} || exit 0
    '';

  # Holds fd 9, the lock, through the exec, so it is let go of when the
  # collection ends, whichever way it ends.
  gatedCollection = pkgs.writeShellApplication {
    name = "github-runners-gated-gc";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.procps
      pkgs.util-linux
    ];
    text = ''
      idle_until=$((SECONDS + ${toString (cfg.gc.idleWait * 60)}))
      exec 9>${gateLock}

      # Call with the lock held, so no job is between its Runner.Worker
      # starting and its mark being written. With no Runner.Worker on the
      # machine, any mark left is from a runner that died mid-job.
      jobs_running() {
        if ! pgrep -f 'Runner\.Worker' >/dev/null; then
          find ${gateJobs} -mindepth 1 -delete
          return 1
        fi
        [ -n "$(ls -A ${gateJobs})" ]
      }

      while :; do
        flock 9
        jobs_running || break
        if [ "$SECONDS" -ge "$idle_until" ]; then
          echo "No idle moment in ${toString cfg.gc.idleWait} minutes: holding new jobs back until the running ones finish."
          drain_until=$((SECONDS + ${toString (cfg.gc.drainWait * 60)}))
          while jobs_running; do
            if [ "$SECONDS" -ge "$drain_until" ]; then
              echo "Jobs still running after ${toString cfg.gc.drainWait} minutes: not collecting."
              exit 1
            fi
            sleep 30
          done
          break
        fi
        flock -u 9
        sleep 30
      done

      touch ${gateStamp}
      exec ${config.nix.package.out}/bin/nix-collect-garbage ${config.nix.gc.options}
    '';
  };

  # A collection that frees nothing must not drain the jobs again an hour
  # later, hence the stamp.
  collectUnderPressure = pkgs.writeShellApplication {
    name = "github-runners-gc-under-pressure";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.systemd
    ];
    text = ''
      used=$(df --output=pcent /nix/store | tail -n 1 | tr -dc '0-9')
      [ "$((100 - used))" -lt ${toString cfg.gc.minFreePercent} ] || exit 0
      if [ -n "$(find ${gateStamp} -mmin -360 2>/dev/null)" ]; then
        echo "Only $((100 - used))% of /nix/store is free, but it was collected in the last 6 hours."
        exit 0
      fi
      echo "Only $((100 - used))% of /nix/store is free: collecting."
      systemctl start --no-block nix-gc.service
    '';
  };

  # ── Cleanup ──────────────────────────────────────────────────
  # nixpkgs puts every runner's state directory in %S/github-runner/<name>.
  stateRoot = "/var/lib/github-runner";
  workRoot = toString cfg.workRoot;
  cacheDir = cfg.nixCache.directory;

  # What belongs in `root`: the state directories of every runner nixpkgs
  # knows about (not only this module's), their workDirs, and the shared
  # cache if it lives there. Anything else that is a directory and not hidden
  # is what a runner that no longer exists left behind.
  expectedIn =
    root:
    let
      runners = config.services.github-runners;
      topOf = path: lib.head (lib.splitString "/" (lib.removePrefix "${root}/" path));
    in
    lib.unique (
      lib.optionals (root == stateRoot) (lib.attrNames runners)
      ++ lib.concatLists (
        lib.mapAttrsToList (
          _: r: lib.optional (r.workDir != null && lib.hasPrefix "${root}/" r.workDir) (topOf r.workDir)
        ) runners
      )
      ++ lib.optional (cacheDir != null && lib.hasPrefix "${root}/" cacheDir) (topOf cacheDir)
    );

  # The names are baked into the script, so the unit changes (and
  # switch-to-configuration restarts it) whenever a runner comes or goes.
  removeStaleDirs = pkgs.writeShellApplication {
    name = "github-runners-remove-stale-dirs";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      remove_stale() {
        local root=$1
        shift
        [ -d "$root" ] || return 0
        local -A keep=()
        local name
        for name in "$@"; do keep[$name]=1; done
        while IFS= read -r -d "" name; do
          if [ -z "''${keep[$name]:-}" ]; then
            echo "Removing $root/$name: no runner uses it any more."
            # Not past a mount (a container's subvolume, say); that much stays.
            rm -rf --one-file-system -- "''${root:?}/$name" ||
              echo "Could not remove all of $root/$name."
          fi
        done < <(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\0')
      }
    ''
    +
      lib.concatMapStrings
        (root: ''
          remove_stale ${lib.escapeShellArgs ([ root ] ++ expectedIn root)}
        '')
        (
          lib.unique [
            stateRoot
            workRoot
          ]
        );
  };

  # Runs as the runners' user, so nothing it creates in the cache (the lock
  # files) ends up owned by root.
  pruneNixCache = pkgs.writeShellApplication {
    name = "github-runners-prune-nix-cache";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.util-linux
    ];
    text = ''
      cache=${lib.escapeShellArg cacheDir}
      days=${toString cfg.nixCache.pruneAfter}

      # gitv3 holds one bare repository per git input, beside a <name>.lock
      # that Nix flock()s while it fetches into it. A repository none of whose
      # top two levels (refs, FETCH_HEAD, objects/pack, …) changed in $days days
      # has not been fetched into since, and goes: a later job that needs it
      # clones it again. Holding its lock while deleting keeps this off a fetch
      # that is under way.
      if [ -d "$cache/gitv3" ]; then
        while IFS= read -r -d "" repo; do
          path=$cache/gitv3/$repo
          if [ -n "$(find "$path" -maxdepth 2 -mtime "-$days" -print -quit)" ] ||
            [ -n "$(find "$path.lock" -maxdepth 0 -mtime "-$days" -print -quit 2>/dev/null)" ]; then
            continue
          fi
          if flock -n "$path.lock" rm -rf -- "$path"; then
            rm -f -- "$path.lock"
            echo "Pruned gitv3/$repo: not fetched into for $days days."
          else
            echo "Skipped gitv3/$repo: in use."
          fi
        done < <(find "$cache/gitv3" -mindepth 1 -maxdepth 1 -type d -printf '%f\0')
        # Locks whose repository is gone.
        while IFS= read -r -d "" lock; do
          [ -e "''${lock%.lock}" ] || rm -f -- "$lock"
        done < <(find "$cache/gitv3" -mindepth 1 -maxdepth 1 -type f -name '*.lock' -mtime "+$days" -print0)
      fi

      # One SQLite database per flake evaluated, with its -wal and -shm; one
      # that nobody wrote to in $days days goes, all three files together (a
      # hit costs a re-evaluation at worst).
      if [ -d "$cache/eval-cache-v6" ]; then
        while IFS= read -r -d "" db; do
          if [ -z "$(find "$db" "$db-wal" "$db-shm" -maxdepth 0 -mtime "-$days" -print -quit 2>/dev/null)" ]; then
            rm -f -- "$db" "$db-wal" "$db-shm"
          fi
        done < <(find "$cache/eval-cache-v6" -mindepth 1 -maxdepth 1 -type f -name '*.sqlite' -printf '%p\0')
      fi
    '';
  };

  # ── Disk bounds ──────────────────────────────────────────────
  # What nixpkgs' runner leaves in a workDir is not bounded by anything: every
  # repository the runner has served keeps its checkout (with .git, and
  # .devenv / .frappe-nix state beside it) until the unit restarts, which
  # empties the lot. With a pool that takes any repository's jobs, each runner
  # ends up holding all of them.
  #
  # The sweep removes two things, both only while their runner has no job:
  #   - a checkout whose .git nothing has touched for `sweep.maxAge` days,
  #     whatever the disk looks like;
  #   - when the disk holding workRoot has less than `sweep.minFreePercent`
  #     free, the stalest checkouts of all runners, oldest first, until
  #     `sweep.targetFreePercent` is free or only the ones used in the last
  #     `sweep.protectHours` hours are left.
  # "Used" is the newest .git directory's mtime, not the checkout's own: that
  # changes whenever git writes the index (every checkout of a job), while the
  # directories above it stay as they were on the day they were created.
  #
  # A checkout is moved into the workDir's .sweep-trash while the gate lock is
  # held (a rename, so the lock is held for no time), and deleted after it is
  # let go of. Taking the lock exclusively also keeps this out of the way of a
  # collection, and the other way round; `flock -w` gives up on a collection
  # that has been holding it for two minutes and tries again next hour.
  #
  # The tool cache (XDG_CACHE_HOME) is emptied when it has been `resetAfter`
  # days since last time, and only with no job running anywhere: a cache that
  # grows with every version of every dependency has no better pruning rule
  # than "start again", which is also what a runner restart has always done to
  # it. It is emptied in place (the runners have this directory bind-mounted
  # into their sandboxes, so it must stay the same directory).
  #
  # SWEEP_* in the environment override the settings, for a run by hand.
  toolDir = cfg.toolCache.directory;
  sweepState = "/var/lib/github-runners-sweep";
  runnerEntries = lib.concatMapStringsSep " " (key: lib.escapeShellArg "${key} ${workDirOf key}") (
    lib.attrNames allRunners
  );

  sweepWorkspaces = pkgs.writeShellApplication {
    name = "github-runners-sweep";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnused
      pkgs.procps
      pkgs.util-linux
    ];
    text = ''
      work_root=${lib.escapeShellArg workRoot}
      tools=${lib.escapeShellArg (if toolDir == null then "" else toolDir)}
      state=''${STATE_DIRECTORY:-${sweepState}}
      max_age=$(( ''${SWEEP_MAX_AGE_DAYS:-${toString cfg.sweep.maxAge}} * 86400 ))
      protect=$(( ''${SWEEP_PROTECT_HOURS:-${toString cfg.sweep.protectHours}} * 3600 ))
      min_free=''${SWEEP_MIN_FREE_PERCENT:-${toString cfg.sweep.minFreePercent}}
      target_free=''${SWEEP_TARGET_FREE_PERCENT:-${toString cfg.sweep.targetFreePercent}}
      reset_days=''${SWEEP_TOOL_CACHE_DAYS:-${toString cfg.toolCache.resetAfter}}
      runners=(${runnerEntries})

      exec 9>${gateLock}

      free_percent() {
        local used
        used=$(df --output=pcent "$work_root" | tail -n 1 | tr -dc '0-9')
        echo $((100 - used))
      }

      last_used() {
        local newest
        newest=$(find "$1" -maxdepth 3 -name .git -prune -printf '%T@\n' 2>/dev/null | sort -rn | sed -n 1p || true)
        [ -n "$newest" ] || newest=$(stat -c %Y "$1")
        echo "''${newest%.*}"
      }

      # Every checkout, as "last used<TAB>runner<TAB>directory". Not the
      # hidden entries (the runner's own HOME) nor the _-prefixed ones
      # (_actions, _tool, _temp: the runner's own).
      candidates() {
        local entry key dir d
        for entry in "''${runners[@]}"; do
          key=''${entry%% *}
          dir=''${entry#* }
          [ -d "$dir" ] || continue
          while IFS= read -r -d "" d; do
            printf '%s\t%s\t%s\n' "$(last_used "$d")" "$key" "$d"
          done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name '_*' -print0)
        done
      }

      empty_trash() {
        local entry dir
        for entry in "''${runners[@]}"; do
          dir=''${entry#* }
          [ -d "$dir/.sweep-trash" ] || continue
          find "$dir/.sweep-trash" -mindepth 1 -maxdepth 1 -exec rm -rf --one-file-system -- {} +
        done
        sync -f "$work_root"
      }

      # Move one checkout out of its workDir if its runner has no job. The
      # lock is the one the jobs' started hooks take, so a job that starts
      # now waits for the rename, and finds the checkout gone.
      take() {
        local key=$1 dir=$2 trash
        flock -w 120 9 || return 1
        if [ -e ${gateJobs}/"$key" ]; then
          flock -u 9
          return 1
        fi
        trash=$(dirname "$dir")/.sweep-trash
        mkdir -p "$trash"
        mv -T -- "$dir" "$trash/$(basename "$dir").$$"
        flock -u 9
      }

      # With the lock held: is the machine free of jobs? Marks with no worker
      # behind them are a dead runner's.
      idle() {
        if ! pgrep -f 'Runner\.Worker' >/dev/null; then
          find ${gateJobs} -mindepth 1 -delete
          return 0
        fi
        [ -z "$(ls -A ${gateJobs})" ]
      }

      parse() {
        IFS=$'\t' read -r ts key dir <<<"$1"
        age=$(( now - ts ))
      }

      now=$(date +%s)
      empty_trash # what an interrupted run left

      mapfile -t found < <(candidates | sort -n)

      for line in "''${found[@]}"; do
        parse "$line"
        [ "$age" -gt "$max_age" ] || continue
        if take "$key" "$dir"; then
          echo "Swept $dir ($key): not used for $(( age / 86400 )) days."
        else
          echo "Kept $dir ($key): its runner has a job, or the gate is busy."
        fi
      done
      empty_trash

      if [ "$(free_percent)" -lt "$min_free" ]; then
        echo "Only $(free_percent)% of $work_root's disk is free (below $min_free%): sweeping the stalest checkouts."
        for line in "''${found[@]}"; do
          [ "$(free_percent)" -lt "$target_free" ] || break
          parse "$line"
          [ -d "$dir" ] || continue
          # Oldest first: everything after this is younger still.
          [ "$age" -gt "$protect" ] || break
          if take "$key" "$dir"; then
            empty_trash
            echo "Swept $dir ($key): unused for $(( age / 3600 )) hours, disk is low."
          fi
        done
        echo "$(free_percent)% of $work_root's disk is free."
      fi

      if [ -n "$tools" ] && [ -d "$tools" ]; then
        mkdir -p "$state"
        stamp=$state/tool-cache-reset
        find "$tools" -mindepth 1 -maxdepth 1 -name '.trash.*' -exec rm -rf --one-file-system -- {} +
        if [ ! -e "$stamp" ]; then
          touch "$stamp" # the clock starts now
        elif [ -n "$(find "$stamp" -mtime "+$reset_days" -print -quit)" ]; then
          if flock -w 120 9; then
            if idle; then
              trash=$tools/.trash.$$
              mkdir -p "$trash"
              find "$tools" -mindepth 1 -maxdepth 1 ! -name '.trash.*' -exec mv -t "$trash" -- {} +
              touch "$stamp"
              flock -u 9
              echo "Emptied $tools: it was more than $reset_days days since last time."
              rm -rf --one-file-system -- "$trash"
            else
              flock -u 9
              echo "$tools is due to be emptied, but a job is running: trying again later."
            fi
          fi
        fi
      fi
    '';
  };

  githubAppToken = import ../pkgs/github-app-token.nix { inherit pkgs; };

  # Where an App-registered runner's registration token is written, just
  # before nixpkgs' own ExecStartPre reads it. Root's only.
  registrationDir = "/run/github-runner-registration";
  registrationTokenOf = key: "${registrationDir}/${key}";

  # Repositories that have a hand-written runner are skipped in `repos`, so
  # listing every repository does not double up on those.
  covered = lib.filter (repo: repo != null) (lib.mapAttrsToList (_: r: r.repo) cfg.runners);

  # The repositories that get runners from `repos`, and how many each.
  served = lib.filter (repo: !(lib.elem repo covered)) (lib.attrNames cfg.repos);
  countOf = repo: cfg.repos.${repo};

  # What `repos` expands to: the same shape as an entry of `runners`. The key is
  # prefixed so a repository can never collide with a hand-written runner's name.
  # A repository's first runner is `repo-<name>` registered as `namePrefix`;
  # further ones add `-<n>`, so raising a count leaves the runner that already
  # exists exactly as it was.
  mkRepoRunner = repo: n: {
    name = if n == 1 then "repo-${repo}" else "repo-${repo}-${toString n}";
    value = {
      inherit repo;
      runnerName = if n == 1 then cfg.namePrefix else "${cfg.namePrefix}-${toString n}";
      extraLabels = [ ];
      tokenFile = null;
      runnerGroup = null;
    };
  };
  repoRunners = lib.listToAttrs (
    lib.concatMap (repo: map (mkRepoRunner repo) (lib.range 1 (countOf repo))) served
  );

  # `orgRunners`: organisation runners with the module-wide labels only, for
  # any repository's jobs. `org-<n>`, registered as `namePrefix-org-<n>`.
  orgKeys = map (n: "org-${toString n}") (lib.range 1 cfg.orgRunners);
  orgRunners = lib.listToAttrs (
    lib.imap1 (
      n: key:
      lib.nameValuePair key {
        repo = null;
        runnerName = "${cfg.namePrefix}-org-${toString n}";
        extraLabels = [ ];
        tokenFile = null;
        runnerGroup = null;
      }
    ) orgKeys
  );

  allRunners = repoRunners // orgRunners // cfg.runners;

  # An organisation runner with no token of its own registers through the App.
  viaApp = r: r.repo == null && r.tokenFile == null && cfg.githubApp != null;
  appRunners = lib.filterAttrs (_: viaApp) allRunners;

  mintRegistrationToken =
    key:
    pkgs.writeShellApplication {
      name = "github-runner-${key}-registration-token";
      runtimeInputs = [
        githubAppToken
        pkgs.coreutils
      ];
      text = ''
        out=${lib.escapeShellArg (registrationTokenOf key)}
        umask 077
        mkdir -p ${registrationDir}
        token=$(github-app-token \
          --api-url ${lib.escapeShellArg cfg.githubApp.apiUrl} \
          --app-id ${toString cfg.githubApp.appId} \
          --key-file ${lib.escapeShellArg cfg.githubApp.privateKeyFile} \
          --owner ${lib.escapeShellArg cfg.owner} \
          --permission organization_self_hosted_runners=write \
          --registration-token)
        tmp=$(mktemp "$out.XXXXXX")
        trap 'rm -f "$tmp"' EXIT
        # No trailing newline: nixpkgs passes the file's content to the runner as is.
        printf '%s' "$token" > "$tmp"
        mv -f "$tmp" "$out"
        trap - EXIT
      '';
    };

  mkRunner =
    key: r:
    {
      enable = true;
      extraLabels = lib.unique (r.extraLabels ++ cfg.extraLabels);
      inherit (cfg) extraPackages group user;
      name = r.runnerName;
      # Let a runner re-register under the same name after a config change,
      # instead of failing because the name is taken.
      replace = true;
      url =
        if r.repo == null then
          "https://github.com/${cfg.owner}"
        else
          "https://github.com/${cfg.owner}/${r.repo}";
      workDir = workDirOf key;
      package = runnerPackage;
    }
    # Nix reads NIX_CACHE_HOME ahead of XDG_CACHE_HOME and ~/.cache/nix, and
    # nothing else does, so NIX_CACHE_HOME moves only Nix's cache. The other
    # tools' caches follow XDG_CACHE_HOME to `toolCache` (or stay in the
    # workDir when that is null).
    // {
      extraEnvironment =
        lib.optionalAttrs (cacheDir != null) { NIX_CACHE_HOME = cacheDir; }
        // lib.optionalAttrs (toolDir != null) { XDG_CACHE_HOME = toolDir; }
        // lib.optionalAttrs cfg.gc.waitForJobs {
          ACTIONS_RUNNER_HOOK_JOB_STARTED = toString (jobStartedHook key);
          ACTIONS_RUNNER_HOOK_JOB_COMPLETED = toString (jobCompletedHook key);
        };
    }
    // lib.optionalAttrs (r.runnerGroup != null) { inherit (r) runnerGroup; }
    // (
      if viaApp r then
        {
          tokenFile = registrationTokenOf key;
          tokenType = "registration";
        }
      else
        {
          tokenFile = if r.tokenFile != null then r.tokenFile else cfg.tokenFile;
        }
    );

  # nixpkgs builds github-runner with node24 only (node20 is end-of-life and
  # gone from nixpkgs), but the runner still runs externals/node20 for its own
  # work, such as evaluating hashFiles() in a workflow expression, and fails
  # with "No such file or directory". ACTIONS_RUNNER_FORCED_INTERNAL_NODE_VERSION
  # cannot redirect it: the runner accepts only "node20" there. Point node20 at
  # node24 instead.
  runnerPackage = pkgs.github-runner.overrideAttrs (old: {
    postInstall = old.postInstall + ''
      ln -s ${pkgs.nodejs_24} $out/lib/externals/node20
    '';
  });

  # A runner registers with GitHub (a dotnet process, and an API call) the first
  # time it starts and whenever its config changes. Start the `repos` runners in
  # sequential batches so deploying a hundred of them is not a hundred
  # registrations at once on a small box. Ordering only: a runner that fails to
  # register does not hold back the next batch.
  # The extra runners of a repository come after every first runner, so adding
  # one shifts nobody who is already running into a different batch (which
  # would change their unit, and restart them mid-job).
  # The organisation runners come last, in order, for the same reason.
  firstKeys = map (repo: "repo-${repo}") served;
  repoKeys =
    lib.sort (a: b: a < b) firstKeys
    ++ lib.sort (a: b: a < b) (lib.filter (key: !(lib.elem key firstKeys)) (lib.attrNames repoRunners))
    ++ orgKeys;
  batchSize = cfg.startupBatchSize;
  staggered = lib.listToAttrs (
    lib.imap0 (
      i: key:
      let
        batch = i / batchSize;
      in
      lib.nameValuePair (unitOf key) {
        after = lib.optionals (batch > 0) (
          map (k: "${unitOf k}.service") (lib.sublist ((batch - 1) * batchSize) batchSize repoKeys)
        );
      }
    ) repoKeys
  );

  runnerOptions =
    { name, ... }:
    {
      options = {
        repo = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Name of the repository (under `owner`) this runner serves. Null, the
            default, registers it for the whole organisation instead, through
            `githubApp` unless it has a `tokenFile` of its own (a PAT that
            administers the organisation's runners).
          '';
          example = "bench_pequea";
        };
        runnerName = mkOption {
          type = types.str;
          default = "${cfg.namePrefix}-${name}";
          defaultText = lib.literalExpression ''"''${namePrefix}-<attribute name>"'';
          description = ''
            Name the runner registers under on GitHub. Must be unique among the
            repository's runners.
          '';
        };
        extraLabels = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Labels for this runner, ahead of the module-wide `extraLabels`.
            Workflows ask for them in `runs-on`, which is how one repository's
            jobs are kept off another's runners.
          '';
        };
        tokenFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            Token for this runner alone, e.g. a PAT scoped to one repository so
            that revoking it cannot take down any other runner. Defaults to the
            module-wide `tokenFile`, or for an organisation runner to
            `githubApp` when that is set.
          '';
        };
        runnerGroup = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Runner group an organisation runner joins (it must exist). Null is
            the organisation's Default group. A group restricted to some
            repositories is the way to keep the rest of the organisation's
            jobs off this runner altogether, where labels only steer them.
          '';
        };
      };
    };
in
{
  options.services.githubRepoRunners = {
    enable = lib.mkEnableOption "self-hosted GitHub Actions runners, one per repository";

    owner = mkOption {
      type = types.str;
      description = "GitHub user or organisation that owns the repositories.";
      example = "Avunu";
    };

    tokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        File holding a PAT that can administer the runners of every repository
        in use (fine-grained: "Administration" read and write on them; classic:
        `repo`). Each runner uses it to fetch its own registration token. See
        `services.github-runners.<name>.tokenFile`.
      '';
      example = "/run/agenix/github-runner-token";
    };

    githubApp = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            appId = mkOption {
              type = types.ints.positive;
              example = 123456;
              description = "The App's numeric App ID (not its client ID).";
            };
            privateKeyFile = mkOption {
              type = types.str;
              example = "/run/agenix/github-app-key";
              description = ''
                Runtime path of the App's PEM private key, readable by root (it
                is read before the runner drops to its user). A path string, so
                the key never enters the store.
              '';
            };
            apiUrl = mkOption {
              type = types.str;
              default = "https://api.github.com";
              description = "The GitHub REST API the tokens are minted from.";
            };
          };
        }
      );
      default = null;
      description = ''
        A GitHub App installed on `owner` with the organisation permission
        "Self-hosted runners" read and write. Organisation runners (`orgRunners`,
        and `runners` without a `repo`) register through it: a registration
        token minted from it just before every start, so no PAT is stored.
        Repository runners are unaffected and keep using `tokenFile`.
      '';
    };

    orgRunners = mkOption {
      type = types.ints.unsigned;
      default = 0;
      description = ''
        How many organisation runners to run with only the module-wide labels,
        for any repository's jobs (`runs-on: [self-hosted, <extraLabels>]`).
        Unlike `repos` they are one pool: an idle one takes the next job from
        whichever repository has one, so the count is how many jobs the host
        runs at once, not a reservation per repository. Each is a resident
        process, so it is a memory budget too.

        Registered through `githubApp`, or `tokenFile` without one (a PAT that
        administers the organisation's runners). On a public repository a pull
        request from a fork can run its workflow here unless the workflow
        sends forks elsewhere.
      '';
    };

    repos = mkOption {
      type = types.coercedTo (types.listOf types.str) (names: lib.genAttrs names (_: 1)) (
        types.attrsOf types.ints.positive
      );
      default = { };
      description = ''
        Repositories, each with the number of runners it gets, built with the
        module-wide settings. A list of names alone gives each one runner. A
        repository that also has an entry in `runners` is left to that entry.

        A runner takes one job at a time, so a repository's count is how many of
        its jobs can run at once: a workflow that fans out into twenty jobs
        waits on twenty runners. Every runner is a resident process whether or
        not it has work, so this is a memory budget; keep the count at 1 except
        for the busy few.

        GitHub also recommends self-hosted runners for private repositories only:
        on a public one, a pull request from a fork can run its own workflow on
        the runner.
      '';
      example = {
        quiet-repo = 1;
        busy-repo = 8;
      };
    };

    runners = mkOption {
      type = types.attrsOf (types.submodule runnerOptions);
      default = { };
      description = ''
        Runners that need more than the defaults: their own token, labels or
        name, or several for one repository. The attribute name is the systemd
        unit's (`github-runner-<name>`) and the workDir's, so renaming one
        registers it afresh.
      '';
    };

    extraLabels = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Labels added to every runner, besides GitHub's own `self-hosted`, OS and architecture.";
      example = [ "nixos" ];
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = hostedImagePackages ++ lib.optional cfg.dockerSocket pkgs.docker-client;
      defaultText = lib.literalExpression "<what GitHub's hosted Ubuntu image has> ++ optional dockerSocket docker-client";
      description = ''
        Packages on the `PATH` of every runner's workflows. The default is what
        a workflow written for GitHub's hosted Ubuntu image commonly calls (git,
        tar, zstd, curl, jq, gh, make, node, python, …), plus the Docker CLI
        when `dockerSocket` is on. Setting this replaces all of it.
      '';
    };

    dockerSocket = mkOption {
      type = types.bool;
      default = config.virtualisation.podman.dockerSocket.enable;
      defaultText = lib.literalExpression "config.virtualisation.podman.dockerSocket.enable";
      description = ''
        Let the workflows use Docker: the runners' user joins the `podman`
        group, which owns podman's rootful socket (root:podman 0660, symlinked
        at /run/docker.sock), and the Docker CLI (with buildx and compose) is
        on their `PATH`.

        Anyone who can run a job here can therefore start a privileged
        container, which is to say is root on this machine. Turn it off to take
        that back.
      '';
    };

    namePrefix = mkOption {
      type = types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Name that a runner made from `repos` registers under.";
    };

    user = mkOption {
      type = types.str;
      default = "github-runner";
      description = "User the runners run as. Declared here unless `createUser` is off.";
    };

    group = mkOption {
      type = types.str;
      default = "github-runner";
      description = "Group the runners run as. Declared here unless `createUser` is off.";
    };

    createUser = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Declare `user` and `group`: a system user whose home is `workRoot`.
        (The runners themselves run with HOME set to their own workDir, which
        nixpkgs empties on every start; what they share is `nixCache`.)

        Turn it off to bring your own, which then needs the `podman` group too
        if `dockerSocket` is on. Either way `user` is added to
        nix.settings.trusted-users.
      '';
    };

    workRoot = mkOption {
      type = types.path;
      default = "/var/lib/github-runner";
      description = ''
        Directory holding each runner's workDir. Must be real disk: leaving a
        workDir unset puts it in the systemd RuntimeDirectory, which is tmpfs, and
        a checkout with submodules is several GB of RAM.
      '';
    };

    startupBatchSize = mkOption {
      type = types.ints.positive;
      default = 8;
      description = "How many of the `repos` runners start (and register) at a time.";
    };

    nixCache = {
      directory = mkOption {
        type = types.nullOr types.str;
        default = "/var/cache/github-runner-nix";
        description = ''
          Nix's fetcher cache (git inputs in gitv3, tarballs, the evaluation
          cache), shared by every runner through NIX_CACHE_HOME. Nix locks
          each git repository in it while it fetches, so concurrent jobs can
          share it. One copy of each input, fetched incrementally, instead of
          one per runner that nixpkgs throws away whenever the runner
          restarts.

          Null leaves Nix on ~/.cache/nix, which for a runner is in its workDir.
        '';
      };

      pruneAfter = mkOption {
        type = types.ints.positive;
        default = 14;
        description = ''
          Days after which a git repository nothing has fetched into, or an
          evaluation cache nothing has written to, is pruned from
          `nixCache.directory`, weekly. A job that needs one again re-fetches
          it. tarball-cache-v2 (GitHub inputs, nixpkgs) is one repository
          for every tarball and is left alone.
        '';
      };
    };

    toolCache = {
      directory = mkOption {
        type = types.nullOr types.str;
        default = "/var/cache/github-runner-tools";
        description = ''
          Where the runners' tools keep their caches (uv, yarn, npm, prek, pip…):
          XDG_CACHE_HOME, shared by every runner. nixpkgs sets each runner's HOME
          to its workDir, so without this ~/.cache is one full copy per runner —
          16 GB each on nix-runner-elitedesk, the same bytes twenty times over.
          uv, pip and yarn lock what they write, so concurrent jobs can share it.

          Keep it on the filesystem `workRoot` is on: uv and pnpm hard-link from
          their cache into the environments they build, and fall back to copying
          across filesystems. Nix's own cache is `nixCache`, which this does not
          move (Nix reads NIX_CACHE_HOME first).

          Null leaves each runner's tools on ~/.cache in its workDir.
        '';
      };

      resetAfter = mkOption {
        type = types.ints.positive;
        default = 30;
        description = ''
          Days between emptying the tool cache, which only happens while no job
          is running on any runner. Nothing prunes a cache by age safely (an entry
          that is read is not written, and a pointer to a deleted entry is an
          error in some tools), so it is emptied whole and refills as jobs ask.
          That is what a runner restart already did to every runner's own copy.
        '';
      };
    };

    sweep = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Remove the checkouts the runners no longer use from their workDirs
          (see the comment on `sweepWorkspaces` in this module). Needs
          `gc.waitForJobs`: the sweep takes the lock and the job marks that
          option sets up, which is how it knows a checkout is not in use.
        '';
      };

      maxAge = mkOption {
        type = types.ints.positive;
        default = 7;
        description = ''
          Days a checkout may go unused before it is removed, whatever the disk
          looks like. A job that needs it again clones it again.
        '';
      };

      protectHours = mkOption {
        type = types.ints.unsigned;
        default = 6;
        description = "A checkout used within this many hours is never removed for lack of space.";
      };

      minFreePercent = mkOption {
        type = types.ints.between 0 100;
        default = 25;
        description = ''
          When less than this much of the disk holding `workRoot` is free, the
          stalest checkouts are removed, oldest first, until `targetFreePercent`
          is free. Checked hourly. 0 leaves only `maxAge`.
        '';
      };

      targetFreePercent = mkOption {
        type = types.ints.between 0 100;
        default = 35;
        description = "Free space the sweep stops at once it has started on `minFreePercent`.";
      };
    };

    gc = {
      waitForJobs = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Collect Nix garbage only while no job is running, and turn off
          determinate-nixd's own disk-pressure collector, which cannot be made
          to wait. A collection during a job deletes the paths its later steps
          need.
        '';
      };

      idleWait = mkOption {
        type = types.ints.unsigned;
        default = 60;
        description = ''
          Minutes nix-gc looks for a moment with no job running, without
          getting in anyone's way, before it starts holding new jobs back.
        '';
      };

      drainWait = mkOption {
        type = types.ints.positive;
        default = 180;
        description = ''
          Minutes nix-gc then holds new jobs back while the running ones
          finish. If they have not, it gives up, nix-gc.service fails, and new
          jobs carry on. Longer than the longest job you expect, or it can never
          succeed on a busy machine.
        '';
      };

      minFreePercent = mkOption {
        type = types.ints.between 0 100;
        default = 15;
        description = ''
          Run nix-gc when less than this much of /nix/store's filesystem is
          free, checked hourly, and at most every 6 hours. This takes the place
          of determinate-nixd's collector. 0 leaves only `nix.gc.dates`.
        '';
      };
    };

    removeStaleDirs = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Delete what runners that no longer exist left in `workRoot` and in
        /var/lib/github-runner: their workDirs (checkouts, `result` links that
        are GC roots) and state directories. Runs at boot and on every switch
        that adds or removes a runner. These directories belong to the runners:
        any non-hidden directory in them that is not a current runner's
        (any services.github-runners entry, not only this module's) is removed.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          lib.all (r: r.tokenFile != null || viaApp r) (lib.attrValues allRunners) || cfg.tokenFile != null;
        message = "services.githubRepoRunners: set `tokenFile`, or one on every runner that has none (an organisation runner can register through `githubApp` instead).";
      }
      {
        assertion = cfg.githubApp == null || !lib.hasPrefix builtins.storeDir cfg.githubApp.privateKeyFile;
        message = "services.githubRepoRunners.githubApp.privateKeyFile is in the Nix store, which every user can read. Point it at a runtime secret (an agenix path).";
      }

      {
        # A repository called "foo-2" would otherwise share a key with the second runner of "foo".
        assertion =
          lib.length (lib.attrNames repoRunners) == lib.foldl' (n: repo: n + countOf repo) 0 served;
        message = "services.githubRepoRunners: two runners ended up with the same name; a repository name probably ends in \"-<number>\".";
      }
      {
        assertion = cfg.dockerSocket -> config.virtualisation.podman.dockerSocket.enable;
        message = "services.githubRepoRunners.dockerSocket needs virtualisation.podman.dockerSocket.enable, which is what provides the socket.";
      }
      {
        assertion = cfg.sweep.enable -> cfg.gc.waitForJobs;
        message = "services.githubRepoRunners.sweep needs gc.waitForJobs: the sweep knows a checkout is idle from the job marks and the lock that option sets up. Turn one off or the other on.";
      }
      {
        assertion = cfg.sweep.targetFreePercent >= cfg.sweep.minFreePercent;
        message = "services.githubRepoRunners.sweep.targetFreePercent is below minFreePercent: the sweep would stop before it started.";
      }
    ];

    users.groups.${cfg.group} = lib.mkIf cfg.createUser { };
    users.users.${cfg.user} = lib.mkIf cfg.createUser {
      createHome = true;
      description = "GitHub Actions self-hosted runners";
      inherit (cfg) group;
      home = cfg.workRoot;
      isSystemUser = true;
      extraGroups = lib.optional cfg.dockerSocket "podman";
    };

    # A trusted user, or the workflows' `access-tokens` (needed to fetch
    # private submodules) are silently ignored.
    nix.settings.trusted-users = [ cfg.user ];

    # nix-ld itself is normally enabled by devHost. nix-ld falls back to
    # /run/current-system/sw/share/nix-ld when NIX_LD is unset, so the runner
    # units need no extra environment.
    programs.nix-ld = {
      enable = lib.mkDefault true;
      libraries = nixLdLibraries;
    };

    services.github-runners = lib.mapAttrs mkRunner allRunners;

    systemd.services = lib.mkMerge [
      staggered
      # The registration token, minted as root ("+": outside the unit's
      # sandbox, which is also what lets it read the App's key) ahead of
      # nixpkgs' own steps, which read it from tokenFile and register with it.
      (lib.mapAttrs' (
        key: _:
        lib.nameValuePair (unitOf key) {
          serviceConfig.ExecStartPre = lib.mkBefore [ "+${lib.getExe (mintRegistrationToken key)}" ];
        }
      ) appRunners)
      # A runner that is starting is running no job, whatever it left behind.
      (lib.mkIf cfg.gc.waitForJobs (
        lib.mapAttrs' (
          key: _:
          lib.nameValuePair (unitOf key) {
            serviceConfig.ExecStartPre = lib.mkBefore [ "+${pkgs.coreutils}/bin/rm -f ${gateJobs}/${key}" ];
            serviceConfig.ReadWritePaths = [ gateDir ];
          }
        ) allRunners
      ))
      (lib.mkIf cfg.gc.waitForJobs {
        nix-gc.script = lib.mkForce "exec ${lib.getExe gatedCollection}";
        github-runners-gc-under-pressure = lib.mkIf (cfg.gc.minFreePercent > 0) {
          description = "Collect Nix garbage if the store's disk is nearly full";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe collectUnderPressure;
          };
        };
      })
      # nixpkgs' unconfigure step empties the workDir on every start, and a
      # runner whose jobs build benches leaves gigabytes there (nix store
      # copies, node_modules): systemd's default 90 s start timeout kills it
      # mid-delete and the runner never comes up.
      (lib.mapAttrs' (
        key: _: lib.nameValuePair (unitOf key) { serviceConfig.TimeoutStartSec = lib.mkDefault "20min"; }
      ) allRunners)
      # The runners' sandbox (ProtectSystem = strict) makes everything but
      # their workDir read-only.
      (lib.mkIf (cacheDir != null) (
        lib.mapAttrs' (
          key: _: lib.nameValuePair (unitOf key) { serviceConfig.ReadWritePaths = [ cacheDir ]; }
        ) allRunners
      ))
      (lib.mkIf (toolDir != null) (
        lib.mapAttrs' (
          key: _: lib.nameValuePair (unitOf key) { serviceConfig.ReadWritePaths = [ toolDir ]; }
        ) allRunners
      ))
      (lib.mkIf cfg.sweep.enable {
        github-runners-sweep = {
          description = "Remove the runners' unused checkouts, and empty their tool cache now and then";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe sweepWorkspaces;
            StateDirectory = "github-runners-sweep";
            Nice = 19;
            IOSchedulingClass = "idle";
            # Deleting a few tens of GB of small files is minutes, and a first
            # sweep of a neglected disk is longer.
            TimeoutStartSec = "6h";
          };
        };
      })
      (lib.mkIf cfg.removeStaleDirs {
        # Type = exec with RemainAfterExit: boot and the switch do not wait on
        # a large delete, and a switch that changes the set of runners (and
        # so the script) restarts it.
        github-runners-remove-stale-dirs = {
          description = "Remove the directories of GitHub runners that no longer exist";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "exec";
            RemainAfterExit = true;
            ExecStart = lib.getExe removeStaleDirs;
            Nice = 19;
            IOSchedulingClass = "idle";
          };
        };
      })
      (lib.mkIf (cacheDir != null) {
        github-runners-prune-nix-cache = {
          description = "Prune the GitHub runners' shared Nix cache";
          serviceConfig = {
            Type = "oneshot";
            User = cfg.user;
            Group = cfg.group;
            ExecStart = lib.getExe pruneNixCache;
            Nice = 19;
            IOSchedulingClass = "idle";
          };
        };
      })
    ];

    systemd.timers.github-runners-prune-nix-cache = lib.mkIf (cacheDir != null) {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    systemd.timers.github-runners-sweep = lib.mkIf cfg.sweep.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30min";
        OnUnitActiveSec = "1h";
      };
    };

    systemd.timers.github-runners-gc-under-pressure =
      lib.mkIf (cfg.gc.waitForJobs && cfg.gc.minFreePercent > 0)
        {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "15min";
            OnUnitActiveSec = "1h";
          };
        };

    # determinate-nixd collects on its own schedule when a disk fills up, which
    # no unit can be ordered against. Written whole because the determinate
    # module's edgeCacheSubstituters writes this file too, and that module is
    # not a given here: this module can be imported without devHost.
    environment.etc."determinate/config.json" = lib.mkIf cfg.gc.waitForJobs {
      text = lib.mkForce (
        builtins.toJSON (
          {
            garbageCollector.strategy = "disabled";
          }
          // lib.optionalAttrs ((config.determinate.edgeCacheSubstituters or null) != null) {
            inherit (config.determinate) edgeCacheSubstituters;
          }
        )
      );
    };

    # The workDirs are created here, rather than by systemd's RuntimeDirectory,
    # because they have to survive between jobs and across restarts.
    systemd.tmpfiles.rules = [
      "d ${cfg.workRoot} 0750 ${cfg.user} ${cfg.group} -"
    ]
    ++ lib.optional (cacheDir != null) "d ${cacheDir} 0750 ${cfg.user} ${cfg.group} -"
    ++ lib.optional (toolDir != null) "d ${toolDir} 0750 ${cfg.user} ${cfg.group} -"
    ++ lib.optionals cfg.gc.waitForJobs [
      "d ${gateDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${gateJobs} 0750 ${cfg.user} ${cfg.group} -"
      "f ${gateLock} 0640 ${cfg.user} ${cfg.group} -"
    ]
    ++ lib.optional (appRunners != { }) "d ${registrationDir} 0700 root root -"
    ++ lib.mapAttrsToList (key: _: "d ${workDirOf key} 0750 ${cfg.user} ${cfg.group} -") allRunners;
  };
}
