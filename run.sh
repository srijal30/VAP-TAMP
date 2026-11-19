#! /usr/bin/bash

xhost +local:

docker compose -f docker/compose.yaml exec remote bash 