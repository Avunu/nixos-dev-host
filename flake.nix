{
  description = "NixOS Development Host";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      ...
    }:
    let
      lib = nixpkgs.lib;
    in
    {
      nixosModules.devHost =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        with lib;
        {
          imports = [
            disko.nixosModules.disko
          ];
          boot = {
            initrd = {
              availableKernelModules = mkDefault [
                "ahci"
                "ehci_pci"
                "nvme"
                "uhci_hcd"
              ];
              kernelModules = mkDefault [ "fbcon" ];
              systemd = {
                enable = mkDefault true;
                tpm2.enable = mkDefault true;
              };
              verbose = mkDefault true;
            };
            kernelPackages = mkDefault pkgs.linuxPackages_latest;
            kernelParams = mkDefault [
              "boot.shell_on_fail"
              "console=tty0"
              "fbcon=vc:2-6"
              "i915.enable_guc=3"
              "i915.modeset=1"
              "loglevel=3"
              "mem_sleep_default=deep"
              "pcie_aspm.policy=powersupersave"
              "rd.systemd.show_status=false"
              "rd.udev.log_level=3"
              "udev.log_priority=3"
            ];
            consoleLogLevel = mkDefault 0;
            loader = {
              efi.canTouchEfiVariables = mkDefault true;
              systemd-boot = {
                configurationLimit = mkDefault 10;
                enable = mkDefault true;
              };
            };
            plymouth.enable = mkDefault false;
          };

          console = {
            keyMap = mkDefault "us";
            packages = mkDefault [ pkgs.terminus_font ];
          };

          disko.devices = {
            disk = {
              main = {
                device = mkDefault "/dev/sda";
                type = "disk";
                content = {
                  type = "gpt";
                  partitions = {
                    ESP = {
                      size = "1G";
                      type = "EF00";
                      content = {
                        type = "filesystem";
                        format = "vfat";
                        mountpoint = "/boot";
                        mountOptions = [
                          "noatime"
                          "umask=0077"
                        ];
                        extraArgs = [
                          "-n"
                          "ESP"
                        ];
                      };
                    };
                    root = {
                      size = "100%";
                      content = {
                        type = "filesystem";
                        format = "btrfs";
                        mountpoint = "/";
                        mountOptions = [
                          "compress=zstd:3"
                          "discard=async"
                          "noatime"
                          "space_cache=v2"
                          "ssd"
                        ];
                        extraArgs = [
                          "-L"
                          "root"
                        ];
                      };
                    };
                  };
                };
              };
            };
          };

          documentation = {
            enable = mkDefault false;
            doc.enable = mkDefault false;
            man.enable = mkDefault false;
            nixos.enable = mkDefault false;
          };

          networking = {
            useDHCP = mkDefault false;
            dhcpcd.enable = mkDefault false;
            useNetworkd = mkDefault true;
          };

          systemd.network = {
            enable = mkDefault true;
            networks."10-wan" = {
              matchConfig.Name = mkDefault [
                "en*"
                "eth*"
              ];
              networkConfig = {
                DHCP = mkDefault "yes";
                IPv6AcceptRA = mkDefault true;
              };
              dhcpV4Config = {
                RouteMetric = mkDefault 1024;
                UseDNS = mkDefault true;
              };
              dhcpV6Config = {
                RouteMetric = mkDefault 1024;
                UseDNS = mkDefault true;
              };
            };
          };

          environment = {
            systemPackages =
              with pkgs;
              lib.flatten [
                (python3.withPackages (
                  python-pkgs: with python-pkgs; [
                    black
                    flake8
                    isort
                    pandas
                    requests
                  ]
                ))
                [
                  bun
                  ccache
                  cmake
                  corepack_22
                  curl
                  docker-compose
                  gh
                  git
                  gnumake
                  nano
                  nixfmt-rfc-style
                  nixos-container
                  nixpkgs-fmt
                  nodejs_22
                  podman-compose
                  podman-tui
                  tzdata
                  wget
                ]
              ];
          };

          nix = {
            gc = {
              automatic = mkDefault true;
              dates = mkDefault "weekly";
              options = mkDefault "--delete-older-than 1w";
            };
            settings = {
              auto-optimise-store = true;
              experimental-features = [
                "nix-command"
                "flakes"
              ];
              substituters = [
                "https://cache.nixos.org?priority=40"
                "https://nix-community.cachix.org?priority=41"
              ];
              trusted-public-keys = [
                "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
                "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
              ];
              trusted-users = [
                "root"
                "nixos"
                "@wheel"
              ];
            };
          };

          nixpkgs = {
            config = {
              allowUnfree = mkDefault true;
            };
          };

          programs = {
            git = {
              enable = true;
              config.safe.directory = [ "/etc/nixos" ];
            };
            nix-ld = {
              enable = mkDefault true;
            };
          };

          services = {
            fstrim = {
              enable = mkDefault true;
              interval = mkDefault "daily";
            };
            fwupd.enable = mkDefault true;
            libinput.enable = mkDefault true;
            openssh = {
              enable = true;
              settings = {
                PermitRootLogin = "yes";
                PasswordAuthentication = true;
              };
            };
            power-profiles-daemon.enable = mkDefault true;
            udisks2.enable = true;
            upower.enable = mkDefault true;
          };

          systemd = {
            services.flake-update = {
              unitConfig = {
                Description = "Update flake inputs";
                StartLimitIntervalSec = 300;
                StartLimitBurst = 5;
              };
              serviceConfig = {
                ExecStart = "${pkgs.nix}/bin/nix flake update --commit-lock-file --flake /etc/nixos";
                Restart = "on-failure";
                RestartSec = "120s";
                Type = "oneshot";
                User = "root";
                Environment = "HOME=/root";
              };
              wants = [ "network-online.target" ];
              after = [ "network-online.target" ];
              before = [ "nixos-upgrade.service" ];
              path = with pkgs; [
                nix
                git
                host
              ];
              requiredBy = [ "nixos-upgrade.service" ];
            };
          };

          system.autoUpgrade = {
            allowReboot = mkDefault false;
            enable = mkDefault true;
            flake = mkDefault "/etc/nixos";
          };

          users.defaultUserShell = pkgs.bashInteractive;

          virtualisation = {
            containers.storage.settings = {
              storage = {
                driver = "btrfs";
                graphroot = "/var/lib/containers/storage";
                runroot = "/run/containers/storage";
              };
            };
            oci-containers.backend = "podman";
            podman = {
              autoPrune.enable = true;
              defaultNetwork.settings = {
                dns_enabled = true;
              };
              dockerCompat = true;
              dockerSocket.enable = true;
              enable = true;
            };
          };

          zramSwap.enable = mkDefault true;

        };
    };
}
