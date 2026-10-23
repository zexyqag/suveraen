# Renders every cluster under kubernetes/clusters the way Flux would, offline, and checks the rules Flux itself
# wouldn't catch (render.sh).
{
  pkgs,
  kubernetes,
  ranges,
}:
pkgs.runCommand "render"
  {
    nativeBuildInputs = [
      pkgs.fluxcd
      pkgs.yq-go
      pkgs.python3
    ];
  }
  ''
    export HOME=$TMPDIR CLUSTER_RANGES=${pkgs.lib.escapeShellArg ranges}
    bash ${./render.sh} ${kubernetes} $out
  ''
