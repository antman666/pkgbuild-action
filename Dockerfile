FROM archlinux:latest

COPY entrypoint.sh /entrypoint.sh
RUN rm -v /etc/makepkg.conf /etc/pacman.conf
COPY pacman.conf /etc/pacman.conf
COPY makepkg.conf /etc/makepkg.conf

ENTRYPOINT ["/entrypoint.sh"]
