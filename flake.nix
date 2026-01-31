{
  description = "NixOS Development Host";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flox = {
      url = "github:flox/flox";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
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
        let
          cfg = config.devHost;
        in
        {
          imports = [
            inputs.disko.nixosModules.disko
          ];

          options.devHost = {
            hostName = mkOption {
              type = types.str;
              description = "Hostname for the system";
            };
            diskDevice = mkOption {
              type = types.str;
              default = "/dev/sda";
              description = "Disk device for installation";
            };
            timeZone = mkOption {
              type = types.str;
              default = "America/New_York";
              description = "System timezone";
            };
            locale = mkOption {
              type = types.str;
              default = "en_US.UTF-8";
              description = "System locale";
            };
            username = mkOption {
              type = types.str;
              description = "Primary user name";
            };
            initialPassword = mkOption {
              type = types.str;
              default = "password";
              description = "Initial password for the user";
            };
            sshKeys = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "SSH public keys for user and root";
            };
            stateVersion = mkOption {
              type = types.str;
              default = "25.11";
              description = "NixOS state version";
            };
            extraPackages = mkOption {
              type = types.listOf types.package;
              default = [ ];
              description = "Additional packages to install";
            };
          };

          config = {
            boot = {
              initrd = {
                availableKernelModules = mkDefault [
                  "ahci"
                  "ehci_pci"
                  "nvme"
                  "uhci_hcd"
                  "xhci_pci"
                ];
                kernelModules = mkDefault [ "kvm-intel" ];
                systemd = {
                  enable = mkDefault false;
                  tpm2.enable = mkDefault true;
                };
                verbose = mkDefault true;
              };
              # kernelPackages = mkDefault pkgs.linuxPackages_latest;
              kernelParams = mkDefault [
                "boot.shell_on_fail"
                "i915.enable_guc=3"
                "i915.modeset=1"
                "mem_sleep_default=deep"
                "pcie_aspm.policy=powersupersave"
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
                  device = cfg.diskDevice;
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
              hostName = cfg.hostName;
              useDHCP = mkDefault false;
              dhcpcd.enable = mkDefault false;
              useNetworkd = mkDefault false;
              firewall.allowedTCPPorts = [
                8443  # Kanidm HTTPS
                636   # Kanidm LDAP
              ];
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

            i18n.defaultLocale = cfg.locale;

            environment = {
              sessionVariables = {
                NIXPKGS_ALLOW_UNFREE = "1";
              };
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
                    nixfmt
                    nixos-container
                    nixpkgs-fmt
                    nodejs_24
                    podman-compose
                    podman-tui
                    service-wrapper
                    tzdata
                    wget
                  ]
                  inputs.flox.packages.${system}.flox
                  cfg.extraPackages
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
                  "https://cache.flox.dev?priority=42"
                ];
                trusted-public-keys = [
                  "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
                  "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
                  "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs="
                ];
                trusted-users = [
                  "root"
                  cfg.username
                  "@wheel"
                ];
              };
            };

            nixpkgs = {
              config = {
                allowUnfree = mkDefault true;
                allowUnfreePredicate = _: true;
              };
            };

            programs = {
              direnv = {
                enable = true;
                angrr = {
                  autoUse = true;
                  enable = true;
                };
                nix-direnv.enable = true;
                enableBashIntegration = true;
              };
              git = {
                enable = true;
                config.safe.directory = [ "/home/${cfg.username}/" ];
              };
              nix-ld = {
                enable = mkDefault true;
              };
            };

            services = {

              avahi = {
                enable = true;
                nssmdns4 = true;
                publish.addresses = true;
                publish.enable = true;
                publish.workstation = true;
              };

              bpftune.enable = true;

              btrfs = {
                autoScrub.enable = true;
                autoScrub.fileSystems = [ "/" ];
                autoScrub.interval = "weekly";
              };

              fstrim = {
                enable = mkDefault true;
                interval = mkDefault "daily";
              };

              fwupd.enable = mkDefault true;

              libinput.enable = mkDefault true;

              openssh = {
                enable = true;
                settings = {
                  PermitRootLogin = "prohibit-password";
                  # Enable password auth via Kanidm PAM
                  PasswordAuthentication = true;
                  UsePAM = true;
                };
              };

              power-profiles-daemon.enable = mkDefault true;

              samba = {
                enable = mkDefault true;
                package = pkgs.samba4Full;  # Includes LDAP support
                openFirewall = mkDefault true;
                nmbd.enable = mkDefault true;
                winbindd.enable = mkDefault false;
                settings = {
                  global = {
                    "workgroup" = mkDefault "WORKGROUP";
                    "server string" = mkDefault "NixOS Dev Host - ${cfg.hostName}";
                    "netbios name" = mkDefault cfg.hostName;
                    "hosts allow" = mkDefault "192.168.0.0/16 172.16.0.0/12 10.0.0.0/8 localhost";
                    "hosts deny" = mkDefault "0.0.0.0/0";
                    "map to guest" = "never";
                    # Use Kanidm LDAP for authentication
                    "passdb backend" = "ldapsam:ldaps://localhost:636";
                    "ldap admin dn" = "dn=idm_admin,o=localhost";
                    "ldap suffix" = "o=localhost";
                    "ldap user suffix" = "ou=people";
                    "ldap group suffix" = "ou=groups";
                    "ldap ssl" = "start tls";
                    "ldap passwd sync" = "yes";
                  };
                  homes = {
                    "comment" = "Home Directories";
                    "browseable" = "no";
                    "read only" = "no";
                    "create mask" = "0700";
                    "directory mask" = "0700";
                    "valid users" = "%S";
                  };
                };
              };

              samba-wsdd = {
                enable = mkDefault true;
                openFirewall = mkDefault true;
              };

              # Kanidm identity management (localhost)
              kanidm = {
                enableServer = true;
                enableClient = true;
                enablePam = true;
                package = pkgs.kanidm.withSecretProvisioning;
                serverSettings = {
                  origin = "https://localhost:8443";
                  domain = "localhost";
                  bindaddress = "[::]:8443";
                  ldapbindaddress = "[::]:636";
                  tls_chain = "/var/lib/kanidm/certs/cert.pem";
                  tls_key = "/var/lib/kanidm/certs/key.pem";
                  online_backup = {
                    path = "/var/lib/kanidm/backups";
                    versions = 7;
                    schedule = "0 3 * * *";
                  };
                };
                clientSettings = {
                  uri = "https://localhost:8443";
                  verify_ca = false;
                  verify_hostnames = false;
                };
                unixSettings = {
                  kanidm = {
                    pam_allowed_login_groups = [ "linux_users" ];
                  };
                };
                provision = {
                  enable = true;
                  acceptInvalidCerts = true;
                  idmAdminPasswordFile = "/var/lib/kanidm/secrets/idm_admin_password";
                  adminPasswordFile = "/var/lib/kanidm/secrets/admin_password";
                  groups.linux_users = { };
                  groups.samba_users = { };
                  persons.${cfg.username} = {
                    displayName = cfg.username;
                    groups = [ "linux_users" "samba_users" ];
                  };
                };
              };

              udisks2.enable = true;

              upower.enable = mkDefault true;

            };

            systemd = {
              # Generate self-signed TLS certificates and admin passwords for Kanidm
              services.kanidm-init = {
                description = "Initialize Kanidm certificates and secrets";
                wantedBy = [ "kanidm.service" ];
                before = [ "kanidm.service" ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                script = ''
                  # Certificates
                  CERT_DIR="/var/lib/kanidm/certs"
                  if [ ! -f "$CERT_DIR/cert.pem" ] || [ ! -f "$CERT_DIR/key.pem" ]; then
                    mkdir -p "$CERT_DIR"
                    ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:4096 \
                      -keyout "$CERT_DIR/key.pem" \
                      -out "$CERT_DIR/cert.pem" \
                      -sha256 -days 3650 -nodes \
                      -subj "/CN=localhost" \
                      -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1"
                    chown -R kanidm:kanidm "$CERT_DIR"
                    chmod 600 "$CERT_DIR/key.pem"
                    chmod 644 "$CERT_DIR/cert.pem"
                  fi

                  # Admin passwords (only created once)
                  SECRET_DIR="/var/lib/kanidm/secrets"
                  mkdir -p "$SECRET_DIR"
                  if [ ! -f "$SECRET_DIR/idm_admin_password" ]; then
                    ${pkgs.openssl}/bin/openssl rand -base64 24 > "$SECRET_DIR/idm_admin_password"
                  fi
                  if [ ! -f "$SECRET_DIR/admin_password" ]; then
                    ${pkgs.openssl}/bin/openssl rand -base64 24 > "$SECRET_DIR/admin_password"
                  fi
                  chown -R kanidm:kanidm "$SECRET_DIR"
                  chmod 600 "$SECRET_DIR"/*
                '';
              };
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
              timers.flake-update = {
                wantedBy = [ "timers.target" ];
                timerConfig = {
                  OnCalendar = "hourly";
                  Persistent = true;
                  Unit = "flake-update.service";
                };
              };
            };

            system = {
              autoUpgrade = {
                allowReboot = mkDefault true;
                enable = mkDefault true;
                flake = mkDefault "/etc/nixos";
                rebootWindow = mkDefault {
                  lower = "01:00";
                  upper = "05:00";
                };
                runGarbageCollection = mkDefault true;
              };
              stateVersion = cfg.stateVersion;
            };

            time.timeZone = cfg.timeZone;

            users = {
              defaultUserShell = pkgs.bashInteractive;
              users = {
                ${cfg.username} = {
                  extraGroups = [ "wheel" ];
                  initialPassword = cfg.initialPassword;
                  isNormalUser = true;
                  openssh.authorizedKeys.keys = cfg.sshKeys;
                };
                root = {
                  openssh.authorizedKeys.keys = cfg.sshKeys;
                };
              };
            };

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
    };
}
