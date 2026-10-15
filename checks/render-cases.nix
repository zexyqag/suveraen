# Breaks copies of kubernetes/ in ways render.sh must refuse, and checks that it refuses each for the intended reason
# (render-cases.sh).
{ pkgs, kubernetes }:
pkgs.runCommand "render-cases"
  {
    nativeBuildInputs = [
      pkgs.fluxcd
      pkgs.yq-go
    ];
  }
  ''
    set -o pipefail
    export HOME=$TMPDIR
    bash ${./render-cases.sh} ${./render.sh} ${kubernetes} | tee $out
  ''
