---
title: "A connected farm, part 3 - weighbridge automation"
date: 2025-02-25T18:34:07+01:00
slug: connected-farm-the-weighbridge
cover:
  image: /images/2025-weighbridge/weighbridge.jpeg
tags: [farm, golang, mariadb, kubernetes, webhook, weighbridge, truckflow]
description: |
  This article covers a topic related to my wife's family farm, namely the brand
  new weighbridge installed on the biogas plant.
---

## The Weighbridge

Next to the actual farm with the milking cows, the farm is also constituted of
a biogas plant. Taking advantage of the facilities there (trucks, buildings,
etc.), my wife's family have been collecting "green waste" for years now, and
up until 2024, the cost for taking care of that waste was being paid for by a
"per-habitant" tax paid by the town.

Recently however, due to the so-called ["principe de
causalité"](https://www.fedlex.admin.ch/eli/cc/1984/1122_1122_1122/fr#art_2),
in place of a tax/fee per capita, people bringing green waste to the biogas
plant will have to pay for the amount they brought. As a result, a weighbridge
had to be installed, which is only one part of the equation.

![Weighbridge picture](/images/2025-weighbridge/weighbridge.jpeg)

As one can imagine, there will be a lot of traffic on the site, and this also
means lots of weighing to process and invoice. Which brings us to the topic of
this blog article: automation!

## Automatic User Import

In order to simplify the work of the farm owners, I developed a piece of
software which processes payments from a registration form automatically, and
which populates customers and passes in the weighbridge management software
([truckflow](https://uk.preciamolen.com/product/truckflow-weight-management-software/)).

The [software is
open-source](https://github.com/clementnuss/truckflow-user-importer), and works
as follows:

1. the software listens on port 9000 for API calls from the
   ordering/registration form
1. as soon as a `completed` payment JSON arrives, we generate a new
   _tier_/_customer_ and a number of passes (depending on the order)
1. we push those tiers and passes (which are JSON files as well) to an S3
   bucket
1. an automatic [rclone](https://rclone.org/) task retrieves the file on the
   Windows PC which runs the truckflow software

### Implementation

Once again, I used [Go](https://go.dev/) to write the software, and that was
once again most pleasant :)

In the main function, I start by initializing a connection to a MariaDB
database (in which I store and increment the unique customer number/codes) and
the S3 client library ([`minio-go`](http://github.com/minio/minio-go/)).
Once that is done, I register a `/webhook` function handler and start the HTTP
server.

The core of the functionality happens in the [webhook handler
function](https://github.com/clementnuss/truckflow-user-importer/blob/f8c1ba8b9066d61815b1cf54e3ffe5f88d051d3a/internal/webhook/webhook.go#L24):
first of all the transaction data is parsed/unmarshaled with Golang struct tags
and the `encoding/json` library:

```go
type Invoice struct {
	Products     []Product     `json:"products"`
	CustomFields []CustomField `json:"custom_fields"`
}

type Product struct {
	Name     string `json:"name"`
	Price    int    `json:"price"`
	Quantity int    `json:"quantity"`
}

type CustomField struct {
	Type  string `json:"type"`
	Name  string `json:"name"`
	Value string `json:"value"`
}

type Contact struct {
	Title        string `json:"title"`
	FirstName    string `json:"firstname"`
	LastName     string `json:"lastname"`
	StreetAndNo  string `json:"street"`
	ZIPCode      string `json:"zip"`
	City         string `json:"place"`
	Country      string `json:"country"`
	Telephone    string `json:"phone"`
	Email        string `json:"email"`
	Company      string `json:"company"`
}
```

Then if the transaction status is _confirmed_ and if we haven't processed the
transaction already, we perform the following tasks:

1. retrieve and increase the client counter from the database
2. create the truckflow structs and marshal the JSON files (only showing the
   `Tiers` generation here)

```go
  tiers := truckflow.Tiers{
    Type:         "Fournisseur",
    Label:        transaction.Contact.FirstName + " " + transaction.Contact.LastName,
    Active:       true,
    Address:      transaction.Contact.StreetAndNo,
    ZIPCode:      transaction.Contact.ZIPCode,
    City:         transaction.Contact.City,
    Telephone:    transaction.Contact.Telephone,
    Email:        transaction.Contact.Email,
    Entreprise:   transaction.Contact.Company,
    Code:         fmt.Sprintf("%05d", clientCounter),
    ProductCodes: "Dechets verts",
  }
  truckflowImport := truckflow.TiersImport{
    Version: "1.50",
    Items:   []truckflow.Tiers{tiers},
  }
  jsonData, err := json.Marshal(truckflowImport)
```

3. upload those files (the tiers and the pass files) to S3:

```go
	path := filepath.Join("importer/", fmt.Sprintf("tiers_import_%s.json", tiers.Code))
	_, err = s3.PutObject(
		context.Background(),
		os.Getenv("S3_BUCKET"),
		path,
		bytes.NewReader(jsonData),
		int64(len(jsonData)),
		minio.PutObjectOptions{},
	)
```

### Windows sync task

The last piece of work is configuring a Windows automatic task to retrieve the
files from the S3 bucket. We use the `move` command of rclone, which downloads
the tiers/passes import files locally, and which are then automatically
processed and imported by truckflow. The full rclone command is:

```cmd
rclone.exe move exoscale:biogaz-balance/export C:\dev\export
```

For the sake of completeness, the windows automated task is documented
hereafter.
{{< details summary="Windows automated task XML" >}}

```xml
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>2025-01-27T21:55:46.3211421</Date>
    <Author>PC-Balance\biogaz-balance</Author>
    <URI>\rclone sync export</URI>
  </RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <Repetition>
        <Interval>PT1H</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>2025-01-27T21:56:02</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-21-3931382402-1419932415-3081863895-1005</UserId>
      <LogonType>Password</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>true</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>true</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT72H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>C:\dev\rclone\rclone.exe</Command>
      <Arguments>move exoscale:biogaz-balance/export C:\dev\export</Arguments>
    </Exec>
  </Actions>
</Task>
```

{{< /details >}}

## Building and Running the Webhook

### ko.build

I am building the webhook software with [`ko`](https://ko.build/), which makes it extremely simple to build and publish a container for a Go app.
Moreover, I used a GitHub action, so that a new container is built every time I push. The code for the GitHub action is shown below:

```yaml
name: Publish

on:
  push:
    branches: ["main"]

jobs:
  publish:
    name: Publish
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      attestations: write
      id-token: write
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: "1.23.x"

      - uses: ko-build/setup-ko@v0.8
      - run: ko build --bare
```

### Kubernetes

As usual, I turn to my homelab cluster to run the webhook. As Let's Encrypt
certificate generation is already provided (with cert-manager), it's really
only a matter of creating 4 manifests to get the software up and running. This
time I mostly created the manifests with imperative style `kubectl` commands. \
I still needed to adapt the manifests to e.g. mount the secret into the pod,
but the main manifests were generated quickly with the `--dry-run=client
--output=yaml` flags :)

```shell
# secret:
kubectl create secret generic --from-env-file=.env truckflow-user-importer-credentials
# deployment:
kubectl create deploy --port 9000 --image ghcr.io/clementnuss/truckflow-user-importer truckflow-user-importer
# service:
kubectl create svc clusterip truckflow-user-importer --tcp 9000:9000
# ingress
kubectl create ingress truckflow-user-importer --rule "truckflow-importer.tld.ch/*=truckflow-user-importer:9000,tls" --class nginx
```

## Conclusion

As of writing this article, 207 clients/tiers and 226 passes have been imported
into truckflow, saving the operators a copious amount of time and sparing many
typos (except for the ones clients entered in the registration form, that is
😅.

A few adapations were needed, such as [the need to explicitly differentiate
between customer/company type of
tiers](https://github.com/clementnuss/truckflow-user-importer/commit/7ae7b21dffad9cfa673265550091cf7f53304ee3#diff-3b708692c7872a280cc2124df861edbf132ee282e5d5d16e8fb7a70507f91ac4R89-R97),
but those were easy fixes which I released quickly thanks to the automated
build pipeline (it takes less than 15s between a commit and the new version
running on my cluster).

So all in all, I'm quite happy with saving lots of time with a little Go code,
and it was fun to finally (mis-)use a DB to store stateful information.

> misuse a DB: I probably shouldn't [store counters manually in a
> table](https://github.com/clementnuss/truckflow-user-importer/blob/v1.0.0/internal/database/db.go#L64),
> but that works and I [implemented a
> mutex](https://github.com/clementnuss/truckflow-user-importer/commit/f8c1ba8b9066d61815b1cf54e3ffe5f88d051d3a)
> to prevent race conditions in the webhook parser code, therefore it's staying
> like that :)
