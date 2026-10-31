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
# All runners share one user (so they share one Nix git cache) but each gets
# its own workDir, so two concurrent jobs cannot collide over one checkout.
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
        Home is what makes sharing one user worth doing, since Nix's git cache
        (~/.cache/nix/gitv3) persists there between jobs and a submodule fetch
        is incremental.

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
    ];

    # The workDirs are created here, rather than by systemd's RuntimeDirectory,
    # because they have to survive between jobs and across restarts.
    systemd.tmpfiles.rules = [
      "d ${cfg.workRoot} 0750 ${cfg.user} ${cfg.group} -"
    ]
    ++ lib.optional (appRunners != { }) "d ${registrationDir} 0700 root root -"
    ++ lib.mapAttrsToList (key: _: "d ${workDirOf key} 0750 ${cfg.user} ${cfg.group} -") allRunners;
  };
}
