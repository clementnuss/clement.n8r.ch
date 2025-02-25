---
title: "Une Ferme Connectée: partie 3 - automatisation de la balance"
date: 2025-02-25T18:34:07+01:00
slug: ferme-connectee-la-balance
cover:
  image: /images/2025-weighbridge/weighbridge.jpeg
tags: [ferme, golang, mariadb, kubernetes, webhook, balance, truckflow]
description: |
  Cet article couvre l'automatisation de la gestion d'utilisateurs pour la
  balance de pesée installée sur le site du biogaz de la ferme.

---

> La version française de cet article ne couvre pas l'implémentation technique,
> mais décrit simplement le problème et la solution mise en place. Pour les
> détails techniques, il faut se référer à la version anglaise !

## La Balance

L'exploitation agricole de mon épouse et de sa famille est disséminée sur deux
sites. Des vaches laitières sont traites sur le premier site, et le deuxième
site est une installation de méthanisation/biogaz et de collecte de déchets
verts (troncs, branchages, gazon, etc.).

Jusqu'à présent, le travail lié à la collecte des déchets verts (broyage,
compostage, tamisage, manutention, etc.) était payé par les communes
avoisinantes à travers une taxe fixe par habitant. Cependant, suite à une
décision communale, le système va changer et le ["principe de
causalité"](https://www.fedlex.admin.ch/eli/cc/1984/1122_1122_1122/fr#art_2)
sera mis en application. Cette loi, communément connue comme celle du
"pollueur/payeur", veut que la personne qui produise les déchets doive en
assumer les coûts d'élimination, comme c'est déjà le cas pour certains déchets
(tels que les ordures ménagères, les déchets plastiques, les déchets inertes,
etc.).

Ainsi, afin de pouvoir peser et facturer la quantité de déchets verts de chaque
habitant/entreprise, une balance industrielle a dû être installée.

![Photo de la balance](/images/2025-weighbridge/weighbridge.jpeg)

Comme il y aura beaucoup d'utilisateurs (habitants des communes en entreprise),
il est donc crucial d'automatiser au maximum la création des utilisateurs
(l'objet de cet article) ainsi que l'importation et la facturation des pesées.

## Importation automatique des utilisateurs

Afin de simplifier au maximum le travail des exploitants, j'ai développé un
petit logiciel qui traite les données d'un formulaire de paiement de manière
automatisée et qui les importe dans le logiciel de gestion de la balance
([truckflow](https://uk.preciamolen.com/product/truckflow-weight-management-software/)).
Le fonctionnement du logiciel est le suivant:

1. le logiciel écoute le traffic sur le port 9000 et reçoit des données du
   formulaire de paiement après chaque transaction
1. lorsque les données d'un paiement complété sont reçues, je créé un fichier
   JSON pour l'importation du client et un autre fichier JSON pour la création
   d'un certain nombre de badges.
1. ces fichiers sont alors envoyés sur un _drive_ S3 dans le cloud
1. enfin, le PC sur lequel le logiciel de gestion de la balance est installé
   déplace ces fichiers localement (avec le logiciel
   [rclone](https://rclone.org/)) et ils sont automatiquement importés dans
   truckflow

### Implémentation

L'implémentation a été réalisée avec le language Golang, et le code source est
disponible sur
[GitHub](https://github.com/clementnuss/truckflow-user-importer). Pour les
détails techniques, il faut se référer à la version anglaise de cet article.

## Conclusion

207 clients/tiers et 226 badges ont été importés en l'espace de 10 jours par
mon petit logiciel, ce qui a déjà économisé passablement d'heures de travail et
a prévenu bon nombre de fautes de frappe.

Et donc, une fois de plus, développer du code en Golang est aussi amusant
qu'utile, et c'est toujours un plaisir de voir le compteur de clients importés
augmenter chauqe jour, car je sais que c'est tout du temps de sauvé pour mon
épouse et ses collègues!
