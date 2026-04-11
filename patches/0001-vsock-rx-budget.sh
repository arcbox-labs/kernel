#!/bin/sh
# vsock: add NAPI-style budget to rx_work to prevent RCU stalls
#
# The virtio_vsock rx_work processes all RX descriptors in a tight loop.
# When the host VMM injects faster than enable_cb detects quiescence,
# rx_work loops forever → RCU stall. This adds a budget of 64 packets
# per work invocation, matching virtio-net's NAPI approach.
#
# Applied to: net/vmw_vsock/virtio_transport.c (Linux 6.12.x)

set -e

FILE="net/vmw_vsock/virtio_transport.c"

if [ ! -f "$FILE" ]; then
    echo "SKIP: $FILE not found (not in kernel source tree)"
    exit 0
fi

if grep -q "VIRTIO_VSOCK_RX_BUDGET" "$FILE"; then
    echo "SKIP: vsock rx budget already applied"
    exit 0
fi

echo "Applying vsock rx_work budget patch to $FILE..."

cp "$FILE" "$FILE.orig"

awk '
# State machine:
#   0 = scanning
#   1 = found workqueue decl, looking to insert define
#   2 = define inserted, looking for rx_work function
#   3 = inside rx_work, looking for virtqueue_disable_cb
#   4 = looking for recv_pkt call to insert budget check

BEGIN { state = 0 }

# Insert the #define after the workqueue declaration.
/^static struct workqueue_struct \*virtio_vsock_workqueue;/ {
    print
    print ""
    print "/* Max packets per rx_work invocation before yielding."
    print " * Prevents RCU stalls when the host VMM continuously injects"
    print " * descriptors faster than enable_cb can detect quiescence."
    print " */"
    print "#define VIRTIO_VSOCK_RX_BUDGET 64"
    state = 2
    next
}

# Detect entry into virtio_transport_rx_work.
state == 2 && /^static void virtio_transport_rx_work/ {
    state = 3
    print
    next
}

# Inside rx_work: insert budget decl before virtqueue_disable_cb.
state == 3 && /virtqueue_disable_cb\(vq\);/ {
    print "\t\tint budget = VIRTIO_VSOCK_RX_BUDGET;"
    print
    state = 4
    next
}

# Inside rx_work: insert budget check after recv_pkt call.
state == 4 && /virtio_transport_recv_pkt\(/ {
    print
    print ""
    print "\t\t\tif (--budget <= 0) {"
    print "\t\t\t\t/* Yield to prevent RCU stalls. Refill"
    print "\t\t\t\t * so host has fresh descriptors, then"
    print "\t\t\t\t * reschedule to process the rest."
    print "\t\t\t\t */"
    print "\t\t\t\tvirtio_vsock_rx_fill(vsock);"
    print "\t\t\t\tqueue_work(virtio_vsock_workqueue,"
    print "\t\t\t\t\t   &vsock->rx_work);"
    print "\t\t\t\tgoto out;"
    print "\t\t\t}"
    state = 5
    next
}

{ print }
' "$FILE.orig" > "$FILE"

rm "$FILE.orig"

# Verify.
if grep -q "VIRTIO_VSOCK_RX_BUDGET" "$FILE" && \
   grep -q "budget <= 0" "$FILE"; then
    echo "OK: vsock rx budget patch applied successfully"
else
    echo "ERROR: patch verification failed"
    exit 1
fi
