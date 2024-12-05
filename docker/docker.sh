#!/bin/bash

echo "Start install 'docker'..."
sleep 1
sudo pacman -Syu docker docker-compose

echo "Enable systemd units(docker.socket)..."
sleep 1
sudo systemctl enable --now docker.socket

echo "Add user to the 'docker' group..."
sleep 1
sudo usermod -aG docker $USER
newgrp docker

echo "Finished install 'docker'..."
docker info