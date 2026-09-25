# The host's secrets identity, and the GitHub access that hangs off it.
#
# agenix decrypts with a pre-provisioned identity at /etc/agenix/key, not with
# the SSH host key. Every install generates a fresh SSH host key, so secrets
# encrypted to it have to be re-keyed on every redeploy. A key that is carried
# *into* the install instead — the host repo keeps it as secrets/key.age,
# agenix-shell decrypts it into $agenix__key, and nixos-install-helper's
# agenix-key asset writes it here (lib/mk-host.nix) — survives any number of
# them.
#
# A function of the agenix flake rather than a module that reads `inputs`:
# the /etc/nixos flake nixos-install-helper seeds passes its own `inputs` as a
# specialArg, which shadows this flake's `_module.args.inputs`, and that one has
# no agenix in it.
{ agenix }:
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.devHost;
  keyPath = import ../lib/agenix-key-path.nix;
  tokenFile = cfg.githubTokenFile;

  # git's half of githubTokenFile. A credential helper rather than the obvious
  # `[include]` of a generated url.insteadOf file: git dies outright ("unable to
  # access … Permission denied") on an include it cannot read, which would break
  # git for every user outside the token's group. A helper that cannot read the
  # file just answers nothing, and git carries on as if it were not configured.
  githubCredentialHelper = pkgs.writeShellScript "git-credential-github-token" ''
    [ "''${1:-}" = get ] || exit 0
    ${pkgs.coreutils}/bin/cat >/dev/null
    [ -r ${escapeShellArg tokenFile} ] || exit 0
    token=$(${pkgs.gnused}/bin/sed -n 's/.*github\.com=\([^[:space:]]*\).*/\1/p' ${escapeShellArg tokenFile})
    [ -n "$token" ] || exit 0
    printf 'username=x-access-token\npassword=%s\n' "$token"
  '';
in
{
  imports = [ agenix.nixosModules.default ];

  config = mkMerge [
    {
      # At normal priority, so it replaces agenix's default (the SSH host keys)
      # but still merges with any other module's list.
      age.identityPaths = [ keyPath ];

      # The installers write the key 0400, but a hand-copied one arrives with
      # whatever mode it had; this is the one file on the box that unlocks
      # every other secret.
      systemd.tmpfiles.rules = [
        "z ${dirOf keyPath} 0700 root root -"
        "z ${keyPath} 0400 root root -"
      ];

      # `agenix -d secrets/foo.age -i ${keyPath}` on the box itself.
      environment.systemPackages = [ agenix.packages.${pkgs.stdenv.hostPlatform.system}.default ];
    }

    (mkIf (tokenFile != null) {
      # `!` — no error while the secret is absent (a test VM, first activation).
      nix.extraOptions = ''
        !include ${tokenFile}
      '';
      programs.git.config.credential."https://github.com".helper = "${githubCredentialHelper}";
    })
  ];
}
