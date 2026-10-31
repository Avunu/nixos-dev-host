# devHost.githubApp.reader: the GitHub token nix and git fetch with, minted
# from a GitHub App instead of stored. (The writer half is flakeAutoUpdate's,
# in flake-auto-update.nix; the options and their reasoning are in
# options.nix.)
#
# An installation token lasts an hour, so a root service mints one at boot and
# every refreshInterval after, and writes it where githubTokenFile points.
# Everything that read the stored token reads this one the same way:
#
#   - nixos-install-helper renders githubTokenFile into its root-only
#     nix.conf include and git credential helper. It does that at activation
#     and from its own unit, so that unit runs again after every refresh
#     (OnSuccess below), or root's copy would be an hour old by the next one.
#   - The group reads the file itself: nix.conf includes it, and the git
#     credential helper reads it, so a member's nix and git (the runners'
#     jobs fetching a private `git+https://` input, say) get the token too.
#     A user outside the group gets an unreadable include, which nix skips,
#     and a helper that answers nothing.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  app = config.devHost.githubApp;
  cfg = app.reader;

  githubAppToken = import ../pkgs/github-app-token.nix { inherit pkgs; };

  refresh = pkgs.writeShellApplication {
    name = "github-app-reader-token";
    runtimeInputs = [
      githubAppToken
      pkgs.coreutils
    ];
    text = ''
      out=${escapeShellArg cfg.tokenFile}
      dir=$(dirname "$out")
      # Traversable, or the group could not reach the file.
      [ -d "$dir" ] || install -d -m 0755 "$dir"
      umask 077

      token=$(github-app-token \
        --api-url ${escapeShellArg app.apiUrl} \
        --app-id ${toString cfg.appId} \
        --key-file ${escapeShellArg cfg.privateKeyFile} \
        --owner ${escapeShellArg cfg.owner} \
        ${
          concatMapStringsSep " " (r: "--repository ${escapeShellArg r}") (
            if cfg.repositories == null then [ ] else cfg.repositories
          )
        } \
        ${
          concatStringsSep " " (
            mapAttrsToList (name: level: "--permission ${escapeShellArg "${name}=${level}"}") cfg.permissions
          )
        })

      # Written beside the old one and renamed over it, so a reader never sees
      # half a file; the group and mode are set before it is visible.
      tmp=$(mktemp "$out.XXXXXX")
      trap 'rm -f "$tmp"' EXIT
      printf 'access-tokens = github.com=%s\n' "$token" > "$tmp"
      chgrp ${escapeShellArg cfg.group} "$tmp"
      chmod 0440 "$tmp"
      mv -f "$tmp" "$out"
      trap - EXIT
      echo "github-app-reader-token: refreshed $out"
    '';
  };

  gitCredentialHelper = pkgs.writeShellScript "git-credential-github-app" ''
    [ "''${1:-}" = get ] || exit 0
    ${pkgs.coreutils}/bin/cat >/dev/null
    [ -r ${escapeShellArg cfg.tokenFile} ] || exit 0
    token=$(${pkgs.gnused}/bin/sed -n 's/.*github\.com=\([^[:space:]]*\).*/\1/p' ${escapeShellArg cfg.tokenFile})
    [ -n "$token" ] || exit 0
    printf 'username=x-access-token\npassword=%s\n' "$token"
  '';

  # What reads the token unattended, so it waits for the first one at boot.
  # nix-daemon is not among them: nix reads the include on every invocation,
  # and holding the daemon back until GitHub answers would hold back the box.
  # Whether nixos-install-helper is rendering this token (githubTokenFile was
  # not forced elsewhere), and so has a unit to run again after each refresh.
  rendered = config.devHost.githubTokenFile == cfg.tokenFile;

  consumers = [
    "system-upgrade.service"
  ]
  ++ map (name: "flake-auto-update-${name}.service") (
    attrNames config.devHost.flakeAutoUpdate.repositories
  )
  ++ map (name: "github-runner-${name}.service") (attrNames config.services.github-runners);
in
{
  config = mkMerge [
    (mkIf (cfg != null) {
      assertions = [
        {
          assertion = !hasPrefix builtins.storeDir cfg.privateKeyFile;
          message = "devHost.githubApp.reader.privateKeyFile is in the Nix store, which every user can read. Point it at a runtime secret (an agenix path).";
        }
      ];

      users.groups.${cfg.group} = { };

      # Over lib.mkHost's secrets/github-token.age (a plain definition), under
      # a host's mkForce.
      devHost.githubTokenFile = mkOverride 90 cfg.tokenFile;

      nix.extraOptions = ''
        !include ${cfg.tokenFile}
      '';

      programs.git.config.credential."https://github.com".helper = mkForce "${gitCredentialHelper}";

      systemd.services.github-app-reader-token = {
        description = "Mint the GitHub App installation token nix and git read with";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [
          "network-online.target"
          # The private key is an agenix secret, where agenix decrypts as a unit.
          "agenix-install-secrets.service"
        ];
        before = consumers ++ optional rendered "install-helper-access-tokens.service";
        # Root's copy of the token (nixos-install-helper's nix.conf include)
        # follows every refresh.
        onSuccess = optional rendered "install-helper-access-tokens.service";
        # GitHub unreachable at boot: try again, rather than wait for the timer.
        startLimitIntervalSec = 0;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = getExe refresh;
          Restart = "on-failure";
          RestartSec = "30s";
          TimeoutStartSec = "5min";
          PrivateTmp = true;
          ProtectHome = true;
          NoNewPrivileges = true;
        };
      };

      systemd.services.install-helper-access-tokens = mkIf rendered {
        after = [ "github-app-reader-token.service" ];
      };

      # nixos-install-helper renders root's copy into /run/install-helper,
      # which it creates 0700. nix stats an include before reading it, and a
      # stat that fails with EACCES (rather than ENOENT) aborts the whole of
      # /etc/nix/nix.conf for every user but root, the group's include with
      # it. Traversable, the stat succeeds, the unreadable file is skipped, and
      # the rest of nix.conf applies. The file itself stays 0400 root.
      systemd.tmpfiles.rules = optionals rendered [
        "d /run/install-helper 0711 root root -"
        "z /run/install-helper 0711 root root -"
      ];

      systemd.timers.github-app-reader-token = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = cfg.refreshInterval;
          AccuracySec = "1min";
          Unit = "github-app-reader-token.service";
        };
      };
    })

    (mkIf (app.writer != null) {
      assertions = [
        {
          assertion = !hasPrefix builtins.storeDir app.writer.privateKeyFile;
          message = "devHost.githubApp.writer.privateKeyFile is in the Nix store, which every user can read. Point it at a runtime secret (an agenix path).";
        }
      ];
    })
  ];
}
