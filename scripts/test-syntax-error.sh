#!/bin/bash
# Fixed syntax — was intentionally broken for CI failure notification test
if [ -f /tmp/test ]; then
    echo "file exists"
fi
