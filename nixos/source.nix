{ config, lib, ... }:
let
  cfg = config.suveraen.source;

  # Nix names SSH key types differently from OpenSSH.
  nixKeyType = {
    "ssh-ed25519" = "ssh-ed25519";
    "sk-ssh-ed25519@openssh.com" = "ssh-ed25519-sk";
    "ecdsa-sha2-nistp256" = "ssh-ecdsa";
    "sk-ecdsa-sha2-nistp256@openssh.com" = "ssh-ecdsa-sk";
    "ssh-rsa" = "ssh-rsa";
  };

  parse =
    signer:
    let
      fields = lib.filter (f: f != "") (lib.splitString " " signer);
    in
    {
      type = lib.elemAt fields 0;
      key = lib.elemAt fields 1;
    };
in
{
  options.suveraen.source = {
    repository = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://github.com/owner/suveraen";
      description = ''
        Public Git repository (HTTPS) holding this host's configuration. The host switches to it every night, and a
        cluster server's Flux keeps the cluster in sync with it. null leaves updates to manual deploys.
      '';
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Branch to follow: servers follow the signed release branch, a canary the branch changes land on first.";
    };

    signers = lib.mkOption {
      type = lib.types.listOf (
        lib.types.strMatching "(${lib.concatStringsSep "|" (lib.attrNames nixKeyType)}) [A-Za-z0-9+/=]+( .*)?"
      );
      default = [ ];
      example = [ "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAA... release" ];
      description = ''
        SSH public keys, one of which must have signed the branch's head commit before the host or its cluster
        deploys it. Empty deploys whatever the branch holds.
      '';
    };

    flake = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      description = "Flake reference for the repository and branch, with the signature check when there are signers.";
    };

    keys = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.str);
      readOnly = true;
      internal = true;
      description = "Signers as type and key, for the modules that check signatures.";
    };
  };

  config = {
    suveraen.source = {
      keys = map parse cfg.signers;
      flake =
        if cfg.repository == null then
          null
        else
          "git+${cfg.repository}?ref=${cfg.branch}"
          +
            lib.optionalString (cfg.signers != [ ])
              "&publicKeys=${
                lib.escapeURL (
                  builtins.toJSON (
                    map (k: {
                      type = nixKeyType.${k.type};
                      inherit (k) key;
                    }) cfg.keys
                  )
                )
              }";
    };

    nix.settings.experimental-features = lib.mkIf (cfg.signers != [ ]) [ "verified-fetches" ];
  };
}
