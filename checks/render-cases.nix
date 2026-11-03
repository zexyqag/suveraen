# Breaks copies of kubernetes/ in ways render.sh must refuse, and checks that it refuses each for the intended reason
# (render-cases.sh). The cases take half an hour of a runner's cores, so they come in shards, each a check of its own.
{
  pkgs,
  kubernetes,
  ranges,
  kanidm,
  netbird,
  shards,
}:
pkgs.lib.genAttrs' (pkgs.lib.range 1 shards) (
  shard:
  pkgs.lib.nameValuePair "render-cases-${toString shard}" (
    pkgs.runCommand "render-cases-${toString shard}"
      {
        nativeBuildInputs = [
          pkgs.fluxcd
          pkgs.yq-go
          pkgs.python3
        ];
      }
      ''
        set -o pipefail
        export HOME=$TMPDIR CLUSTER_RANGES=${pkgs.lib.escapeShellArg ranges} KANIDM_VERSION=${kanidm.version} \
          NETBIRD_PINS=${pkgs.lib.escapeShellArg (builtins.toJSON netbird)}
        bash ${./render-cases.sh} ${./render.sh} ${kubernetes} ${toString shard} ${toString shards} | tee $out
      ''
  )
)
