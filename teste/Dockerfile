# Ubuntu Server 24.04 com systemd, para testar os scripts antes da VM de verdade.
# O container faz o papel da VM: systemd como PID 1, serviços, timers e journal funcionam igual.
# Rede, hostname e auditd são do host Docker; os scripts percebem isso e avisam.
FROM ubuntu:24.04
ENV container=docker DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv sudo ca-certificates curl git bc \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl mask systemd-udevd.service systemd-udev-trigger.service getty.target console-getty.service \
      systemd-firstboot.service systemd-networkd-wait-online.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
