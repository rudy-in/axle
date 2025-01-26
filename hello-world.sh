#!/bin/bash
while true; do
    echo "Hello, World! $(date)" >> /var/log/hello-world.log
    sleep 60
done