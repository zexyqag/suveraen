# The calendar of a timer that runs every n hours from midnight, n dividing 24, at the given minute past the hour.
# systemd repeats an hour by 23 at most, so a daily one names its hour.
n: minute: "*-*-* ${if n < 24 then "00/${toString n}" else "00"}:${minute}:00"
