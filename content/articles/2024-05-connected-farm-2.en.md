---
title: "A Connected Farm, part 2 - Remote Controlled Fence ⚡️"
date: 2024-05-11T06:17:14+02:00
slug: connected-farm-fence-bot
cover:
   image: /images/2024-fence-bot/pasture-overview.jpeg
tags: [farm, cow, golang, mqtt, gokrazy]
---

This article again covers a topic related to my wife's family farm, but this
time, instead of [exporting milking data to Grafana]({{< ref
"./2024-02-connected-farm-1.en.md" >}}), I will detail my usage of [Michael
Stapelberg](https://michael.stapelberg.ch/)'s amazing
[`gokrazy`](https://gokrazy.org/) project, which made it possible to reliably
develop Go software to control  fences around the farm.

## Fences and Cows 🐄

The farm is distributed on 2 sites, and on each site there are rather long
electric fences, in which the cows happily pasture during the day (and for the
heifer's fence, also during the night). \
To prevent the cows from escaping the fences and e.g. eat our neighbour's grass
(which is always greener, as we all know), the fences are electrified ⚡️ with
high voltage (6000V) impulsions every second.

![cow pasture fence](/images/2024-fence-bot/pasture-overview.jpeg)

While all of this works really well, because the fence electrification
equipment (one per fence) is located in the main buildings of both site,
conducting maintenance on the fence was quite cumbersome  as you had to
walk sometimes up to 1 Km to the main building to pull the plug of the
electrification equipment.

That's when I thought that adding a connected relay to the equation could help
simplify their work, as it would enable them to stay on the maintenance site,
remotely toggle the fence off, and start working on the fence.

## RC Fence and User Experience

For ease of user experience, I didn't want my wife and her family to have to
install an app to control the fence, as it would have incurred sharing
user/password among 5 people, showing them how to use the app, relying on some
manufacturer's cloud to (reliably) work, etc. 

However, as I had already enjoined them to use
[Telegram](https://telegram.org/) (to receive alerts related to their Biogas
plant), I thought it would be cool to create a Telegram Bot to control the
fence. It comes with several advantages:
- ease of use: you only have to open the chat of the Telegram Bot for the
  corresponding fence, and you can start to interact with the fence
- security: I only let authorized Telegram `user_id` command the bot status,
  and authentication (the `user_id`) comes granted from Telegram
- reliability: the only breaking point which I do not control is the Telegram
  Bot API, but in multiple years of using it, I never had an incident

With that said, I started to work on writing the Go software for the bot,
which you can check at [clementnuss/fence-bot](https://github.com/clementnuss/fence-bot)

With relatively few lines of code, I got to something simple to understand and use:

![Fence bot screenshot](/images/2024-fence-bot/fence-bot-screenshot.png)

The three buttons permit to turn on/off the fence, and to manually enquire a
status update from the switch.

## Where to run `fence-bot` code ?

That's where [`gokrazy`](https://gokrazy.org/) comes into play! Written by
[Michael Stapelberg](https://michael.stapelberg.ch/), it makes it reliablye,
simple and mostly fun to write and upload Go code to a Raspberry Pi!

Gokrazy permits to focus on the application logic, written in Go, so that you
don't have to lose time writing `systmed` services to make sure the bot starts
on system boot, etc.

And to give you and idea of how simple it is to update a running code on your
Raspberry Pi, the only command you need to run is
```shell
gok --instance gok-biogas update
```

Another immensely simple and useful feature of gokrazy is importing another Go
module into your project. For this project, I needed to use an MQTT server, and
had I not used gokrazy, I would probably have hosted that on my private
Kubernetes cluster, but to the detriment of latency and reliability.

Thanks to gokrazy however, I imported a lightweight Go-written MQTT server
(namely, [wind-c/comqtt](https://github.com/wind-c/comqtt/)) to my instance
configuration, as simply as doing
```shell
gok --instance gok-biogas add github.com/wind-c/comqtt/cmd/single
gok --instance gok-biogas update
```

And with that done, I had a local MQTT server running on my Raspberry Pi, so
that the only requirement for `fence-bot` to work is a reliable internet
connection to the Telegram API, and nothing more.

## `fence-bot` code

Inspired by [Michael](https://github.com/stapelberg/regelwerk)'s project to
manage his MQTT-driven smart house, I started writing the code to control my
MQTT-driven relay (a [Shelly Plus 1
PM](https://www.shelly.com/en-ch/products/product-overview/shelly-plus-1-pm)),
which in the end turned out quite simple: I only had to create 2 Go structs
which I used to parse the status update from the mqtt relay, and and a
function to publish to a specified topic to toggle on/off the relay (and
thereby the fence).

```go
type shellyInputStatus struct {
	Id         int  `json:"id"`
	State      bool `json:"state"`
	LastUpdate time.Time
}
type shellySwitchStatus struct {
	Output       bool    `json:"output"`
	Voltage      float64 `json:"voltage"`
	Current      float64 `json:"current"`
	AveragePower float64 `json:"apower"`
	LastUpdate   time.Time
}

func handler(client mqtt.Client, message mqtt.Message) {
	switch message.Topic() {
	case shellyPrefix + "status/input:0":
		err := json.Unmarshal(message.Payload(), &stat.InputStatus)
		if err == nil {
			stat.InputStatus.LastUpdate = time.Now()
		}
	case shellyPrefix + "status/switch:0":
		err := json.Unmarshal(message.Payload(), &stat.SwitchStatus)
		if err == nil {
			stat.SwitchStatus.LastUpdate = time.Now()
		}
	}
}

func mqttCommandSwitch(status bool) { // command the switch status
	client.Publish(shellyPrefix+"command/switch:0", 0, false, boolToStr(status))
}

func mqttStatusUpdate() { // enquire a status update
	client.Publish(shellyPrefix+"command", 1, false, "status_update")
}
```

With that being done, I wrote the code for the Telegram Bot API with the
[`telebot`](https://github.com/tucnak/telebot) package, which seems actively
maintained and boasts 3.7k GitHub stars:

```Go
func bot() {

	b, err = telebotv3.NewBot(settings)
	if err != nil {
		log.Fatal(err)
		return
	}

	statusButton := telebotv3.InlineButton{Unique: "status", Text: "Statut"}
	on := telebotv3.InlineButton{Unique: "on", Text: "On ⚡️"}
	off := telebotv3.InlineButton{Unique: "off", Text: "Off"}

	m = b.NewMarkup()
	m.InlineKeyboard = append(m.InlineKeyboard,
		[]telebotv3.InlineButton{off, statusButton, on})

	b.Handle("/start", func(c telebotv3.Context) error {
		return c.Send(fenceStatus(), m)
	})

	b.Handle(&statusButton, func(c telebotv3.Context) error {
		mqttStatusUpdate()
		time.Sleep(200 * time.Millisecond)
		_, _ = b.Edit(c.Message(), fenceStatus(), m)
		return c.Respond(&telebotv3.CallbackResponse{})
	})

	b.Handle(&on, func(c telebotv3.Context) error {
		return commandSwitch(true, c)
	})

	b.Handle(&off, func(c telebotv3.Context) error {
		return commandSwitch(false, c)
	})

	b.Start()
    
```

Et voilà! my little `fence-bot` was ready to run ! And to this day (11th of May
2024), it has been in use for over 2 months without any interruption 🙃

And shall you be interested in replicating that setup for yourself, you will
find the Go code for this project at
[clementnuss/fence-bot](https://github.com/clementnuss/fence-bot)

