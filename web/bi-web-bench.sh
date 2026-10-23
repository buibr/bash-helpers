#!/bin/bash
# bi: Apache-bench a URL for 10s with 10 concurrent connections
# bi-arg: @none

ab -t 10 -c 10 -k $1