#!/usr/bin/env bash
# Intentionally broken bash for CI failure test
if [ -f /tmp/x  # missing closing bracket → bash -n will fail
  echo "broken"
fi
