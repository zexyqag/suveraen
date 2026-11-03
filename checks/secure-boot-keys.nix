# Test only: Secure Boot keys made in the build. keys/ holds the PK, KEK and db pairs, db's where lanzaboote signs with
# it; auth/ the four variables as a host's settings name them, signed as the firmware takes them in setup mode, with a
# stand-in entry for dbx.
pkgs:
let
  # Owner of the signature lists, as `systemd-id128 new --uuid` makes one.
  owner = "8c4b7ec1-0b5e-4d2a-9a6c-2f1f3c5d7e90";
in
pkgs.runCommand "secure-boot-test-keys"
  {
    nativeBuildInputs = [
      pkgs.openssl
      pkgs.sbsigntool
    ];
  }
  ''
    mkdir -p $out/auth
    for k in PK KEK db; do
      mkdir -p $out/keys/$k
      openssl req -new -x509 -newkey rsa:2048 -nodes -days 7300 -subj "/CN=test $k/" \
        -keyout $out/keys/$k/$k.key -out $out/keys/$k/$k.pem
      openssl x509 -outform DER -in $out/keys/$k/$k.pem -out $k.der
      sbsiglist --owner ${owner} --type x509 --output $k.esl $k.der
    done
    printf stand-in | openssl dgst -sha256 -binary > revoked.bin
    sbsiglist --owner ${owner} --type sha256 --output dbx.esl revoked.bin
    sign() {
      sbvarsign --attr NON_VOLATILE,RUNTIME_ACCESS,BOOTSERVICE_ACCESS,TIME_BASED_AUTHENTICATED_WRITE_ACCESS \
        --key $out/keys/$1/$1.key --cert $out/keys/$1/$1.pem --output $out/auth/$2.auth $2 $2.esl
    }
    sign PK PK
    sign PK KEK
    sign KEK db
    sign KEK dbx
  ''
