#!/bin/bash

set -e
iptables -D DOCKER-USER -p tcp --dport 9090 -j DROP 2>/dev/null || true
iptables -D DOCKER-USER -p tcp --dport 9090 -s 192.168.64.5 -j ACCEPT 2>/dev/null || true
iptables -I DOCKER-USER 1 -p tcp --dport 9090 -s 192.168.64.5 -j ACCEPT
iptables -I DOCKER-USER 2 -p tcp --dport 9090 -j DROP
