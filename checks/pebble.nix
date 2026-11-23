# Test only: the Pebble the test ACME CAs run, without two of its deadlocks.
pkgs:
pkgs.pebble.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    # Reading an order while it's finalized deadlocks; fixed in 2.10.2, where this stops applying and fails the build:
    # drop it then.
    ./pebble-order-deadlock.patch
    # An authz poll, a new order and a queued writer deadlock; not fixed upstream.
    ./pebble-authz-lock-order.patch
  ];
})
