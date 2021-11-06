FROM archlinux:latest

COPY entrypoint.sh /entrypoint.sh
RUN rm -v /etc/makepkg.conf
COPY makepkg.conf /etc/makepkg.conf
COPY jemalloc.pkg.tar.zst /jemalloc.pkg.tar.zst
RUN pacman -U /jemalloc.pkg.tar.zst --noconfirm

ENTRYPOINT ["/entrypoint.sh"]
