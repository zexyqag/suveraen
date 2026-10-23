# Tests the gateway's pseudonym plugin with Go, then again with yaegi, which is how Traefik runs it.
{ pkgs, source }:
# The yaegi in the go.mod of the Traefik the gateway runs (platform/gateway): yaegi's quirks differ by version.
assert pkgs.yaegi.version == "0.16.1";
pkgs.runCommand "pseudonym"
  {
    nativeBuildInputs = [
      pkgs.go
      pkgs.yaegi
    ];
  }
  ''
    export GOTOOLCHAIN=local GOPROXY=off CGO_ENABLED=0 GOCACHE=$TMPDIR/cache HOME=$TMPDIR
    cp -r --no-preserve=mode ${source} $TMPDIR/pseudonym
    cd $TMPDIR/pseudonym
    unformatted=$(gofmt -l .)
    [ -z "$unformatted" ] || { echo "not gofmt'ed: $unformatted" >&2; exit 1; }
    go vet ./...
    go test ./...
    mkdir -p $TMPDIR/gopath/src/suveraen
    cp -r . $TMPDIR/gopath/src/suveraen/pseudonym
    GOPATH=$TMPDIR/gopath GO111MODULE=off yaegi test suveraen/pseudonym
    touch $out
  ''
