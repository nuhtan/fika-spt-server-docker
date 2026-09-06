FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble

RUN apt update && apt install -y --no-install-recommends \
    curl \
    aria2 \
    ca-certificates \
    unzip \
    7zip \
    vim \
    cron \
    exiftool \
    jq \
    dos2unix

ARG SPT_VERSION=4.1.5-40743-7d7add5
ARG FIKA_VERSION=2.4.0
ENV SPT_VERSION=$SPT_VERSION
ENV FIKA_VERSION=$FIKA_VERSION

WORKDIR /opt/build
# SPT moved from the sp-tarkov org to SP-Tushonka. The new mirror only carries
# 4.1.3+, so fall back to the GitHub release asset and then the frozen legacy
# mirror, which is the only source for <= 4.1.2.
RUN SPT_VERSION_NUM=$(echo "${SPT_VERSION}" | cut -d'-' -f1); \
    curl -fSL "https://mirror.sp-tushonka.com/releases/SPT-${SPT_VERSION}.7z" -o spt.7z || \
    curl -fSL "https://github.com/SP-Tushonka/build/releases/download/${SPT_VERSION_NUM}/SPT-${SPT_VERSION}.7z" -o spt.7z || \
    curl -fSL "https://spt-releases.modd.in/SPT-${SPT_VERSION}.7z" -o spt.7z
RUN 7z x spt.7z

COPY entrypoint.sh /usr/bin/entrypoint
COPY scripts/backup.sh /usr/bin/backup
COPY scripts/download_unzip_install_mods.sh /usr/bin/download_unzip_install_mods
COPY data/cron/cron_backup_spt /etc/cron.d/cron_backup_spt
RUN dos2unix /usr/bin/entrypoint /usr/bin/backup /usr/bin/download_unzip_install_mods /etc/cron.d/cron_backup_spt && \
    chmod +x /usr/bin/entrypoint /usr/bin/backup /usr/bin/download_unzip_install_mods /etc/cron.d/cron_backup_spt

# Docker desktop doesn't allow you to configure port mappings unless this is present
EXPOSE 6969
ENTRYPOINT ["/usr/bin/entrypoint"]
