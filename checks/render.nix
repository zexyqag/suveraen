# Renders every cluster under kubernetes/clusters the way Flux would, offline, and checks the rules Flux itself
# wouldn't catch (render.sh).
{
  pkgs,
  kubernetes,
  ranges,
  nodeServices,
  kanidm,
  netbird,
  peerColumns,
}:
pkgs.runCommand "render"
  {
    nativeBuildInputs = [
      pkgs.fluxcd
      pkgs.yq-go
      pkgs.jq
      pkgs.python3
    ];
  }
  ''
    export HOME=$TMPDIR CLUSTER_RANGES=${pkgs.lib.escapeShellArg ranges} \
      NODE_SERVICES=${pkgs.lib.escapeShellArg nodeServices} KANIDM_VERSION=${kanidm.version} \
      NETBIRD_PINS=${pkgs.lib.escapeShellArg (builtins.toJSON netbird)} \
      NETBIRD_PEER_COLUMNS=${pkgs.lib.escapeShellArg (builtins.toJSON peerColumns)}
    bash ${./render.sh} ${kubernetes} $out
  ''
