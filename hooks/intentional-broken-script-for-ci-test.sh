#!/bin/bash
# THIS SCRIPT IS INTENTIONALLY BROKEN.
# It exists ONLY to verify that CI failure wake events are delivered
# to the originating Claude Code session via the FIFO push-wake mechanism.
# The PR containing this file MUST NOT be merged — close it after the
# failure wake event has been received.
#
# Below is a deliberate bash syntax error that bash -n will catch:

if then
    echo "this never runs"
fi
