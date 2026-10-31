# devHost.githubApp and the runners' App registration, against a fake GitHub
# API (github-api-stub.py) on the machine itself. The App keys are generated at
# boot, so nothing secret is in the store, and the stub verifies the JWTs with
# them.
#
# What it checks:
#   - the reader's token: minted narrowed, written 0440 root:github-token in
#     the access-tokens format, refreshed, and followed by
#     nixos-install-helper's root-only copy;
#   - a member of github-token gets it from nix.conf and from git's credential
#     helper, a non-member gets neither;
#   - flakeAutoUpdate with the writer: a token narrowed to the one repository,
#     and a push made with it (to a local bare repository standing in for
#     github.com);
#   - an organisation runner's registration token, minted with a token
#     narrowed to organization_self_hosted_runners;
#   - no installation token in the journal.
{ inputs }:
{ lib, ... }:
let
  readerId = 5545003;
  writerId = 5544044;
  runnerAppId = 1111;
  api = "http://127.0.0.1:8099";
  keys = "/run/test-app-keys";
in
{
  name = "github-app";

  nodes.machine =
    { config, pkgs, ... }:
    {
      imports = [
        ../modules/options.nix
        ../modules/github-app.nix
        ../modules/flake-auto-update.nix
        ../modules/github-repo-runners.nix
        (import ../modules/secrets.nix { inherit (inputs) agenix nixos-install-helper; })
      ];

      virtualisation.memorySize = 2048;
      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];
      programs.git.enable = true;

      users.users.alice = {
        isNormalUser = true;
        extraGroups = [ "github-token" ];
      };
      users.users.bob.isNormalUser = true;

      devHost.githubApp = {
        apiUrl = api;
        reader = {
          appId = readerId;
          privateKeyFile = "${keys}/reader.pem";
        };
        writer = {
          appId = writerId;
          privateKeyFile = "${keys}/writer.pem";
        };
      };

      # https://github.com/Avunu/<name> is a bare repository on this machine.
      programs.git.config.url."file:///srv/git/".insteadOf = "https://github.com/Avunu/";
      devHost.flakeAutoUpdate.repositories.example.url = "https://github.com/Avunu/example.git";
      # Started by the test, not the timer.
      systemd.timers.flake-auto-update-example.enable = false;

      services.githubRepoRunners = {
        enable = true;
        owner = "Avunu";
        githubApp = {
          appId = runnerAppId;
          privateKeyFile = "${keys}/runner.pem";
          apiUrl = api;
        };
        runners.bench.extraLabels = [ "bench" ];
        dockerSocket = false;
      };
      # Registration itself needs github.com; only the token is under test.
      systemd.services.github-runner-bench.wantedBy = lib.mkForce [ ];

      systemd.services.test-app-keys = {
        wantedBy = [ "multi-user.target" ];
        before = [ "github-app-reader-token.service" ];
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
        path = [ pkgs.openssl ];
        script = ''
          install -d -m 0700 ${keys}
          for app in reader writer runner; do
            openssl genrsa -traditional -out ${keys}/$app.pem 2048
          done
          chmod 0400 ${keys}/*.pem
        '';
      };

      systemd.services.github-api-stub = {
        wantedBy = [ "multi-user.target" ];
        after = [ "test-app-keys.service" ];
        requires = [ "test-app-keys.service" ];
        before = [ "github-app-reader-token.service" ];
        serviceConfig.ExecStart =
          let
            python = pkgs.python3.withPackages (ps: [
              ps.pyjwt
              ps.cryptography
            ]);
          in
          lib.escapeShellArgs [
            "${python}/bin/python3"
            "${./github-api-stub.py}"
            "8099"
            "/run/github-api-stub.log"
            "${toString readerId}=${keys}/reader.pem"
            "${toString writerId}=${keys}/writer.pem"
            "${toString runnerAppId}=${keys}/runner.pem"
          ];
        # Up before anything asks it.
        postStart = ''
          for _ in $(seq 50); do
            ${pkgs.curl}/bin/curl -s -o /dev/null ${api}/ && exit 0
            sleep 0.2
          done
        '';
      };
    };

  testScript = ''
    import json

    def requests():
        return [json.loads(l) for l in machine.succeed("cat /run/github-api-stub.log").splitlines()]

    machine.wait_for_unit("multi-user.target")

    with subtest("the reader's token is minted, narrowed and written for the group"):
        machine.wait_until_succeeds("test -s /run/github-app/token", timeout=120)
        machine.succeed("[ \"$(stat -c '%a %U %G' /run/github-app/token)\" = '440 root github-token' ]")
        machine.succeed("grep -qxE 'access-tokens = github.com=ghs_stub[0-9]+' /run/github-app/token")
        first = [r for r in requests() if r["kind"] == "installation"][0]
        assert first["app"] == "${toString readerId}", first
        assert first["body"] == {"permissions": {"contents": "read"}}, first

    with subtest("root's nixos-install-helper copy follows the token"):
        machine.wait_until_succeeds("cmp /run/github-app/token /run/install-helper/nix-access-tokens.conf")

    with subtest("a refresh replaces it, and root's copy follows again"):
        before = machine.succeed("cat /run/github-app/token")
        machine.succeed("systemctl start github-app-reader-token.service")
        after = machine.succeed("cat /run/github-app/token")
        assert before != after
        machine.wait_until_succeeds("cmp /run/github-app/token /run/install-helper/nix-access-tokens.conf")
        machine.succeed("systemctl list-timers github-app-reader-token.timer | grep -q github-app-reader-token")

    token = machine.succeed("sed -n 's/^access-tokens = github.com=//p' /run/github-app/token").strip()

    with subtest("a member of github-token gets the token from nix and git"):
        # nix.conf applies at all for a user (it sets nix-command here).
        machine.succeed("su alice -c 'nix config show experimental-features' | grep -q nix-command")
        machine.succeed(f"su alice -c 'nix config show access-tokens' | grep -q 'github.com={token}'")
        machine.succeed(
            "su alice -c \"printf 'protocol=https\\nhost=github.com\\n\\n' | GIT_TERMINAL_PROMPT=0 git credential fill\""
            f" | grep -qx 'password={token}'"
        )

    with subtest("anyone else gets neither, and nix still works for them"):
        machine.succeed("su bob -c 'nix config show experimental-features' | grep -q nix-command")
        machine.fail("su bob -c 'cat /run/github-app/token'")
        machine.fail(f"su bob -c 'nix config show access-tokens' | grep -q '{token}'")
        machine.fail(
            "su bob -c \"printf 'protocol=https\\nhost=github.com\\n\\n' | GIT_TERMINAL_PROMPT=0 git credential fill\""
        )

    with subtest("flakeAutoUpdate pushes with a writer token narrowed to its repository"):
        machine.succeed(
            "mkdir -p /srv/git /tmp/w",
            "git init -q -b main /tmp/w/dep",
            "git -C /tmp/w/dep -c user.name=t -c user.email=t@t commit -q --allow-empty -m one",
            "git clone -q --bare /tmp/w/dep /srv/git/dep.git",
            "git init -q -b main /tmp/w/example",
            "printf '{ inputs.dep = { url = \"git+file:///srv/git/dep.git\"; flake = false; }; outputs = _: { }; }' > /tmp/w/example/flake.nix",
            "git -C /tmp/w/example add flake.nix",
            "cd /tmp/w/example && nix flake lock",
            "git -C /tmp/w/example add flake.lock",
            "git -C /tmp/w/example -c user.name=t -c user.email=t@t commit -q -m init",
            "git clone -q --bare /tmp/w/example /srv/git/example.git",
            "git -C /tmp/w/dep -c user.name=t -c user.email=t@t commit -q --allow-empty -m two",
            "git -C /tmp/w/dep push -q /srv/git/dep.git main",
        )
        machine.succeed("systemctl start flake-auto-update-example.service")
        machine.succeed("git -C /srv/git/example.git log -1 --format=%s main | grep -qx 'chore: update flake'")
        writer = [r for r in requests() if r["kind"] == "installation" and r["app"] == "${toString writerId}"]
        assert writer, requests()
        assert writer[-1]["body"] == {
            "permissions": {"contents": "write", "pull_requests": "write"},
            "repositories": ["example"],
        }, writer

    with subtest("an organisation runner gets a registration token minted through the App"):
        machine.succeed("systemctl start --no-block github-runner-bench.service")
        machine.wait_until_succeeds("grep -qxE 'REGSTUB[0-9]+' /run/github-runner-registration/bench", timeout=120)
        machine.succeed("[ \"$(stat -c '%a %U' /run/github-runner-registration/bench)\" = '600 root' ]")
        registration = [r for r in requests() if r["kind"] == "registration"]
        assert registration[-1]["grant"] == {"permissions": {"organization_self_hosted_runners": "write"}}, registration

    with subtest("no installation token reaches the journal"):
        machine.fail("journalctl --no-pager | grep -q ghs_stub")
  '';
}
