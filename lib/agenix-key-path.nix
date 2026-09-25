# Where every dev host keeps its agenix identity. One place, because two things
# must agree on it: modules/secrets.nix points age.identityPaths here, and
# lib/mk-host.nix tells the installer to put the key here.
"/etc/agenix/key"
