#!/bin/bash
# Размер очереди, возраст самой старой задачи, размер DLQ.
COLOR=$(grep -oP '(?<=backend-)[a-z]+(?=:8000)' /home/jahongir/devops-backend/nginx/nginx.conf | head -1)
docker exec "backend-$COLOR" python queue_stats.py
