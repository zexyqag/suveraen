# Rules and a job of a server's metrics that its evaluation refuses (refused.txt): each prints, or is keyed by, what may
# not leave the server, is named so that its findings' keys could be another's, reads what no job keeps, or keeps what
# no rule reads.
let
  rule = detail: {
    expr = "vector(1)";
    title = "refused";
    cleared = "refused no more";
    inherit detail;
    reads = [ ];
  };
in
{
  suveraen.metrics = {
    jobs.unread = {
      scrape.static_configs = [ { targets = [ "127.0.0.1:9999" ]; } ];
      keep = [ "unread_total" ];
    };
    rules = {
      "prints an instance" = rule "{{ $labels.instance }} found";
      "prints by dot" = rule "{{ .Labels.name }} found";
      "prints a query" = rule ''{{ query "up" | first | value }} found'';
      "prints half" = rule "{{ $labels.name found";
      "titled by a label" = rule "found" // {
        title = "{{ $labels.name }} refused";
      };
      "keyed by an instance" = rule "found" // {
        key = [ "instance" ];
      };
      "reads nowhere" = rule "found" // {
        reads = [ "nowhere_total" ];
      };
      "target down" = rule "found";
      Watchdog = rule "found";
      disk = rule "found";
      "disk full" = rule "found";
    };
  };
}
