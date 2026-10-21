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
# All runners share one user (so they share one Nix git cache) but each gets
# its own workDir, so two concurrent jobs cannot collide over one checkout.
#
# Not part of nixosModules.devHost: a host opts in by importing
# nixos-dev-host.nixosModules.githubRepoRunners. What the host still declares
# itself: the user and group the runners run as (`user`, `group`; the user must
# be in nix.settings.trusted-users, or the workflows' `access-tokens` are
# silently ignored) and the token's agenix secret, owned by that user.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.githubRepoRunners;
  inherit (lib) mkOption types;

  workDirOf = key: "${cfg.workRoot}/work-${key}";
  unitOf = key: "github-runner-${key}";

  # Repositories that have a hand-written runner are skipped in `repos`, so
  # listing every repository does not double up on those.
  covered = lib.mapAttrsToList (_: r: r.repo) cfg.runners;

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
    };
  };
  repoRunners = lib.listToAttrs (
    lib.concatMap (repo: map (mkRepoRunner repo) (lib.range 1 (countOf repo))) served
  );

  allRunners = repoRunners // cfg.runners;

  mkRunner = key: r: {
    enable = true;
    extraLabels = lib.unique (r.extraLabels ++ cfg.extraLabels);
    inherit (cfg) extraPackages group user;
    name = r.runnerName;
    # Let a runner re-register under the same name after a config change,
    # instead of failing because the name is taken.
    replace = true;
    tokenFile = if r.tokenFile != null then r.tokenFile else cfg.tokenFile;
    url = "https://github.com/${cfg.owner}/${r.repo}";
    workDir = workDirOf key;
  };

  # A runner registers with GitHub (a dotnet process, and an API call) the first
  # time it starts and whenever its config changes. Start the `repos` runners in
  # sequential batches so deploying a hundred of them is not a hundred
  # registrations at once on a small box. Ordering only: a runner that fails to
  # register does not hold back the next batch.
  # The extra runners of a repository come after every first runner, so adding
  # one shifts nobody who is already running into a different batch (which
  # would change their unit, and restart them mid-job).
  firstKeys = map (repo: "repo-${repo}") served;
  repoKeys =
    lib.sort (a: b: a < b) firstKeys
    ++ lib.sort (a: b: a < b) (lib.filter (key: !(lib.elem key firstKeys)) (lib.attrNames repoRunners));
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
          type = types.str;
          description = "Name of the repository (under `owner`) this runner serves.";
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
            module-wide `tokenFile`.
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
      # actions/checkout needs git; actions/cache shells out to tar/zstd/gzip.
      default = with pkgs; [
        git
        gnutar
        gzip
        zstd
      ];
      defaultText = lib.literalExpression "with pkgs; [ git gnutar gzip zstd ]";
      description = "Packages on the `PATH` of every runner's workflows.";
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
      description = "User the runners run as. Declared by the host, not here.";
    };

    group = mkOption {
      type = types.str;
      default = "github-runner";
      description = "Group the runners run as. Declared by the host, not here.";
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
        assertion = lib.all (r: r.tokenFile != null) (lib.attrValues allRunners) || cfg.tokenFile != null;
        message = "services.githubRepoRunners: set `tokenFile`, or one on every runner that has none.";
      }
      {
        # A repository called "foo-2" would otherwise share a key with the second runner of "foo".
        assertion =
          lib.length (lib.attrNames repoRunners) == lib.foldl' (n: repo: n + countOf repo) 0 served;
        message = "services.githubRepoRunners: two runners ended up with the same name; a repository name probably ends in \"-<number>\".";
      }
    ];

    services.github-runners = lib.mapAttrs mkRunner allRunners;

    systemd.services = staggered;

    # The workDirs are created here, rather than by systemd's RuntimeDirectory,
    # because they have to survive between jobs and across restarts.
    systemd.tmpfiles.rules = [
      "d ${cfg.workRoot} 0750 ${cfg.user} ${cfg.group} -"
    ]
    ++ lib.mapAttrsToList (key: _: "d ${workDirOf key} 0750 ${cfg.user} ${cfg.group} -") allRunners;
  };
}
