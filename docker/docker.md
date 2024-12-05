# Manual docker installation

**1.** Install packages:
  * [docker](https://archlinux.org/packages/?name=docker) (or [docker-git](https://aur.archlinux.org/packages/docker-git) from AUR)  
  * [docker-compose](https://archlinux.org/packages/?name=docker-compose)
  * [docker-buildx](https://archlinux.org/packages/?name=docker-buildx) - for build container images 
```bash
sudo pacman -Syu docker docker-compose
```
**2.** Enable/start `docker.service` or `docker.socket`:  
  * `docker.service` starts docker on boot.
  * `docker.socket` starts docker on first usage.
```bash
sudo systemctl enable --now docker.socket
```
**3.** Check docker status:  
```bash
sudo docker info
# If error, check status:
sudo systemctl status docker.socket
sudo systemctl status docker.service
# Re-login or reboot the system if the problem is not resolved.
```
**4.** *(Optional)* Add user to the `docker` user group:
```bash
sudo usermod -aG docker $USER
# Use:
newgrp docker
# or re-login so that your group membership will be re-evaluated

# If problems, check user groups:
groups $USER
```
**5.** *(Optional)* Install offical Docker Desktop:  
View docker site: [DockerDocs](https://docs.docker.com/desktop/install/linux/archlinux/)

**6.** *(Optional)* Install third party apps for managing docker containers:  
  * ducker
  * lazydocker and other...

