{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.suveraen.backup;
  zfs = config.boot.zfs.package;

  # The job runs with a private /tmp, so these mounts are only visible to it.
  root = "/tmp/snapshot";
  snapshot = "backup";

  under = path: mountPoint: mountPoint == path || lib.hasPrefix "${path}/" mountPoint;
  mounts = lib.sort (a: b: lib.stringLength a.mountPoint < lib.stringLength b.mountPoint) (
    lib.filter (fs: fs.fsType == "zfs" && lib.any (p: under p fs.mountPoint) cfg.paths) (
      lib.attrValues config.fileSystems
    )
  );
in
{
  options.suveraen.backup = {
    enable = lib.mkEnableOption "nightly encrypted backups to a remote Borg repository";

    repo = lib.mkOption {
      type = lib.types.str;
      example = "ssh://u123456@u123456.your-storagebox.de:23/./suveraen";
      description = "Borg repository. Hetzner Storage Boxes take Borg over SSH on port 23.";
    };

    knownHosts = lib.mkOption {
      type = lib.types.lines;
      example = "[u123456.your-storagebox.de]:23 ssh-ed25519 AAAA...";
      description = "known_hosts lines for the repository's SSH server (`ssh-keyscan -p 23 <host>`).";
    };

    passphraseFile = lib.mkOption {
      type = lib.types.str;
      description = "File holding the repository passphrase. Keep a copy off the server: without it the backups can't be read.";
    };

    sshKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "SSH private key the repository accepts.";
    };

    paths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "/var" ] ++ lib.optional (config.suveraen.storage.bulkDisks != [ ]) "/srv";
      defaultText = lib.literalExpression ''[ "/var" ] ++ lib.optional (bulk disks) "/srv"'';
      description = "ZFS mounts to back up. They are snapshotted first, so databases are saved in a consistent state; archives hold them under ${root}.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = map (path: {
      assertion = (config.fileSystems.${path}.fsType or null) == "zfs";
      message = "suveraen.backup.paths: ${path} is not a ZFS mount.";
    }) cfg.paths;

    services.borgbackup.jobs.suveraen = {
      inherit (cfg) repo;
      encryption = {
        mode = "repokey-blake2";
        passCommand = "cat ${cfg.passphraseFile}";
      };
      environment.BORG_RSH = "ssh -i ${cfg.sshKeyFile} -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${pkgs.writeText "backup-known-hosts" cfg.knownHosts}";
      paths = map (path: root + path) cfg.paths;
      exclude = map (path: root + path) [
        "/var/cache"
        "/var/tmp"
        "/var/lib/systemd/coredump"
      ];
      compression = "auto,zstd";
      startAt = "02:00";
      prune.keep = {
        daily = 7;
        weekly = 4;
        monthly = 12;
      };
      preHook = lib.concatMapStrings (fs: ''
        ${zfs}/sbin/zfs destroy ${fs.device}@${snapshot} 2>/dev/null || true
        ${zfs}/sbin/zfs snapshot ${fs.device}@${snapshot}
        mkdir -p ${root}${fs.mountPoint}
        ${zfs}/sbin/mount.zfs -o ro ${fs.device}@${snapshot} ${root}${fs.mountPoint}
      '') mounts;
      postHook = lib.concatMapStrings (fs: ''
        ${pkgs.util-linux}/bin/umount ${root}${fs.mountPoint} 2>/dev/null || true
        ${zfs}/sbin/zfs destroy ${fs.device}@${snapshot} || true
      '') (lib.reverseList mounts);
    };

    suveraen.alerts.units = [ "borgbackup-job-suveraen" ];
  };
}
