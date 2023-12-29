#!/bin/sh

rsync -avrP --delete amun:/var/lib/rancher/k3s/storage /backup/amun/var/lib/rancher/k3s
rsync -avrP --delete isis:/var/lib/rancher/k3s/storage /backup/isis/var/lib/rancher/k3s
