# Renders every cluster under kubernetes/clusters the way Flux would, offline, and checks the rules Flux itself
# wouldn't catch (render.sh).
{ pkgs, kubernetes }:
pkgs.runCommand "render"
  {
    nativeBuildInputs = [
      pkgs.fluxcd
      pkgs.yq-go
    ];
  }
  ''
    export HOME=$TMPDIR
    bash ${./render.sh} ${kubernetes} $out
  ''
