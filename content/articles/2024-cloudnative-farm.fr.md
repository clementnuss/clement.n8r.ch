---
title: "Une Ferme Connectée: partie 1 - La Traite 🐄 🥛"
date: 2024-02-07T17:12:16+00:00
slug: ferme-connectee-la-traite
cover:
   image: /images/2024-milk-exporter/grafana-dashboard-excerpt.png
tags: [kubernetes, metrics, grafana, mdb, Access, lait, ferme]
---

À côté de mon travail d'Ingénieur Système (focus Kubernetes) chez PostFinance,
je suis marié à une agricultrice en Suisse, et vis avec elle et sa famille sur
l'exploitation familiale. \
Cela me change de mon travail quotidien, et j'ai
parfois l'occasion d'aider en donnant par exemple à boire aux veaux lors de la
traite, en utilisant mes compétences pour par exemple installer des caméras de
surveillance, pour déployer un réseau WiFi longue distance à travers
l'exploitation, ou encore pour moderniser la surveillance de la traite
quotidienne. \
C'est ce dernier point que je détaille aujourd'hui (sans les détails
techniques, qui seront eux abordés dans la version anglaise de cette article,
et dans le [README](https://github.com/clementnuss/alpro-openmetrics-exporter)
du projet OpenSource que j'ai créé pour ce projet).

## La Ferme et la traite

Mon épouse et sa famille traient quotidiennement 65 vaches laitières Holstein,
à 5h30 le matin et à 16h30 pour la traite du soir. Les données de la traite
sont enregistrées dans un logiciel appelé Alpro, qui n'a plus été mis à jour
depuis 2009.

Le logiciel permet d'obtenir un grand nombre d'informations sur les vaches,
comme la quantité de lait pour chaque traite, la quantité de concentré
distribué à la vache, la durée de la traite, le nombre de jours depuis la
dernière mise-bas, etc.

Bien que ces données soit intéressantes, comme le seul moyen d'y accéder est de
se connecter à l'ordinateur et de d'utiliser le vieux logiciel à l'interface
démodée, je me suis intéressé à essayer d'importer les données de la traite
dans une base de données chronologique (en anglais: time-series database), afin
de pouvoir ensuite visualiser ces données avec un logiciel moderne et que
j'apprécie au quotidien: Grafana.

### Importer les données Access

Pour ce faire, je me suis intéressé à la base de données employée par le
logiciel Alpro, qui est une base de donnée Access assez vieille, mais que l'on
peut toujours ouvrir avec des logiciels comme MDB/ACCDB viewer sour MacOS, avec
Microsoft Access, ou encore avec l'excellent logiciel open-source
[mdbtools](https://github.com/mdbtools/mdbtools).

Le processus pour sortir les données `Access` et les convertir au format
OpenMetrics/Prometheus est le suivant:

1. je sauvegarde les fichiers de la base de données Alpro avec le logiciel
   open-source [restic](https://restic.net/), qui me permet assez facilement de
   faire une sauvegarde incrémentale toutes les 15 minutes sur un serveur S3
   (en l'occurrence, Cloudflare R2, avec une offre gratuite généreuse), et qui
   gère automatiquement la rotation des sauvegardes
1. je télécharge la dernière sauvegarde dans un `CronJob` sous Kubernetes, et
   je convertis les fichiers Access `.mdb` en une base de données `SQLite`
1. un script python importe les données `SQLite` avec la librairie
   [pandas](https://pandas.pydata.org/), convertit les "timestamps", filtre les
   données manquantes/erronéees, puis génère des enregistrements
   OpenMetrics/Prometheus
1. j'envoie tous ces enregistrements dans ma base de donnée chronologique de
   prédilection: [VictoriaMetrics](https://victoriametrics.com/)

### Visualisation des données

Comme les données de la traite sont disponibles dans VictoriaMetrics, je peux
utiliser [Grafana](https://grafana.com/) pour les visualiser. Je pourrai
potentiellement par la suite créer des alertes, par exemple lorsqu'il faut
beaucoup plus de temps pour traire une vache que la veille, ou si la production
moyenne de lait sur 3 jours baisse sensiblement.

Comme Grafana est une solution de visualisation de graphiques web, il est
maintenant possible en tout temps de consulter la production de chaque vache,
la tendance de production, la durée moyenne de la traite, etc. Et ce même
depuis son natel (/téléphone portable/smartphone)!

Je clôture donc cet article avec un aperçu de la visualisation. Le prochain
épisode concernera l'installation de méthanisation/biogaz de l'exploitation !

![Grafana dashboard](/images/2024-milk-exporter/grafana-dashboard.png)
