---
title: "Backing up MariaDB on Kubernetes"
date: 2023-12-27T05:12:16+00:00
slug: backing-up-mariadb-on-kubernetes
cover:
  image: /images/2023-mariadb-backup/MariaDB_colour_logo.svg
tags: [mysql, kubernetes, mariadb, backup, cronjob]
aliases:
- /backing-up-mariadb-on-kubernetes

---

Hosting MariaDB on Kubernetes proved so far a quite good experience: using the [Bitnami Helm Chart](https://github.com/bitnami/charts/tree/main/bitnami/mariadb) to host a "standalone" instance (i.e. without replication, as replication already happens on the storage layer, and because simplicity is more valuable than a complex HA setup like Galera) of MariaDB worked out quite well.

Being cautious, I had configured a daily backup to S3, using a [tool found on Github](https://github.com/benjamin-maynard/kubernetes-cloud-mysql-backup), but when it came to restoring data dumped with this tool, which uses a pretty old `mysqldump` binary, I was stuck and couldn't restore 😅
For some reason, the default config of the tool didn't bother to escape quotes and other sensitive types of chars, and as a result I had to resort to restoring my daily `velero` backup of my MariaDB instance in another namespace to make a proper export from there and to finally restore my data.

Following that, I spent some time writing the following script, which runs as a Kubernetes CronJob, and uses a combination of `mariadbdump`, `gzip --rsyncable`, and `restic` to export all my DBs.

The code is available in the following GitHub gist, but the key aspects are:

* using `mariadb:latest` Docker image, to ensure I don't use an outdated `mariadbdump` binary.

* backing up each database in a separate file, to make for easier restore.

* compressing the backups with gzip and the `--rsyncable` option (details [here](https://beeznest.wordpress.com/2005/02/03/rsyncable-gzip/)), which makes `gzip` "*regularly reset his compression algorithm to what it was at the beginning of the file"*, so that changes to a portion of the file do not alter the whole compressed output, which permits to make incremental backups.

* using `restic` to store the backups on an S3 endpoint (Cloudflare R2, with a generous free tier!), which makes for simple management and rotation, as well as for simple restores.

Hoping this helps someone make safer backups :)

{{< gist clementnuss d66ff435f11570944f646b4f8a1677be>}}
