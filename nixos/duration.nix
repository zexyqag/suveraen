# A span of time as options give it, such as 30s, 15m, 26h or 7d, and how many seconds that is.
lib: {
  type = lib.types.strMatching "[1-9][0-9]*[smhd]";
  seconds =
    s:
    let
      m = builtins.match "([0-9]+)([smhd])" s;
    in
    lib.toInt (lib.head m)
    * {
      s = 1;
      m = 60;
      h = 3600;
      d = 86400;
    }
    .${lib.last m};
}
